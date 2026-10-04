#!/usr/bin/env python3
"""Claude's access levels, checked against a test run of Search.

    python3 mcp/tests/access.py PATH/TO/Search.app

Starts the app given under SEARCH_PROBE=claudeaccess — a world of its own,
nothing of yours in it — serves a few pages from this Mac, and checks what
each level of Settings › General › "Let Claude use Search" lets Claude see
and do over the socket: whose tabs, whose cookies, the clipboard, a batch
whose script went away, a large upload, the console a page can't rewrite,
an idle wait beside a request that never ends, and the setting kept from one
launch to the next, with the keychain mark behind it (SEARCH_CONSENT=real).

Only the world's own folder, settings suite and the processes it starts are
touched; GIFs it writes into Downloads are removed again.
"""

import base64
import http.server
import json
import os
import socket
import subprocess
import sys
import threading
import time

WORLD = "claudeaccess"
SUITE = f"com.officecommun.search.test.{WORLD}"
FOLDER = os.path.expanduser(f"~/Library/Application Support/Search ({WORLD})")
SOCKET = os.path.join(FOLDER, "bench.sock")

failures = []


def check(what, ok, detail=""):
    print(("  ok   " if ok else "  FAIL ") + what + (f" — {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(what)


# MARK: - pages from this Mac

class Pages(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path.startswith("/hang"):
            # A request that stays open: a long poll, answered only after
            # every wait in here is over.
            time.sleep(40)
            try:
                self.send_response(204)
                self.end_headers()
            except OSError:
                pass
            return
        body = {
            "/": "<title>plain</title><p>plain page</p><input id=f><input type=file id=up>",
            "/frame": f"<title>framed</title><p>outer</p><iframe src='http://127.0.0.1:{PORT}/inner' width=300 height=100></iframe>",
            "/inner": "<button>inside the frame</button>",
            "/longpoll": "<title>long</title><script>fetch('/hang');</script><p>polling</p>",
        }.get(self.path.split("?")[0], "<title>none</title>")
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Pages)
PORT = server.server_address[1]
threading.Thread(target=server.serve_forever, daemon=True).start()
PAGE = f"http://localhost:{PORT}"


# MARK: - the socket

def ask(request, timeout=60, hold=True):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(SOCKET)
    s.sendall((json.dumps(request) + "\n").encode())
    if not hold:
        return s
    chunks = []
    while True:
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        chunks.append(chunk)
    s.close()
    return json.loads(b"".join(chunks).split(b"\n", 1)[0] or b"{}")


def listening():
    try:
        ask({"do": "a.tabs"}, timeout=3)
        return True
    except OSError:
        return False


# MARK: - the app

app_path = None
process = None


def defaults(*args):
    subprocess.run(["defaults", *args], capture_output=True)


def launch(strict=False, expect_socket=True):
    global process
    env = dict(os.environ, SEARCH_PROBE=WORLD)
    env.pop("SEARCH_CONSENT", None)
    if strict:
        env["SEARCH_CONSENT"] = "real"
    process = subprocess.Popen([os.path.join(app_path, "Contents/MacOS/Search")], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        time.sleep(0.25)
        if os.path.exists(SOCKET) and listening():
            return True
    if expect_socket:
        sys.exit("the test run never listened")
    return False


def quit_app():
    global process
    if process is None:
        return
    # A setting just changed is on its way to cfprefsd; a quit with ⌘Q waits
    # for it, a SIGTERM doesn't.
    time.sleep(1)
    process.terminate()
    try:
        process.wait(10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    process = None
    # Settings reach cfprefsd at once; a beat for it all the same.
    time.sleep(0.5)


def level(n):
    return ask({"do": "consent", "set": n})


def bench_tab(url):
    return ask({"do": "a.open", "url": url})["id"]


def js(code, tab):
    out = ask({"do": "a.js", "code": code, "id": tab})
    return out.get("value", out.get("error"))


def your_tab(url):
    """A tab of yours, as a person opens one: through a bookmark, into a new tab."""
    ask({"do": "bookmark", "url": url, "new": True}, timeout=30)
    tabs = ask({"do": "tabs"})["tabs"]
    return next(t["id"] for t in tabs if t["active"])


# MARK: - the checks

def levels():
    print("whose tabs, at each level")
    level(3)
    yours = your_tab(PAGE + "/?yours")
    # A private tab: ⇧⌘N, then a page in it.
    ask({"do": "press", "code": 45, "chars": "n", "mods": ["cmd", "shift"]})
    ask({"do": "bookmark", "url": PAGE + "/?private"}, timeout=30)
    private = next(t["id"] for t in ask({"do": "tabs"})["tabs"] if t["shy"])
    seen = {t["id"] for t in ask({"do": "a.tabs"})["tabs"]}
    check("Your tabs too: Claude sees your tab", yours in seen)
    check("Your tabs too: never a private tab", private not in seen)
    check("Your tabs too: reads your tab", "error" not in ask({"do": "a.read", "id": yours}))
    for n, name in ((2, "Signed in as you"), (1, "Its own tabs")):
        level(n)
        a = ask({"do": "a.tabs"})
        check(f"{name}: your tab not listed", yours not in {t["id"] for t in a["tabs"]})
        check(f"{name}: your tab can't be read", "error" in ask({"do": "a.read", "id": yours}))
        check(f"{name}: no tab in front to take", "error" in ask({"do": "a.show", "id": yours}))
    ask({"do": "a.close", "id": "all"})
    return yours


def cookies(yours):
    print("whose cookies")
    level(3)
    ask({"do": "eval", "id": yours, "js": "document.cookie = 'mine=yes; path=/'; document.cookie"})
    level(2)
    signed = bench_tab(PAGE + "/?claude")
    check("Signed in as you: Claude's tab has your cookie", "mine=yes" in str(js("document.cookie", signed)))
    level(1)
    check("lowering to Its own tabs closes Claude's signed-in tab", signed not in {t["id"] for t in ask({"do": "a.tabs"})["tabs"]})
    own = bench_tab(PAGE + "/?claude")
    check("Its own tabs: Claude's tab hasn't your cookie", "mine=yes" not in str(js("document.cookie", own)))
    js("document.cookie = 'claude=own; path=/'", own)
    level(2)
    check("raising from Its own tabs closes the tab in Claude's store", own not in {t["id"] for t in ask({"do": "a.tabs"})["tabs"]})
    ask({"do": "a.close", "id": "all"})


def clipboard():
    print("the clipboard")
    for n, name in ((1, "Its own tabs"), (2, "Signed in as you")):
        level(n)
        tab = bench_tab(PAGE + "/")
        for keys in ("cmd+v", "cmd+c", "cmd+x"):
            check(f"{name}: {keys} refused", "error" in ask({"do": "a.key", "keys": keys, "id": tab}))
        check(f"{name}: cmd+a still works", "error" not in ask({"do": "a.key", "keys": "cmd+a", "id": tab}))
        ask({"do": "a.close", "id": tab})


def batch():
    print("a batch whose script went away")
    level(2)
    tab = bench_tab(PAGE + "/")
    steps = [{"do": "a.wait", "selector": "#never", "seconds": 3}, {"do": "a.js", "code": "window.__ran = 1"}]
    s = ask({"do": "a.batch", "id": tab, "steps": steps, "keepGoing": True}, hold=False)
    time.sleep(0.5)
    s.close()
    time.sleep(5)
    check("no step runs after the script is gone", js("window.__ran === undefined", tab) is True)
    out = ask({"do": "a.batch", "id": tab, "steps": steps, "keepGoing": True})
    check("held, the same batch runs to the end", js("window.__ran", tab) == 1, json.dumps(out)[:200])
    ask({"do": "a.close", "id": tab})


def upload():
    print("a large upload")
    level(2)
    tab = bench_tab(PAGE + "/")
    data = base64.b64encode(os.urandom(24_000_000 - 1024)).decode()
    started = time.time()
    out = ask({"do": "a.upload", "id": tab, "selector": "#up", "files": [{"name": "big.bin", "type": "", "data": data}]}, timeout=120)
    took = time.time() - started
    check("24 MB arrives and is put in the field", out.get("files") == 1, json.dumps(out)[:200])
    check(f"…in under 8 s (took {took:.1f})", took < 8)
    ask({"do": "a.close", "id": tab})


def console_and_idle():
    print("the console and the idle wait")
    level(2)
    tab = bench_tab(PAGE + "/")
    js("console.log('heard-before'); var b = window[Symbol.for('search.claude')];"
       "try { b.read = function () { return []; }; } catch (e) {}"
       "try { b.open = null; } catch (e) {} 1", tab)
    messages = ask({"do": "a.console", "id": tab}).get("messages", [])
    check("a page can't rewrite what Claude hears", any("heard-before" in m["text"] for m in messages), json.dumps(messages)[:200])
    poll = bench_tab(PAGE + "/longpoll")
    started = time.time()
    out = ask({"do": "a.wait", "id": poll, "idle": True, "seconds": 20}, timeout=40)
    took = time.time() - started
    check("idle comes beside a request that never ends", out.get("idle") is True and out.get("longRequests", 0) >= 1, json.dumps(out))
    check(f"…after about ten seconds (took {took:.1f})", 9 <= took <= 14)
    ask({"do": "a.close", "id": "all"})


def frames_and_gif():
    print("frames from another site, and recordings")
    level(2)
    tab = bench_tab(PAGE + "/frame")
    page = ask({"do": "a.read", "id": tab}).get("page", "")
    check("a frame from another site is still read", "inside the frame" in page and "f1." in page, page[-300:])
    shot = ask({"do": "a.shot", "id": tab, "scale": 0.3})
    frames = [{"jpeg": shot["jpeg"], "pageWidth": shot["pageWidth"], "label": "test"}]
    name = f"claude-access-test-{os.getpid()}.gif"
    first = ask({"do": "a.gif", "frames": frames, "name": name})
    second = ask({"do": "a.gif", "frames": frames, "name": name})
    check("a second recording of the same name doesn't overwrite the first",
          first.get("path") and second.get("path") and first["path"] != second["path"], f"{first} {second}")
    for out in (first, second):
        if out.get("path") and os.path.basename(out["path"]).startswith("claude-access-test-"):
            os.remove(out["path"])
    ask({"do": "a.close", "id": "all"})


def persistence():
    print("kept from one launch to the next")
    level(2)
    quit_app()
    launch()
    check("the level comes back after a relaunch", ask({"do": "consent"})["level"] == 2)
    level(0)
    quit_app()
    check("off: the socket stays closed at the next launch", not launch(expect_socket=False))
    quit_app()


def strict():
    print("the keychain mark (SEARCH_CONSENT=real)")
    # The mark, set to 1 from a run that may write it.
    defaults("write", SUITE, "claude.access", "-int", "1")
    launch()
    ask({"do": "consent", "action": "grant", "level": 1})
    after = ask({"do": "consent"})["after"]
    quit_app()
    if after == 0:
        check("the mark is written", False, "Consent.grant left nothing")
        return
    if after > 3:
        print("  skip this build has no keychain access group (no provisioning profile): the mark can't be kept, and the setting is taken as written")
        return
    # Raised behind Settings' back.
    defaults("write", SUITE, "claude.access", "-int", "3")
    launch(strict=True)
    state = ask({"do": "consent"})
    check("a level the mark doesn't back is held at the mark's", state["level"] == 1, json.dumps(state))
    check("…and asked about", state["asking"] == 3, json.dumps(state))
    yours = your_tab(PAGE + "/?strict")
    raw = {t["id"] for t in ask({"do": "tabs"})["tabs"]}
    check("the socket's own tabs lists none of yours below Your tabs too", yours not in raw)
    check("the socket won't open a file", "error" in ask({"do": "open", "url": "file:///etc/hosts"}))
    level(3)
    raw = {t["id"] for t in ask({"do": "tabs"})["tabs"]}
    check("at Your tabs too, the socket's tabs lists yours", yours in raw)
    quit_app()
    launch(strict=True)
    state = ask({"do": "consent"})
    check("set in Settings, it comes back after a relaunch, unasked", state["level"] == 3 and state["asking"] == 0, json.dumps(state))
    ask({"do": "consent", "action": "revoke"})
    quit_app()


def main():
    global app_path
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    app_path = os.path.abspath(sys.argv[1])
    if os.path.exists(SOCKET) and listening():
        sys.exit(f"something is already listening for the world {WORLD}: quit it first")
    defaults("delete", SUITE)
    defaults("write", SUITE, "claude.access", "-int", "2")
    defaults("write", SUITE, "welcomed", "-bool", "true")
    launch()
    try:
        yours = levels()
        cookies(yours)
        clipboard()
        batch()
        upload()
        console_and_idle()
        frames_and_gif()
        persistence()
        strict()
    finally:
        quit_app()
        server.shutdown()
    print(f"\n{len(failures)} failed" if failures else "\nall passed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
