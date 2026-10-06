#!/usr/bin/env python3
"""Claude in Search: an MCP server that lets Claude use the Search browser.

    claude mcp add --scope user search -- python3 /Applications/Search.app/Contents/Resources/search_mcp.py

Settings › General › "Let Claude use Search" › Connect Claude Code does that
for you, and checks the connection. This file ships inside the app.

It speaks MCP over stdio and drives Search through the bench's socket (see
Sources/Search/Bench.swift and Agent.swift). Nothing to install: Python 3's
standard library only.

In Search: Settings › General › "Let Claude use Search" on, at one of three
levels. "Its own tabs": Claude works only in tabs it opens, marked with a
flask, signed in to nothing of yours. "Signed in as you": the same tabs, with
your sign-ins. "Your tabs too": also the tab in front and the others you have
open, and the clipboard. Claude's tabs never take the window from you.

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

# Search answers for every request within its own time (Bench.agentPatience:
# 30 s, a batch 170, a wait or navigate its seconds + 5) and then stops work
# on it; the socket waits longer than that, so a slow request is told as
# Search's answer rather than as silence while its steps go on.
PATIENCE = 10

# Who is asking, for Settings › General's "Claude last used Search".
FROM = os.environ.get("SEARCH_MCP_FROM", "claude")

# The tab Claude last opened or used: the one a call without a tabId means.
current = {"id": None}
# The last screenshots, by the id each was given, for upload_image.
shots = {}
shot_order = []
# gif_creator's frames, while recording or until exported or cleared.
recording = {"on": False, "frames": []}


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
                  "“Let Claude use Search”.")


def ask(request, timeout=30 + PATIENCE):
    """One request, one answer, over the socket."""
    # Said with every request, so Settings can show when Claude last used
    # Search; its own connection check says "settings" instead.
    request.setdefault("from", FROM)
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
    mark = ("claude, private" if t.get("shy") else "claude") if t.get("bench") else ("front" if t.get("active") else "yours")
    state = " (loading)" if t.get("loading") else (" (asleep)" if t.get("asleep") else "")
    return f"{t['id']}  [{mark}]  {t.get('title') or '—'}  {t.get('url')}{state}"


def keep_shot(answer):
    """A screenshot kept under an id of its own, the last 20 of them."""
    n = (int(shot_order[-1].split("_")[1]) + 1) if shot_order else 1
    image_id = f"img_{n}"
    shots[image_id] = answer["jpeg"]
    shot_order.append(image_id)
    while len(shot_order) > 20:
        shots.pop(shot_order.pop(0), None)
    return image_id


def frame(args, label, click=None, drag=None, answer=None):
    """While recording: the page as it is now, with what was just done."""
    if not recording["on"]:
        return
    try:
        a = answer or ask(with_tab({"do": "a.shot", "quality": 0.5, "scale": 0.75}, args))
    except Exception:
        return
    recording["frames"].append({"jpeg": a["jpeg"], "pageWidth": a.get("pageWidth", a["width"]), "label": label,
                                **({"click": click} if click else {}), **({"drag": drag} if drag else {})})
    del recording["frames"][:-200]


def spot(args, answer):
    """Where an action landed, in page coordinates: the answer's, or the one given."""
    at = answer.get("at") if isinstance(answer, dict) else None
    if at and len(at) == 2:
        return [float(at[0]), float(at[1])]
    if args.get("coordinate"):
        return [float(args["coordinate"][0]), float(args["coordinate"][1])]
    return None


# MARK: - the tools

TAB = {"type": "string", "description": "The tab's id from tabs_context. Leave out for the tab Claude last opened or used (or, with “Let Claude use Search” at “Your tabs too”, the one in front)."}
REF = {"type": "string", "description": "An element's ref from read_page or find, like r12."}

TOOLS = [
    {
        "name": "tabs_context",
        "description": "List Search's tabs: their ids, titles, addresses, which one is in front, and which ones Claude opened. Call this first. Claude can use the tabs it opened; the user's own only if they set “Let Claude use Search” to “Your tabs too”.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "tabs_create",
        "description": "Open a new tab of Claude's own at a URL (localhost works) and wait for it to load. It opens at the end of the row with a flask, out of the user's way, 1280×800 unless width and height say otherwise. mobile: true loads it with an iPhone user agent from the first request — with width 390 and height 844, a phone. private: true opens it in a cookie jar of its own that starts empty, with no extensions: signed in to nothing, the user's accounts or Claude's — the site as a signed-out visitor sees it, scripts and all; windows its pages open stay private, and it is all gone when the tab closes. Use it to see a site signed out: never sign the user out for that, which would sign them out everywhere. show: true brings it to the front (needs “Let Claude use Search” at “Your tabs too”).",
        "inputSchema": {"type": "object", "properties": {
            "url": {"type": "string"}, "show": {"type": "boolean"},
            "width": {"type": "number"}, "height": {"type": "number"}, "mobile": {"type": "boolean"},
            "private": {"type": "boolean"}}, "required": ["url"]},
    },
    {
        "name": "resize_page",
        "description": "Give a tab of Claude's another viewport size, to check a layout: e.g. 390×844 with mobile: true for a phone, 820×1180 for a tablet, 1920×1080. mobile: true switches to an iPhone user agent, mobile: false back to the Mac's; either change reloads the page, so the site serves what it serves a phone. Answers once the page has laid itself out at the new size. A tab in the user's window keeps the size there too, in the middle. Only Claude's own tabs.",
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
        "description": "Bring a tab to the front of the user's window, so they can watch — at the size resize_page or tabs_create gave it, if they gave one. Needs “Let Claude use Search” at “Your tabs too”.",
        "inputSchema": {"type": "object", "properties": {"tabId": TAB}},
    },
    {
        "name": "navigate",
        "description": "Go to a URL in a tab, or back, forward, reload, hard (every file checked with the server and the site's service-worker caches dropped — after changing a file, as ⇧⌘R does), or empty (the site's whole cache emptied first, for a server that says a changed file hasn't changed; slower to start); waits for the page to load.",
        "inputSchema": {"type": "object", "properties": {
            "tabId": {"type": "string", "description": "The tab's id from tabs_context. Leave out for the tab Claude last opened or used; with none yet, a new tab of Claude's own is opened — never the user's tab in front."},
            "url": {"type": "string", "description": "A URL, or back, forward, reload, hard, empty."}}, "required": ["url"]},
    },
    {
        "name": "read_page",
        "description": "What can be used on the page, one element per line with a ref: links, buttons, fields (with their values), checkboxes, headings, dialogs, and file fields even when hidden. Each line ends with @x,y, its middle in screenshot coordinates, or (offscreen). Frames from other sites — a payment form, an embedded widget — are read too, below the page: their refs are named after the frame (f1.r4) and work with every tool. Refs stay the same for the same element across reads. filter: interactive (default) or all (adds images and other labeled elements). ref: read only under that element. Fast: a few milliseconds.",
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
            "- screenshot: a JPEG of what is on screen; 1 pixel = 1 CSS pixel, so its coordinates are the ones to click. With ref: just that element. scale (0.1–1): a smaller picture for fewer tokens — coordinates stay the page's. save_to_disk: also written to a file, for the user. Each screenshot has an imageId for upload_image.\n"
            "- zoom: region [x0, y0, x1, y1] in page coordinates, drawn at twice the density — to read small text or icons.\n"
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
            "action": {"type": "string", "enum": ["screenshot", "zoom", "left_click", "double_click", "triple_click", "right_click", "hover", "left_click_drag", "type", "key", "scroll", "scroll_to", "wait"]},
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
            "region": {"type": "array", "items": {"type": "number"}, "minItems": 4, "maxItems": 4},
            "scale": {"type": "number", "minimum": 0.1, "maximum": 1},
            "save_to_disk": {"type": "boolean"},
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
        "name": "upload_image",
        "description": "Put a screenshot taken with computer screenshot or zoom (its imageId) into a file field, or drop it on the page: ref for a field or drop zone (a hidden file input too), or coordinate [x, y] to drop it where that is, as a drag from the desktop would. Take the screenshot just before; filename is optional.",
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB, "imageId": {"type": "string"}, "ref": REF,
            "coordinate": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2},
            "filename": {"type": "string"}}, "required": ["imageId"]},
    },
    {
        "name": "gif_creator",
        "description": "Record what is done in the browser as an animated GIF. start_recording, then act — every computer action and navigation adds a frame, with clicks, drags and what was done drawn on it; take a screenshot right after starting and right before stopping for the first and last frames. stop_recording keeps the frames; export writes the GIF into the Downloads folder (download: true) or drops it on the page at coordinate; clear discards the frames. options: showClickIndicators, showDragPaths, showActionLabels, showProgressBar (all on by default).",
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB,
            "action": {"type": "string", "enum": ["start_recording", "stop_recording", "export", "clear"]},
            "download": {"type": "boolean"}, "filename": {"type": "string"},
            "coordinate": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2},
            "options": {"type": "object"}}, "required": ["action"]},
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
        "description": "Run JavaScript in the page, with the page's own globals, and get its value back as a console gives it: top-level await works, and the last expression's value is returned (`const r = await fetch(u); r.status` answers the status), or a body's `return`. An error is reported; code is never run twice.",
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB, "code": {"type": "string"}}, "required": ["code"]},
    },
    {
        "name": "read_console_messages",
        "description": "Console messages, uncaught errors and rejections, files that failed to load and blocked content. Claude's own tabs and pages from this Mac (localhost, *.local, *.test) are heard from the first line of the page; any other page from the first call on it. pattern: a regex to keep only matching lines. onlyErrors: errors and exceptions only. clear: empty the buffer after reading. limit: the last this many (default 100).",
        "inputSchema": {"type": "object", "properties": {
            "tabId": TAB, "pattern": {"type": "string"}, "onlyErrors": {"type": "boolean"}, "clear": {"type": "boolean"}, "limit": {"type": "integer"}}},
    },
    {
        "name": "read_network_requests",
        "description": "What the page loaded and asked for: the document, each file, and every fetch and XHR with its method, status, time and failure. Heard from the first line in Claude's tabs and localhost pages. pattern: a regex on the URL. onlyFailed: 4xx, 5xx and failures only. clear: forget what was listed. limit: the last this many (default 100).",
        "inputSchema": {"type": "object", "properties": {"tabId": TAB, "pattern": {"type": "string"}, "onlyFailed": {"type": "boolean"}, "clear": {"type": "boolean"}, "limit": {"type": "integer"}}},
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
        level = a.get("level") or ""
        note = f"\n\nAccess: {level}." if a.get("yours") else (
            f"\n\nAccess: {level}. Claude can use only the tabs marked [claude]"
            + (", signed in to nothing of the user's" if level == "Its own tabs" else ", signed in as the user")
            + ". Settings › General › “Let Claude use Search” at “Your tabs too” opens the others.")
        return [text("\n".join(lines) + note)]

    if name == "tabs_create":
        req = {"do": "a.open", "url": args["url"], "show": bool(args.get("show"))}
        if args.get("width") and args.get("height"):
            req["width"], req["height"] = float(args["width"]), float(args["height"])
        if args.get("mobile"):
            req["mobile"] = True
        if args.get("private"):
            req["private"] = True
        a = ask(req)
        current["id"] = a.get("id")
        # A Search from before private tabs opens an ordinary one instead,
        # signed in wherever Claude's tabs are: it never passes for private.
        if args.get("private") and a.get("id"):
            tab = next((t for t in ask({"do": "a.tabs"}).get("tabs", []) if t.get("id") == a["id"]), None)
            if not (tab and tab.get("shy")):
                ask({"do": "a.close", "id": a["id"]})
                current["id"] = None
                raise Refused("this Search can't open a private tab yet — it needs updating. It opened an ordinary tab of Claude's instead, signed in as Claude's tabs are, and that tab is closed")
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
        words = f"{a['width']}×{a['height']}" + (" as a phone" if a.get("mobile") else "")
        if a.get("reloaded"):
            words += ", reloaded with that user agent"
        # A site's own zoom lays the page out at other numbers than it was given.
        page = a.get("page")
        if page and page != [a["width"], a["height"]]:
            words += f"; the page itself says {page[0]}×{page[1]}"
        if a.get("front"):
            words += " — in the user's window, shown at that size"
        return [text(words)]

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
        # Without a tabId, and no tab of Claude's in hand yet: a tab of its
        # own, as Claude in Chrome opens one — never the page in front of the
        # user, which an address would take them away from. Back, forward
        # and the reloads need a tab to act on.
        if not args.get("tabId") and not current["id"] and args["url"] not in ("back", "forward", "reload", "hard", "empty"):
            a = ask({"do": "a.open", "url": args["url"]})
        else:
            a = ask(with_tab({"do": "a.navigate", "url": args["url"]}, args))
        current["id"] = a.get("id") or current["id"]
        frame(args, "navigate " + args["url"])
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
        return [text(said("a.wait", ask(req, timeout=float(args.get("seconds", 10)) + 5 + PATIENCE)))]

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
        lines = [f"[{m['level']}] {m['text']}" for m in messages[-int(args.get("limit") or 100):]]
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
        return [text(head + ("\n".join(row(r) for r in reqs[-int(args.get("limit") or 100):]) or "no requests"))]

    if name == "batch":
        steps = [step(s) for s in args["steps"]]
        a = ask(with_tab({"do": "a.batch", "steps": steps, "keepGoing": bool(args.get("keepGoing"))}, args), timeout=170 + PATIENCE)
        out = []
        for n, (s, r) in enumerate(zip(steps, a.get("results", []))):
            out.append(f"{n + 1}. {s['do'][2:]}: " + (f"error: {r['error']}" if "error" in r else said(s["do"], r)))
        if "stopped" in a:
            out.append(f"stopped at step {a['stopped'] + 1}")
        return [text("\n".join(out))]

    if name == "upload_image":
        data = shots.get(args.get("imageId", ""))
        if not data:
            raise Refused(f"no screenshot {args.get('imageId')} — take one with computer screenshot and use its imageId")
        req = with_tab({"do": "a.upload", "files": [{"name": os.path.basename(args.get("filename") or "screenshot.jpg"), "type": "image/jpeg", "data": data}]}, args)
        if args.get("ref"):
            req["ref"] = args["ref"]
        elif args.get("coordinate"):
            req["x"], req["y"] = float(args["coordinate"][0]), float(args["coordinate"][1])
        else:
            raise Refused("upload_image needs a ref or a coordinate")
        a = ask(req)
        return [text(f"{a.get('files')} image " + ("put in the field" if a.get("into") == "field" else "dropped"))]

    if name == "gif_creator":
        action = args["action"]
        if action == "start_recording":
            recording.update(on=True, frames=[])
            return [text("recording — take a screenshot now for the first frame")]
        if action == "stop_recording":
            recording["on"] = False
            return [text(f"stopped with {len(recording['frames'])} frames")]
        if action == "clear":
            recording.update(on=False, frames=[])
            return [text("frames discarded")]
        if action == "export":
            if not recording["frames"]:
                raise Refused("no frames — start_recording, act, then export")
            a = ask({"do": "a.gif", "frames": recording["frames"], "options": args.get("options") or {}, "name": args.get("filename") or ""}, timeout=120)
            if args.get("coordinate"):
                with open(a["path"], "rb") as f:
                    gif = base64.b64encode(f.read()).decode()
                req = with_tab({"do": "a.upload", "x": float(args["coordinate"][0]), "y": float(args["coordinate"][1]),
                                "files": [{"name": os.path.basename(a["path"]), "type": "image/gif", "data": gif}]}, args)
                ask(req)
                return [text(f"{a['frames']} frames, {a['bytes'] // 1024} KB, dropped on the page — also at {a['path']}")]
            return [text(f"{a['frames']} frames, {a['bytes'] // 1024} KB: {a['path']}")]
        raise Refused(f"unknown action {action}")

    if name == "computer":
        action = args["action"]
        req = with_tab({}, args)
        if args.get("coordinate"):
            req["x"], req["y"] = float(args["coordinate"][0]), float(args["coordinate"][1])
        if args.get("ref"):
            req["ref"] = args["ref"]
        if action in ("screenshot", "zoom"):
            req["do"] = "a.shot"
            if args.get("scale"):
                req["scale"] = float(args["scale"])
            if action == "zoom":
                region = args.get("region") or []
                if len(region) != 4:
                    raise Refused("zoom needs region [x0, y0, x1, y1]")
                x0, y0, x1, y1 = (float(v) for v in region)
                req.update(x=min(x0, x1), y=min(y0, y1), w=abs(x1 - x0), h=abs(y1 - y0))
                req.pop("ref", None)
            a = ask(req)
            image_id = keep_shot(a)
            if action == "screenshot" and not args.get("ref"):
                frame(args, "screenshot", answer=a)
            page_w, page_h = a.get("pageWidth", a["width"]), a.get("pageHeight", a["height"])
            if action == "zoom":
                where = f"{a['width']}×{a['height']} picture of the page from ({a['left']}, {a['top']}) to ({a['left'] + page_w}, {a['top'] + page_h})"
            elif args.get("ref"):
                where = f"{a['width']}×{a['height']} — the element, from ({a['left']}, {a['top']}) on the page"
            elif a["width"] != page_w:
                where = f"{a['width']}×{a['height']}, scaled from {page_w}×{page_h} — click in the page's coordinates: multiply this picture's by {page_w / a['width']:.3g}"
            else:
                where = f"{a['width']}×{a['height']} — coordinates on this picture are the ones to click"
            where += f"\nimageId: {image_id}"
            if args.get("save_to_disk"):
                folder = os.path.join(os.path.expanduser("~/Downloads"), "Search screenshots")
                os.makedirs(folder, exist_ok=True)
                path = os.path.join(folder, time.strftime("screenshot %Y-%m-%d at %H.%M.%S") + f" {image_id}.jpg")
                with open(path, "wb") as f:
                    f.write(base64.b64decode(a["jpeg"]))
                where += f"\nsaved: {path}"
            return [{"type": "image", "data": a["jpeg"], "mimeType": "image/jpeg"}, text(where)]
        if action == "left_click_drag":
            req["do"] = "a.drag"
            if args.get("to_ref"):
                req["toRef"] = args["to_ref"]
            if args.get("to_coordinate"):
                req["toX"], req["toY"] = float(args["to_coordinate"][0]), float(args["to_coordinate"][1])
            a = ask(req)
            start = spot(args, a)
            end = [float(v) for v in args["to_coordinate"]] if args.get("to_coordinate") else None
            frame(args, "drag", drag=(start + end) if start and end else None)
            return [text(said("a.drag", a))]
        if action in ("left_click", "double_click", "triple_click", "right_click"):
            req["do"] = "a.click"
            req["button"] = {"left_click": "left", "double_click": "double", "triple_click": "triple", "right_click": "right"}[action]
            if args.get("modifiers"):
                req["mods"] = args["modifiers"]
            a = ask(req)
            frame(args, action.replace("_", " "), click=spot(args, a))
            return [text(said("a.click", a))]
        if action == "hover":
            req["do"] = "a.hover"
            a = ask(req)
            frame(args, "hover", click=spot(args, a))
            return [text(said("a.hover", a))]
        if action == "type":
            req["do"] = "a.type"
            req["text"] = args.get("text", "")
            if args.get("keys"):
                req["keys"] = True
            a = ask(req)
            frame(args, "type “" + (args.get("text", "")[:40]) + "”")
            return [text(said("a.type", a))]
        if action == "key":
            req["do"] = "a.key"
            req["keys"] = args.get("text", "")
            if args.get("repeat"):
                req["repeat"] = int(args["repeat"])
            a = ask(req)
            frame(args, "key " + args.get("text", ""))
            return [text(said("a.key", a))]
        if action in ("scroll", "scroll_to"):
            req["do"] = "a.scroll"
            if action == "scroll":
                amount = float(args.get("scroll_amount", 3)) * 100
                direction = args.get("scroll_direction", "down")
                req["dx"] = {"left": -amount, "right": amount}.get(direction, 0)
                req["dy"] = {"up": -amount, "down": amount}.get(direction, 0)
            a = ask(req)
            frame(args, "scroll " + args.get("scroll_direction", "") if action == "scroll" else "scroll to " + str(args.get("ref", "")))
            return [text(said("a.scroll", a))]
        if action == "wait":
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
                        "Prefer read_page/find and refs over screenshots: they are exact and take milliseconds, and reach into frames from other sites. "
                        "Pages in Claude's tabs behave as the page in front of a person does — visible, focused, hover opens menus. "
                        "Use batch to do several steps in one call. For web development: pages on localhost keep their console "
                        "and requests from the first line (read_console_messages, read_network_requests); navigate with url "
                        "\"hard\" after changing files; resize_page for phones; dialogs never block; gif_creator records a flow."
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
