#!/usr/bin/env python3
"""Claude in Search: an MCP server that lets Claude use the Search browser.

    claude mcp add --scope user search -- python3 /path/to/Search/mcp/search_mcp.py

It speaks MCP over stdio and drives Search through the bench's socket (see
Sources/Search/Bench.swift and Agent.swift). Nothing to install: Python 3's
standard library only.

In Search: Settings › General › "Let a script drive Search" on. To let Claude
use your own tabs too — the one in front, the ones you have open — also turn
on "Let Claude use your tabs". Without it Claude works in tabs of its own,
marked with a flask, which never take the window from you.

SEARCH_WORLD=test drives a SEARCH_PROBE run instead of your browser.
"""

import base64
import json
import mimetypes
import os
import re
import socket
import subprocess
import sys
import time

WORLD = os.environ.get("SEARCH_WORLD", "").strip().lower()
FOLDER = os.path.expanduser(f"~/Library/Application Support/Search ({WORLD})" if WORLD else "~/Library/Application Support/Search")
SOCKET = os.path.join(FOLDER, "bench.sock")
VERSION = "1.0.0"

# The tab Claude last opened or used: the one a call without a tabId means.
current = {"id": None}


class Refused(Exception):
    pass


def connect(timeout):
    """The socket, with Search opened in the background first if it is closed."""
    for attempt in range(2):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect(SOCKET)
            return s
        except (FileNotFoundError, ConnectionRefusedError):
            s.close()
            running = subprocess.run(["pgrep", "-x", "Search"], capture_output=True).returncode == 0
            if attempt or WORLD or running:
                break
            subprocess.run(["open", "-g", "-b", "com.officecommun.search"], capture_output=True)
            for _ in range(40):
                time.sleep(0.25)
                if os.path.exists(SOCKET):
                    break
    raise Refused("Search isn't listening. Open Search and turn on Settings › General › "
                  "“Let a script drive Search”.")


def ask(request, timeout=180):
    """One request, one answer, over the socket."""
    s = connect(timeout)
    try:
        s.sendall((json.dumps(request) + "\n").encode())
        chunks = []
        while True:
            chunk = s.recv(1 << 20)
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        s.close()
    line = b"".join(chunks).split(b"\n", 1)[0]
    answer = json.loads(line or b"{}")
    if "error" in answer:
        error = str(answer["error"])
        # A tab gone since — closed, or Search started again: the next call
        # without a tabId goes to the one in front, or asks.
        if error.startswith("no tab") and current["id"] and request.get("id") == current["id"]:
            current["id"] = None
        raise Refused(error)
    return answer


def tab_of(args):
    tab = args.get("tabId") or current["id"]
    if args.get("tabId"):
        current["id"] = args["tabId"]
    return tab


def with_tab(request, args):
    tab = tab_of(args)
    if tab:
        request["id"] = tab
    return request


def text(value):
    return {"type": "text", "text": value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, indent=1)}


def tab_line(t):
    mark = "claude" if t.get("bench") else ("front" if t.get("active") else "yours")
    state = " (loading)" if t.get("loading") else (" (asleep)" if t.get("asleep") else "")
    return f"{t['id']}  [{mark}]  {t.get('title') or '—'}  {t.get('url')}{state}"


# MARK: - the tools

TAB = {"type": "string", "description": "The tab's id from tabs_context. Leave out for the tab Claude last opened or used (or, with “Let Claude use your tabs” on, the one in front)."}
REF = {"type": "string", "description": "An element's ref from read_page or find, like r12."}

TOOLS = [
    {
        "name": "tabs_context",
        "description": "List Search's tabs: their ids, titles, addresses, which one is in front, and which ones Claude opened. Call this first. Claude can use the tabs it opened; the user's own only if they turned on “Let Claude use your tabs”.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "tabs_create",
        "description": "Open a new tab of Claude's own at a URL (localhost works) and wait for it to load. It opens at the end of the row with a flask, out of the user's way, 1280×800 unless width and height say otherwise. show: true brings it to the front (needs “Let Claude use your tabs”).",
        "inputSchema": {"type": "object", "properties": {
            "url": {"type": "string"}, "show": {"type": "boolean"},
            "width": {"type": "number"}, "height": {"type": "number"}}, "required": ["url"]},
    },
    {
        "name": "resize_page",
        "description": "Give a tab of Claude's another viewport size, to check a layout: e.g. 390×844 with mobile: true for a phone (also sends an iPhone user agent), 820×1180 for a tablet, 1920×1080. Not for a tab shown in the user's window.",
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB, "width": {"type": "number"}, "height": {"type": "number"}, "mobile": {"type": "boolean"}}, "required": ["width", "height"]},
    },
    {
        "name": "tabs_close",
        "description": "Close a tab Claude opened.",
        "inputSchema": {"type": "object", "properties": {"tabId": TAB}},
    },
    {
        "name": "tab_show",
        "description": "Bring a tab to the front of the user's window, so they can watch. Needs “Let Claude use your tabs”.",
        "inputSchema": {"type": "object", "properties": {"tabId": TAB}},
    },
    {
        "name": "navigate",
        "description": "Go to a URL in a tab, or back, forward, reload, or hard (reload past every cache — after changing a file); waits for the page to load.",
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB, "url": {"type": "string", "description": "A URL, or back, forward, reload, hard."}}, "required": ["url"]},
    },
    {
        "name": "read_page",
        "description": "What can be used on the page, one element per line with a ref: links, buttons, fields (with their values), checkboxes, headings, dialogs. Each line ends with @x,y, its middle in screenshot coordinates, or (offscreen). Refs stay the same for the same element across reads. filter: interactive (default) or all (adds images and other labeled elements). ref: read only under that element. Fast: a few milliseconds.",
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB, "filter": {"type": "string", "enum": ["interactive", "all"]}, "ref": REF,
            "max": {"type": "integer", "description": "At most this many elements (default 400)."}}},
    },
    {
        "name": "find",
        "description": "Find elements by words — their text, label, placeholder, role, id or name. Returns matching lines with refs, best first.",
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB, "query": {"type": "string"}, "max": {"type": "integer"}}, "required": ["query"]},
    },
    {
        "name": "get_page_text",
        "description": "The page's text: the article or main part if there is one, else the whole body. ref: the text under one element.",
        "inputSchema": {"type": "object", "properties": {"tabId": TAB, "ref": REF, "max": {"type": "integer"}}},
    },
    {
        "name": "computer",
        "description": (
            "Use the page with real mouse and keyboard events, as a person would. Actions:\n"
            "- screenshot: a JPEG of what is on screen; 1 pixel = 1 CSS pixel, so its coordinates are the ones to click. With ref: just that element.\n"
            "- left_click, double_click, triple_click, right_click, hover: at ref (preferred — scrolled into view first) or coordinate [x, y]. modifiers: e.g. \"cmd\" or \"shift+cmd\". A click that loads a page answers once it has loaded. A select can't be clicked: use form_input.\n"
            "- left_click_drag: from ref or coordinate to to_ref or to_coordinate — a slider, a sortable list, a canvas, HTML drag and drop.\n"
            "- type: text into the focused field (ref: click that field first). Inserted in one go, like Chrome's; keys: true presses a key per character instead.\n"
            "- key: space-separated chords, e.g. \"Enter\", \"cmd+a Backspace\", \"shift+Tab\", \"ArrowDown ArrowDown Enter\". repeat: how many times.\n"
            "- scroll: scroll_direction up/down/left/right, scroll_amount in ticks of 100px (default 3), at ref or coordinate (scrolls what is under it) or the page.\n"
            "- scroll_to: bring ref into view.\n"
            "- wait: duration seconds (max 30)."
        ),
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB,
            "action": {"type": "string", "enum": ["screenshot", "left_click", "double_click", "triple_click", "right_click", "hover", "left_click_drag", "type", "key", "scroll", "scroll_to", "wait"]},
            "ref": REF,
            "coordinate": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2},
            "to_ref": REF,
            "to_coordinate": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2},
            "text": {"type": "string", "description": "For type: the text. For key: the chords."},
            "keys": {"type": "boolean"},
            "modifiers": {"type": "string"},
            "repeat": {"type": "integer"},
            "scroll_direction": {"type": "string", "enum": ["up", "down", "left", "right"]},
            "scroll_amount": {"type": "number"},
            "duration": {"type": "number"},
        }, "required": ["action"]},
    },
    {
        "name": "form_input",
        "description": "Set a field's value directly: text fields, selects (by option value or text), checkboxes and radios (true/false). Faster than typing; use computer type when the page reacts to keystrokes.",
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB, "ref": REF, "value": {}}, "required": ["ref", "value"]},
    },
    {
        "name": "upload_file",
        "description": "Put files from this Mac into a file field, or drop them on a drop zone (ref). paths: absolute paths. Up to 24 MB in all.",
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB, "ref": REF, "paths": {"type": "array", "items": {"type": "string"}}}, "required": ["ref", "paths"]},
    },
    {
        "name": "wait_for",
        "description": "Wait until a CSS selector matches, some text is on the page, or (idle: true) the page has loaded and has no fetch or XHR open for half a second. Default up to 10 s.",
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB, "selector": {"type": "string"}, "text": {"type": "string"}, "idle": {"type": "boolean"}, "seconds": {"type": "number"}}},
    },
    {
        "name": "handle_dialog",
        "description": "Alerts, confirms, prompts, logins and file choosers in Claude's tabs never block the page: they are answered at once and reported with the next result (\"dialogs\"). By default an alert is closed, a confirm is OK, a prompt takes its default, a login and an untrusted certificate are refused. Call this before the action to answer the next one differently: accept false for Cancel, text for a prompt's answer, or \"name:password\" for a login. Without accept/text it just returns what was asked since the last result.",
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB, "accept": {"type": "boolean"}, "text": {"type": "string"}}},
    },
    {
        "name": "javascript_tool",
        "description": "Run JavaScript in the page, with the page's own globals, and get its value back: an expression, or a function body that returns. Promises are awaited. An error is reported, never run twice.",
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB, "code": {"type": "string"}}, "required": ["code"]},
    },
    {
        "name": "read_console_messages",
        "description": "Console messages, uncaught errors and rejections, files that failed to load and blocked content. Claude's own tabs and pages from this Mac (localhost, *.local, *.test) are heard from the first line of the page; any other page from the first call on it. pattern: a regex to keep only matching lines. onlyErrors: errors and exceptions only. clear: empty the buffer after reading.",
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB, "pattern": {"type": "string"}, "onlyErrors": {"type": "boolean"}, "clear": {"type": "boolean"}}},
    },
    {
        "name": "read_network_requests",
        "description": "What the page loaded and asked for: the document, each file, and every fetch and XHR with its method, status, time and failure. Heard from the first line in Claude's tabs and localhost pages. pattern: a regex on the URL. onlyFailed: 4xx, 5xx and failures only. clear: forget what was listed.",
        "inputSchema": {"type": "object", "properties": {"tabId": TAB, "pattern": {"type": "string"}, "onlyFailed": {"type": "boolean"}, "clear": {"type": "boolean"}}},
    },
    {
        "name": "batch",
        "description": (
            "Several steps in one call, in order, stopping at the first error (keepGoing: true to go on). "
            "Each step is {\"do\": ..., ...} with the same fields as the tools: "
            "read, find, text, click (ref|coordinate, button: left|double|triple|right), hover, drag (ref|coordinate, toRef|toX,toY), type (text, ref?, keys?), "
            "key (keys), fill (ref, value), scroll (dx, dy, ref?|coordinate?), navigate (url), wait (selector|text|idle, seconds), js (code). "
            "Example: [{\"do\":\"click\",\"ref\":\"r3\"},{\"do\":\"type\",\"text\":\"hello\"},{\"do\":\"key\",\"keys\":\"Enter\"},{\"do\":\"wait\",\"text\":\"Results\"},{\"do\":\"read\"}]"
        ),
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB, "steps": {"type": "array", "items": {"type": "object"}}, "keepGoing": {"type": "boolean"}}, "required": ["steps"]},
    },
]


def step(s):
    """A batch step in the tools' words, as the bench's verb."""
    s = dict(s)
    verb = s.pop("do", "")
    if "coordinate" in s:
        s["x"], s["y"] = s.pop("coordinate")
    if verb == "key" and "text" in s and "keys" not in s:
        s["keys"] = s.pop("text")
    s.pop("world", None)
    names = {"read": "a.read", "find": "a.find", "text": "a.text", "click": "a.click", "hover": "a.hover", "type": "a.type",
             "key": "a.key", "fill": "a.fill", "scroll": "a.scroll", "navigate": "a.navigate", "wait": "a.wait", "js": "a.js",
             "focus": "a.focus", "drag": "a.drag"}
    if verb not in names:
        raise Refused(f"batch: unknown step “{verb}”")
    s["do"] = names[verb]
    return s


def said(verb, answer):
    """A bench answer as a few lines for Claude, with what the page did meanwhile."""
    out = plain(verb, answer)
    extra = []
    for d in answer.get("dialogs") or []:
        how = "accepted" if d.get("accepted") else "refused"
        extra.append(f"the page asked ({d.get('kind')}): {d.get('message')} — {how}" + (f", answered “{d['answered']}”" if d.get("answered") else ""))
    for t in answer.get("opened") or []:
        extra.append(f"the page opened a new tab of Claude's: {t}")
    return out + ("\n" + "\n".join(extra) if extra else "")


def plain(verb, answer):
    answer = {k: v for k, v in answer.items() if k not in ("dialogs", "opened", "tab")}
    if verb == "a.read":
        return answer.get("page", "")
    if verb == "a.find":
        found = answer.get("found", [])
        return "\n".join(found) if found else "nothing found"
    if verb == "a.text":
        return f"{answer.get('title')} — {answer.get('url')}\n\n{answer.get('text', '')}" + ("\n[… cut]" if answer.get("truncated") else "")
    if verb == "a.js":
        return json.dumps(answer.get("value"), ensure_ascii=False)
    if verb in ("a.navigate", "a.open"):
        out = f"{answer.get('id')}: {answer.get('title') or '—'} — {answer.get('url')}"
        if answer.get("failure"):
            out += f"\nfailed: {answer['failure']}"
        if answer.get("timeout"):
            out += "\n(still loading)"
        return out
    return json.dumps(answer, ensure_ascii=False)


def call(name, args):
    if name == "tabs_context":
        a = ask({"do": "a.tabs"})
        lines = [tab_line(t) for t in a.get("tabs", [])]
        note = "" if a.get("yours") else "\n\nClaude can use only the tabs marked [claude]. Settings › General › “Let Claude use your tabs” opens the others."
        return [text("\n".join(lines) + note)]

    if name == "tabs_create":
        req = {"do": "a.open", "url": args["url"], "show": bool(args.get("show"))}
        if args.get("width") and args.get("height"):
            req["width"], req["height"] = float(args["width"]), float(args["height"])
        a = ask(req)
        current["id"] = a.get("id")
        return [text(said("a.open", a))]

    if name == "tabs_close":
        tab = tab_of(args)
        if not tab:
            raise Refused("which tab? see tabs_context")
        a = ask({"do": "a.close", "id": tab})
        if current["id"] == tab:
            current["id"] = None
        return [text(f"closed {a.get('closed')}")]

    if name == "resize_page":
        req = with_tab({"do": "a.resize", "width": float(args["width"]), "height": float(args["height"])}, args)
        if "mobile" in args:
            req["mobile"] = bool(args["mobile"])
        a = ask(req)
        return [text(f"{a['width']}×{a['height']}" + (" as a phone" if a.get("mobile") else ""))]

    if name == "upload_file":
        files, total = [], 0
        for path in args["paths"]:
            path = os.path.expanduser(path)
            with open(path, "rb") as f:
                data = f.read()
            total += len(data)
            if total > 24_000_000:
                raise Refused("more than 24 MB — upload fewer or smaller files")
            files.append({"name": os.path.basename(path), "type": mimetypes.guess_type(path)[0] or "", "data": base64.b64encode(data).decode()})
        a = ask(with_tab({"do": "a.upload", "ref": args["ref"], "files": files}, args))
        return [text(f"{a.get('files')} file(s) " + ("put in the field" if a.get("into") == "field" else "dropped"))]

    if name == "handle_dialog":
        if "accept" in args or "text" in args:
            req = with_tab({"do": "a.dialog", "accept": bool(args.get("accept", True))}, args)
            if args.get("text") is not None:
                req["text"] = str(args["text"])
            ask(req)
            return [text("the next dialog will be answered that way")]
        a = ask(with_tab({"do": "a.dialogs"}, args))
        lines = [f"{d.get('kind')}: {d.get('message')} — " + ("accepted" if d.get("accepted") else "refused") for d in a.get("dialogs", [])]
        return [text("\n".join(lines) or "nothing was asked")]

    if name == "tab_show":
        a = ask(with_tab({"do": "a.show"}, args))
        return [text(f"in front: {tab_line(a)}")]

    if name == "navigate":
        a = ask(with_tab({"do": "a.navigate", "url": args["url"]}, args))
        current["id"] = a.get("id") or current["id"]
        return [text(said("a.navigate", a))]

    if name == "read_page":
        req = with_tab({"do": "a.read"}, args)
        for k in ("filter", "ref", "max"):
            if args.get(k) is not None:
                req[k] = args[k]
        a = ask(req)
        current["id"] = a.get("tab") or current["id"]
        return [text(said("a.read", a))]

    if name == "find":
        req = with_tab({"do": "a.find", "query": args["query"]}, args)
        if args.get("max"):
            req["max"] = args["max"]
        return [text(said("a.find", ask(req)))]

    if name == "get_page_text":
        req = with_tab({"do": "a.text"}, args)
        for k in ("ref", "max"):
            if args.get(k) is not None:
                req[k] = args[k]
        return [text(said("a.text", ask(req)))]

    if name == "form_input":
        a = ask(with_tab({"do": "a.fill", "ref": args["ref"], "value": args["value"]}, args))
        return [text(said("a.fill", a))]

    if name == "wait_for":
        req = with_tab({"do": "a.wait", "seconds": float(args.get("seconds", 10))}, args)
        for k in ("selector", "text", "idle"):
            if args.get(k):
                req[k] = args[k]
        return [text(said("a.wait", ask(req, timeout=float(args.get("seconds", 10)) + 15)))]

    if name == "javascript_tool":
        return [text(said("a.js", ask(with_tab({"do": "a.js", "code": args["code"]}, args))))]

    if name == "read_console_messages":
        a = ask(with_tab({"do": "a.console", "clear": bool(args.get("clear"))}, args))
        messages = a.get("messages", [])
        if args.get("onlyErrors"):
            messages = [m for m in messages if m["level"] in ("error", "exception")]
        if args.get("pattern"):
            rx = re.compile(args["pattern"])
            messages = [m for m in messages if rx.search(m["text"])]
        lines = [f"[{m['level']}] {m['text']}" for m in messages[-200:]]
        head = "listening from now on — what the page said before this call was not heard\n" if a.get("since") == "now" else ""
        return [text(head + ("\n".join(lines) or "no messages"))]

    if name == "read_network_requests":
        a = ask(with_tab({"do": "a.network", "clear": bool(args.get("clear"))}, args))
        reqs = a.get("requests", [])
        if args.get("pattern"):
            rx = re.compile(args["pattern"])
            reqs = [r for r in reqs if rx.search(r.get("url", ""))]
        if args.get("onlyFailed"):
            reqs = [r for r in reqs if r.get("failed") or (r.get("status") or 0) >= 400]
        def row(r):
            status = r.get("failed") and f"FAILED ({r['failed']})" or str(r.get("status", "—"))
            size = f" {r['bytes']}B" if r.get("bytes") else ""
            ms = f" {r['ms']}ms" if r.get("ms") is not None else ""
            return f"{status} {r.get('method', 'GET')} {r.get('type', '')}{ms}{size} {r.get('url', '')}"
        head = "listening from now on — only files the page loaded are listed from before\n" if a.get("since") == "now" else ""
        return [text(head + ("\n".join(row(r) for r in reqs[-200:]) or "no requests"))]

    if name == "batch":
        steps = [step(s) for s in args["steps"]]
        a = ask(with_tab({"do": "a.batch", "steps": steps, "keepGoing": bool(args.get("keepGoing"))}, args), timeout=150)
        out = []
        for n, (s, r) in enumerate(zip(steps, a.get("results", []))):
            out.append(f"{n + 1}. {s['do'][2:]}: " + (f"error: {r['error']}" if "error" in r else said(s["do"], r)))
        if "stopped" in a:
            out.append(f"stopped at step {a['stopped'] + 1}")
        return [text("\n".join(out))]

    if name == "computer":
        action = args["action"]
        req = with_tab({}, args)
        if args.get("coordinate"):
            req["x"], req["y"] = float(args["coordinate"][0]), float(args["coordinate"][1])
        if args.get("ref"):
            req["ref"] = args["ref"]
        if action == "screenshot":
            req["do"] = "a.shot"
            a = ask(req)
            where = f"{a['width']}×{a['height']}"
            where += f" — the element, from ({a['left']}, {a['top']}) on the page" if args.get("ref") else " — coordinates on this picture are the ones to click"
            return [{"type": "image", "data": a["jpeg"], "mimeType": "image/jpeg"}, text(where)]
        if action == "left_click_drag":
            req["do"] = "a.drag"
            if args.get("to_ref"):
                req["toRef"] = args["to_ref"]
            if args.get("to_coordinate"):
                req["toX"], req["toY"] = float(args["to_coordinate"][0]), float(args["to_coordinate"][1])
            return [text(said("a.drag", ask(req)))]
        if action in ("left_click", "double_click", "triple_click", "right_click"):
            req["do"] = "a.click"
            req["button"] = {"left_click": "left", "double_click": "double", "triple_click": "triple", "right_click": "right"}[action]
            if args.get("modifiers"):
                req["mods"] = args["modifiers"]
            return [text(said("a.click", ask(req)))]
        if action == "hover":
            req["do"] = "a.hover"
            return [text(said("a.hover", ask(req)))]
        if action == "type":
            req["do"] = "a.type"
            req["text"] = args.get("text", "")
            if args.get("keys"):
                req["keys"] = True
            return [text(said("a.type", ask(req)))]
        if action == "key":
            req["do"] = "a.key"
            req["keys"] = args.get("text", "")
            if args.get("repeat"):
                req["repeat"] = int(args["repeat"])
            return [text(said("a.key", ask(req)))]
        if action in ("scroll", "scroll_to"):
            req["do"] = "a.scroll"
            if action == "scroll":
                amount = float(args.get("scroll_amount", 3)) * 100
                direction = args.get("scroll_direction", "down")
                req["dx"] = {"left": -amount, "right": amount}.get(direction, 0)
                req["dy"] = {"up": -amount, "down": amount}.get(direction, 0)
            return [text(said("a.scroll", ask(req)))]
        if action == "wait":
            import time
            time.sleep(max(0, min(30, float(args.get("duration", 1)))))
            return [text("waited")]
        raise Refused(f"unknown action {action}")

    raise Refused(f"unknown tool {name}")


# MARK: - MCP over stdio

def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    # UTF-8 both ways, whatever the locale Claude Code starts this in.
    sys.stdin.reconfigure(encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        method, mid = message.get("method"), message.get("id")
        if mid is None:
            continue  # a notification
        try:
            if method == "initialize":
                result = {
                    "protocolVersion": message.get("params", {}).get("protocolVersion", "2024-11-05"),
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "search", "version": VERSION},
                    "instructions": (
                        "Claude in Search: use the Search browser on this Mac. Start with tabs_context. "
                        "Prefer read_page/find and refs over screenshots: they are exact and take milliseconds. "
                        "Use batch to do several steps in one call. For web development: pages on localhost keep their console "
                        "and requests from the first line (read_console_messages, read_network_requests); navigate with url "
                        "\"hard\" after changing files; resize_page for phones; dialogs never block."
                    ),
                }
            elif method == "tools/list":
                result = {"tools": TOOLS}
            elif method == "tools/call":
                params = message.get("params", {})
                try:
                    result = {"content": call(params.get("name"), params.get("arguments") or {})}
                except Refused as e:
                    result = {"content": [text(f"Error: {e}")], "isError": True}
                except (socket.timeout, OSError) as e:
                    result = {"content": [text(f"Error: Search didn't answer ({e})")], "isError": True}
            elif method == "ping":
                result = {}
            else:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"no method {method}"}})
                continue
            send({"jsonrpc": "2.0", "id": mid, "result": result})
        except Exception as e:  # never die on one bad call
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": str(e)}})


if __name__ == "__main__":
    main()
