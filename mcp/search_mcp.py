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
import os
import socket
import sys

WORLD = os.environ.get("SEARCH_WORLD", "").strip().lower()
FOLDER = os.path.expanduser(f"~/Library/Application Support/Search ({WORLD})" if WORLD else "~/Library/Application Support/Search")
SOCKET = os.path.join(FOLDER, "bench.sock")
VERSION = "1.0.0"

# The tab Claude last opened or used: the one a call without a tabId means.
current = {"id": None}


class Refused(Exception):
    pass


def ask(request, timeout=130):
    """One request, one answer, over the socket."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(SOCKET)
    except (FileNotFoundError, ConnectionRefusedError):
        raise Refused("Search isn't listening. Open Search and turn on Settings › General › "
                      "“Let a script drive Search”.")
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
        raise Refused(str(answer["error"]))
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
        "description": "Open a new tab of Claude's own at a URL and wait for it to load. It opens at the end of the row with a flask, out of the user's way. show: true brings it to the front (needs “Let Claude use your tabs”).",
        "inputSchema": {"type": "object", "properties": {
            "url": {"type": "string"}, "show": {"type": "boolean"}}, "required": ["url"]},
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
        "description": "Go to a URL in a tab, or back, forward, reload; waits for the page to load.",
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB, "url": {"type": "string", "description": "A URL, or back, forward, reload."}}, "required": ["url"]},
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
            "- screenshot: a JPEG of what is on screen; 1 pixel = 1 CSS pixel, so its coordinates are the ones to click.\n"
            "- left_click, double_click, triple_click, right_click, hover: at ref (preferred — scrolled into view first) or coordinate [x, y]. modifiers: e.g. \"cmd\" or \"shift+cmd\".\n"
            "- type: text into the focused field (ref: click that field first). Inserted in one go, like Chrome's; keys: true presses a key per character instead.\n"
            "- key: space-separated chords, e.g. \"Enter\", \"cmd+a Backspace\", \"shift+Tab\", \"ArrowDown ArrowDown Enter\". repeat: how many times.\n"
            "- scroll: scroll_direction up/down/left/right, scroll_amount in ticks of 100px (default 3), at ref or coordinate (scrolls what is under it) or the page.\n"
            "- scroll_to: bring ref into view.\n"
            "- wait: duration seconds (max 30)."
        ),
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB,
            "action": {"type": "string", "enum": ["screenshot", "left_click", "double_click", "triple_click", "right_click", "hover", "type", "key", "scroll", "scroll_to", "wait"]},
            "ref": REF,
            "coordinate": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2},
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
        "name": "wait_for",
        "description": "Wait until a CSS selector matches or some text is on the page (default up to 10 s).",
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB, "selector": {"type": "string"}, "text": {"type": "string"}, "seconds": {"type": "number"}}},
    },
    {
        "name": "javascript_tool",
        "description": "Run JavaScript in the page and get its value back: an expression, or a function body that returns. Promises are awaited. world: page (default, the page's own globals) or search (an isolated world the page can't see).",
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB, "code": {"type": "string"}, "world": {"type": "string", "enum": ["page", "search"]}}, "required": ["code"]},
    },
    {
        "name": "read_console_messages",
        "description": "Console messages and uncaught errors on the page. Listening starts at the first call on a page: call once before doing what you want to watch. pattern: a regex to keep only matching lines. onlyErrors: errors and exceptions only. clear: empty the buffer after reading.",
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB, "pattern": {"type": "string"}, "onlyErrors": {"type": "boolean"}, "clear": {"type": "boolean"}}},
    },
    {
        "name": "read_network_requests",
        "description": "What the page loaded — the document and each resource, with type, duration, size and status where known — from the page's own timing records. pattern: a regex on the URL.",
        "inputSchema": {"type": "object", "properties": {"tabId": TAB, "pattern": {"type": "string"}}},
    },
    {
        "name": "batch",
        "description": (
            "Several steps in one call, in order, stopping at the first error (keepGoing: true to go on). "
            "Each step is {\"do\": ..., ...} with the same fields as the tools: "
            "read, find, text, click (ref|coordinate, button: left|double|triple|right), hover, type (text, ref?, keys?), "
            "key (keys), fill (ref, value), scroll (dx, dy, ref?|coordinate?), navigate (url), wait (selector|text, seconds), js (code). "
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
    if verb == "js" and "world" in s and s["world"] != "search":
        s.pop("world")
    names = {"read": "a.read", "find": "a.find", "text": "a.text", "click": "a.click", "hover": "a.hover", "type": "a.type",
             "key": "a.key", "fill": "a.fill", "scroll": "a.scroll", "navigate": "a.navigate", "wait": "a.wait", "js": "a.js",
             "focus": "a.focus"}
    if verb not in names:
        raise Refused(f"batch: unknown step “{verb}”")
    s["do"] = names[verb]
    return s


def said(verb, answer):
    """A bench answer as a few lines for Claude."""
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
    return json.dumps({k: v for k, v in answer.items() if k not in ("tab",)}, ensure_ascii=False)


def call(name, args):
    if name == "tabs_context":
        a = ask({"do": "a.tabs"})
        lines = [tab_line(t) for t in a.get("tabs", [])]
        note = "" if a.get("yours") else "\n\nClaude can use only the tabs marked [claude]. Settings › General › “Let Claude use your tabs” opens the others."
        return [text("\n".join(lines) + note)]

    if name == "tabs_create":
        a = ask({"do": "a.open", "url": args["url"], "show": bool(args.get("show"))})
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
        for k in ("selector", "text"):
            if args.get(k):
                req[k] = args[k]
        return [text(said("a.wait", ask(req, timeout=float(args.get("seconds", 10)) + 15)))]

    if name == "javascript_tool":
        req = with_tab({"do": "a.js", "code": args["code"]}, args)
        if args.get("world") == "search":
            req["world"] = "search"
        return [text(said("a.js", ask(req)))]

    if name == "read_console_messages":
        a = ask(with_tab({"do": "a.console", "clear": bool(args.get("clear"))}, args))
        messages = a.get("messages", [])
        if args.get("onlyErrors"):
            messages = [m for m in messages if m["level"] in ("error", "exception")]
        if args.get("pattern"):
            import re
            rx = re.compile(args["pattern"])
            messages = [m for m in messages if rx.search(m["text"])]
        lines = [f"[{m['level']}] {m['text']}" for m in messages[-200:]]
        return [text((f"listening since {a.get('since')}\n" if a.get("since", "").startswith("now") else "") + ("\n".join(lines) or "no messages"))]

    if name == "read_network_requests":
        a = ask(with_tab({"do": "a.network"}, args))
        reqs = a.get("requests", [])
        if args.get("pattern"):
            import re
            rx = re.compile(args["pattern"])
            reqs = [r for r in reqs if rx.search(r["url"])]
        lines = [f"{r.get('status', '')} {r['type']} {r['ms']}ms {r.get('bytes', '')} {r['url']}".strip() for r in reqs[-200:]]
        return [text("\n".join(lines) or "no requests")]

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
            return [
                {"type": "image", "data": a["jpeg"], "mimeType": "image/jpeg"},
                text(f"{a['width']}×{a['height']} — coordinates on this picture are the ones to click"),
            ]
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
                        "Use batch to do several steps in one call."
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
