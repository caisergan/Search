import AppKit
import WebKit

// Claude, in Search: what an assistant needs to use the browser the way a
// person does — read a page, point at what is on it, click, type, press keys,
// look — spoken over the bench's socket (see Bench.swift) by the MCP server
// in mcp/search_mcp.py. The verbs all start with "a.".
//
// Built for an assistant that pays for every round trip: a page is read once
// into a short list of what can be used on it, each thing with a ref that
// stays the same for the same element across reads; an action names a ref,
// not a selector that has to be guessed; a click or a key is a real event
// handed to the page's view, which a page can't tell from a hand's, where
// element.click() is ignored by half the sign-in forms around; a screenshot
// is a JPEG the size of the page's own CSS pixels, so a point on it is a
// point on the page; a click that loads a page answers once it has; and
// `a.batch` runs several steps in one request.
//
// And for building web pages with it: Claude's own tabs, and any page served
// from this Mac (localhost, *.local, *.test), keep their console, their
// errors and their requests from the first line of the page; a tab of
// Claude's can be any size, a phone's included; and nothing a page does can
// stop it — an alert, a confirm, a login prompt or a file chooser in a tab of
// Claude's is answered here instead of on a window nobody sees, where it
// would hold the page for good, and a pop-up it opens is Claude's too.
//
// The refs and the reading live in Search's own world (Web.world): the page
// sees none of it. Only what has to happen in the page's world does — its
// own JavaScript, and the console and requests, listened to there.
//
// Whose tabs: the ones Claude opened (the bench's, with the flask) always;
// yours, the one in front by default, only with Settings › General › "Let
// Claude use your tabs" on — and never a private one, nor an extension's
// page (a password manager's vault is one), nor a file. Claude opens and goes
// to web pages only. What it is told on a page is a page's to say: nothing
// here lets a page reach Search's own world, where its handlers are.

@MainActor
extension Bench {
    /// How long a verb may take before the bench answers for it.
    static func agentPatience(_ verb: String, _ request: [String: Any]) -> Double? {
        switch verb {
        case "a.wait", "a.navigate", "a.open": return (request["seconds"] as? Double ?? 20) + 5
        case "a.batch": return 170
        default: return verb.hasPrefix("a.") ? 30 : nil
        }
    }

    /// Whether Claude may use a tab at all.
    private func reachable(_ tab: Tab, in browser: Browser) -> Bool {
        guard tab.bench || (browser.prefs.claudeTabs && !tab.shy) else { return false }
        return tab.address.map(Bench.web) ?? true
    }

    /// Only web pages: never an extension's page or a file.
    static func web(_ url: URL) -> Bool {
        ["http", "https", "about", "data", "blob"].contains(url.scheme?.lowercased() ?? "")
    }

    /// The tab a request is for. Named by the first characters of its id;
    /// unnamed, the one in front.
    private func agentTab(_ request: [String: Any], in browser: Browser) -> Tab? {
        guard let ref = (request["id"] as? String)?.lowercased(), !ref.isEmpty else {
            return browser.active.flatMap { reachable($0, in: browser) ? $0 : nil }
        }
        return browser.tabs.first { $0.id.uuidString.lowercased().hasPrefix(ref) && reachable($0, in: browser) }
    }

    /// Ready to be read or used: awake, and in a window so it is laid out.
    private func ready(_ tab: Tab) {
        tab.wake()
        if tab.web.window == nil || Backstage.holds(tab.web) { house(tab, any: true) }
    }

    /// In the page's world or Search's, with what comes back as a dictionary.
    private func run(_ body: String, _ arguments: [String: Any], on tab: Tab, in world: WKContentWorld, _ then: @escaping (Result<[String: Any], Agent.Failure>) -> Void) {
        tab.web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let value): then(.success((value as? [String: Any]) ?? ["value": Bench.plain(value)]))
                case .failure(let error): then(.failure(Agent.Failure(said: Agent.said(error))))
                }
            }
        }
    }

    /// Search's side of the page (Agent.page) asked one thing.
    private func page(_ verb: String, _ request: [String: Any], on tab: Tab, _ then: @escaping (Result<[String: Any], Agent.Failure>) -> Void) {
        var arguments: [String: Any] = ["verb": verb]
        for key in ["filter", "ref", "query", "value", "dx", "dy", "x", "y", "max", "selector", "files", "toRef", "toX", "toY"] {
            if let value = request[key] { arguments[key] = value }
        }
        run(Agent.page, ["args": arguments], on: tab, in: Web.world, then)
    }

    func agent(_ verb: String, _ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let noTab: [String: Any] = ["error": browser.prefs.claudeTabs
            ? "no tab “\(request["id"] as? String ?? "")” Claude can use — see a.tabs (private tabs and extensions' pages are never Claude's)"
            : "no tab — Claude can use only the tabs it opened; Settings › General › “Let Claude use your tabs” lets it use yours"]
        let reply: (Result<[String: Any], Agent.Failure>) -> Void = { result in
            switch result {
            case .success(let out): answer(out)
            case .failure(let error): answer(["error": error.said])
            }
        }

        switch verb {
        case "a.tabs":
            // Only what Claude may use: with the switch off, your tabs'
            // addresses and titles are not its to see either.
            let seen = browser.tabs.filter { reachable($0, in: browser) }
            answer(["tabs": seen.map(describe), "yours": browser.prefs.claudeTabs, "others": browser.tabs.count - seen.count, "keysStopped": Agent.stopped])

        case "a.open":
            guard let url = (request["url"] as? String).flatMap(Address.url(from:)), Bench.web(url) else {
                answer(["error": "a.open needs a web address"])
                return
            }
            let tab = browser.benchOpen(url)
            if let size = Agent.size(request) { Agent.sizes[tab.id] = size }
            if request["show"] as? Bool == true, browser.prefs.claudeTabs { browser.select(tab) } else { house(tab) }
            if request["wait"] as? Bool == false { answer(describe(tab)); return }
            wait(for: tab, until: Date().addingTimeInterval(request["seconds"] as? Double ?? 20)) { [weak self] out in
                answer(self?.decorated(out, tab) ?? out)
            }

        case "a.show":
            guard browser.prefs.claudeTabs else {
                answer(["error": "showing a tab takes your window — only with “Let Claude use your tabs” on"])
                return
            }
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            // In your window, at your window's size.
            tab.web.autoresizingMask = [.width, .height]
            browser.select(tab)
            answer(describe(tab))

        case "a.close":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            guard tab.bench else { answer(["error": "Claude closes only the tabs it opened"]); return }
            browser.close(tab)
            forget(tab)
            answer(["closed": Bench.short(tab)])

        case "a.resize":
            // A tab of Claude's at any size: a phone's, a tablet's, a wide
            // screen's. Yours take the size of your window.
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            guard tab.bench else { answer(["error": "only Claude's own tabs can be resized — yours follow your window"]); return }
            guard let size = Agent.size(request) else { answer(["error": "a.resize needs width and height, 200 to 4000"]); return }
            guard tab.id != browser.activeID else { answer(["error": "the tab is in front, at your window's size — resize a tab that isn't shown"]); return }
            Agent.sizes[tab.id] = size
            if let mobile = request["mobile"] as? Bool { tab.web.customUserAgent = mobile ? Agent.phone : nil }
            tab.web.removeFromSuperview()
            ready(tab)
            // A beat for the page to lay itself out at its new size.
            tab.web.evaluateJavaScript("0") { _, _ in
                MainActor.assumeIsolated {
                    answer(["ok": true, "width": Int(size.width), "height": Int(size.height), "mobile": !(tab.web.customUserAgent ?? "").isEmpty])
                }
            }

        case "a.navigate":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            ready(tab)
            let to = request["url"] as? String ?? ""
            var url: URL?
            if !["back", "forward", "reload", "hard"].contains(to) {
                guard let web = Address.url(from: to), Bench.web(web) else { answer(["error": "a.navigate needs a web address, back, forward, reload or hard"]); return }
                url = web
            }
            let limit = Date().addingTimeInterval(request["seconds"] as? Double ?? 20)
            // The page there now is marked, in Search's world, so the new one
            // is known by not having the mark — even one that loads before
            // anyone sees it loading, as a page from this Mac does.
            tab.web.evaluateJavaScript("window.__claudeOld = 1", in: nil, in: Web.world) { [weak self] _ in
                MainActor.assumeIsolated {
                    switch to {
                    case "back": tab.back()
                    case "forward": tab.forward()
                    case "reload": tab.reload()
                    // This site's caches emptied first, service workers'
                    // included: what a developer means after changing a file (⇧⌘R).
                    case "hard": tab.reloadEmptied()
                    default: if let url { tab.go(to: url) }
                    }
                    self?.arrived(tab, within: to == "hard" ? 5 : 1.5) {
                        self?.wait(for: tab, until: limit) { out in answer(self?.decorated(out, tab) ?? out) }
                    }
                }
            }

        case "a.wait":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            ready(tab)
            let limit = Date().addingTimeInterval(request["seconds"] as? Double ?? 10)
            let selector = request["selector"] as? String
            let text = request["text"] as? String
            let idle = request["idle"] as? Bool == true
            guard selector != nil || text != nil || idle else {
                wait(for: tab, until: limit) { [weak self] out in answer(self?.decorated(out, tab) ?? out) }
                return
            }
            var quiet: Date?
            func poll() {
                let body = idle ? Agent.idle : Agent.present
                tab.web.callAsyncJavaScript(body, arguments: ["selector": selector ?? "", "text": text ?? ""], in: nil, in: idle ? .page : Web.world) { result in
                    MainActor.assumeIsolated {
                        switch result {
                        case .success(let value) where value as? Bool == true:
                            // Idle is idle for half a second, not between two requests.
                            guard idle else { answer(["ok": true]); return }
                            if let since = quiet, Date().timeIntervalSince(since) >= 0.5 { answer(["ok": true, "idle": true]); return }
                            if quiet == nil { quiet = Date() }
                        // A selector that can't be read never will be.
                        case .failure(let error) where Agent.said(error).contains("SyntaxError"): answer(["error": Agent.said(error)]); return
                        default: quiet = nil
                        }
                        guard Date() < limit else { answer(["error": idle ? "the page kept loading or fetching for the whole wait" : "not there after the wait", "timeout": true]); return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
                    }
                }
            }
            poll()

        case "a.read", "a.find", "a.text", "a.fill", "a.scroll", "a.focus", "a.upload":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            ready(tab)
            page(verb, request, on: tab) { result in
                if case .success(var out) = result, verb == "a.read" || verb == "a.text" {
                    out["tab"] = Bench.short(tab)
                    answer(out)
                    return
                }
                reply(result)
            }

        case "a.click", "a.hover":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            ready(tab)
            point(on: tab, request) { [weak self] spot, found in
                guard let self else { return }
                guard let spot else { answer(["error": found["error"] as? String ?? "nowhere to click"]); return }
                if verb == "a.hover" {
                    self.mouse(tab.web, at: spot, kinds: [.mouseMoved], clicks: 1, mods: [])
                    answer(["ok": true, "at": found["at"] ?? []])
                    return
                }
                // A select's list is AppKit's menu, which holds the whole app
                // until someone picks from it: chosen with a.fill instead.
                if let options = found["select"] as? [String] {
                    answer(["error": "that is a select — choose with form_input (ref \(found["selectRef"] ?? "?")) and one of: " + options.joined(separator: " | ")])
                    return
                }
                let button = request["button"] as? String ?? "left"
                let mods = Agent.flags(request["mods"])
                if button == "right" {
                    // A real right-click opens a menu the same way: the page
                    // hears the events instead.
                    self.run(Agent.contextMenu, ["x": found["x"] ?? 0, "y": found["y"] ?? 0], on: tab, in: .page) { _ in
                        answer(["ok": true, "at": found["at"] ?? []])
                    }
                    return
                }
                let count = button == "double" ? 2 : button == "triple" ? 3 : 1
                self.mouse(tab.web, at: spot, kinds: [.mouseMoved], clicks: 1, mods: mods)
                for n in 1...count {
                    self.mouse(tab.web, at: spot, kinds: [.leftMouseDown, .leftMouseUp], clicks: n, mods: mods)
                }
                var out: [String: Any] = ["ok": true, "at": found["at"] ?? []]
                if let note = found["note"] as? String { out["note"] = note }
                self.settled(tab, out, answer)
            }

        case "a.drag":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            ready(tab)
            var to: [String: Any] = [:]
            if let ref = request["toRef"] { to["ref"] = ref }
            if let x = request["toX"], let y = request["toY"] { to["x"] = x; to["y"] = y }
            guard !to.isEmpty else { answer(["error": "a.drag needs where to: toRef, or toX and toY"]); return }
            point(on: tab, request) { [weak self] start, from in
                guard let self, let start else { answer(["error": from["error"] as? String ?? "nowhere to start"]); return }
                self.point(on: tab, to) { end, onto in
                    guard let end else { answer(["error": onto["error"] as? String ?? "nowhere to drop"]); return }
                    // What the page lets be dragged the HTML way — a link, a
                    // picture, anything draggable — would start AppKit's own
                    // drag, which follows the real pointer and drops wherever
                    // it is, in any app. The page is told the drag instead.
                    if from["draggable"] as? Bool == true {
                        let arguments: [String: Any] = ["x": from["x"] ?? 0, "y": from["y"] ?? 0, "toX": onto["x"] ?? 0, "toY": onto["y"] ?? 0]
                        self.page("a.dnd", arguments, on: tab) { result in
                            if case .success(let out) = result { self.settled(tab, out, answer) } else { reply(result) }
                        }
                        return
                    }
                    let steps = 12
                    self.mouse(tab.web, at: start, kinds: [.mouseMoved, .leftMouseDown], clicks: 1, mods: [])
                    for n in 1...steps {
                        let t = CGFloat(n) / CGFloat(steps)
                        let spot = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                        self.mouse(tab.web, at: spot, kinds: [.leftMouseDragged], clicks: 1, mods: [])
                    }
                    self.mouse(tab.web, at: end, kinds: [.leftMouseUp], clicks: 1, mods: [])
                    self.settled(tab, ["ok": true, "from": from["at"] ?? [], "to": onto["at"] ?? []], answer)
                }
            }

        case "a.type":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            guard let text = request["text"] as? String else { answer(["error": "a.type needs text"]); return }
            ready(tab)
            let keys = request["keys"] as? Bool == true
            let go = { [weak self] (note: Any?) in
                guard let self else { return }
                self.typeText(text, into: tab.web, keys: keys) {
                    var out: [String: Any] = ["ok": true, "typed": text.count]
                    if let note { out["note"] = note }
                    self.settled(tab, out, answer)
                }
            }
            guard request["ref"] != nil || request["selector"] != nil || request["x"] != nil else { go(nil); return }
            // Into a field: clicked first, as a hand would, so the page sees focus.
            point(on: tab, request) { [weak self] spot, found in
                guard let self, let spot else { answer(["error": found["error"] as? String ?? "no field"]); return }
                if found["select"] != nil { answer(["error": "that is a select — choose with form_input"]); return }
                self.mouse(tab.web, at: spot, kinds: [.leftMouseDown, .leftMouseUp], clicks: 1, mods: [])
                go(found["note"] as? String)
            }

        case "a.key":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            guard let keys = request["keys"] as? String, !keys.isEmpty else { answer(["error": "a.key needs keys, like “Enter” or “cmd+a Backspace”"]); return }
            ready(tab)
            let chords = keys.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            let unknown = chords.filter { Agent.chord($0) == nil }
            guard unknown.isEmpty else { answer(["error": "unknown keys: " + unknown.joined(separator: ", ")]); return }
            let times = max(1, min(100, request["repeat"] as? Int ?? 1))
            page("a.active", [:], on: tab) { [weak self] focused in
                guard let self else { return }
                // Space, Enter or an arrow on a select opens its menu, which
                // holds the app like a click on it does.
                if case .success(let out) = focused, out["select"] as? Bool == true,
                   chords.contains(where: { ["space", "enter", "return", "arrowup", "arrowdown", "up", "down"].contains($0.lowercased()) }) {
                    answer(["error": "a select has the focus — choose with form_input (ref \(out["ref"] ?? "?"))"])
                    return
                }
                self.pressAll(Array(repeating: chords, count: times).flatMap { $0 }, on: tab.web) { self.settled(tab, ["ok": true], answer) }
            }

        case "a.shot":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            ready(tab)
            let quality = request["quality"] as? Double ?? 0.6
            guard request["ref"] != nil || request["selector"] != nil else {
                picture(tab.web, of: nil, quality: quality, answer)
                return
            }
            page("a.rect", request, on: tab) { [weak self] result in
                switch result {
                case .success(let out):
                    guard let x = out["x"] as? Double, let y = out["y"] as? Double, let w = out["width"] as? Double, let h = out["height"] as? Double
                    else { answer(["error": "no picture of that"]); return }
                    self?.picture(tab.web, of: CGRect(x: x, y: y, width: w, height: h), quality: quality, answer)
                case .failure(let error): answer(["error": error.said])
                }
            }

        case "a.js":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            guard let code = request["code"] as? String else { answer(["error": "a.js needs code"]); return }
            ready(tab)
            // In the page's world only: Search's own has its handlers in it.
            // An expression's value, or a body that returns one — awaited
            // either way. The expression is tried first, and what it throws
            // is caught and told: only code that isn't an expression at all,
            // and so never ran, is run again as a body. Run twice, a click or
            // a request in code that then threw would have happened twice.
            let expression = "try { return await (\n" + code + "\n); } catch (e) { return { \(Agent.threw): String(e && e.stack ? e.name + ': ' + e.message : e) }; }"
            tab.web.callAsyncJavaScript(expression, arguments: [:], in: nil, in: .page) { [weak self] result in
                MainActor.assumeIsolated {
                    if case .success(let value) = result {
                        if let thrown = (value as? [String: Any])?[Agent.threw] { answer(["error": thrown]); return }
                        answer(self?.decorated(["value": Bench.plain(value)], tab) ?? [:])
                        return
                    }
                    tab.web.callAsyncJavaScript(code, arguments: [:], in: nil, in: .page) { again in
                        MainActor.assumeIsolated {
                            switch again {
                            case .success(let value): answer(self?.decorated(["value": Bench.plain(value)], tab) ?? [:])
                            case .failure(let error): answer(["error": Agent.said(error)])
                            }
                        }
                    }
                }
            }

        case "a.console":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            ready(tab)
            run(Agent.console, ["clear": request["clear"] as? Bool ?? false], on: tab, in: .page, reply)

        case "a.network":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            ready(tab)
            run(Agent.network, ["clear": request["clear"] as? Bool ?? false], on: tab, in: .page, reply)

        case "a.dialog":
            // How the next confirm, prompt or login in this tab of Claude's is
            // answered. Until told, a confirm is OK, a prompt takes what it
            // offers, a login is cancelled.
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            guard tab.bench else { answer(["error": "a dialog in your tab is yours to answer, on your screen"]); return }
            Agent.next[tab.id] = Agent.Answer(accept: request["accept"] as? Bool ?? true, text: request["text"] as? String)
            answer(["ok": true])

        case "a.dialogs":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            answer(["dialogs": Agent.asked.removeValue(forKey: tab.id) ?? []])

        case "a.batch":
            guard let steps = request["steps"] as? [[String: Any]], !steps.isEmpty else { answer(["error": "a.batch needs steps"]); return }
            var results: [[String: Any]] = []
            func next(_ index: Int) {
                guard index < steps.count else { answer(["results": results]); return }
                var step = steps[index]
                if step["id"] == nil, let id = request["id"] { step["id"] = id }
                let name = step["do"] as? String ?? ""
                guard name.hasPrefix("a."), name != "a.batch" else {
                    results.append(["error": "not a step: \(name)"])
                    answer(["results": results, "stopped": index])
                    return
                }
                agent(name, step, browser: browser) { out in
                    results.append(out)
                    if out["error"] != nil, request["keepGoing"] as? Bool != true {
                        answer(["results": results, "stopped": index])
                        return
                    }
                    next(index + 1)
                }
            }
            next(0)

        default:
            answer(["error": "unknown command “\(verb)”", "commands": [
                "a.tabs", "a.open", "a.show", "a.close", "a.resize", "a.navigate", "a.wait", "a.read", "a.find", "a.text", "a.click",
                "a.hover", "a.drag", "a.type", "a.key", "a.fill", "a.upload", "a.scroll", "a.focus", "a.shot", "a.js", "a.console",
                "a.network", "a.dialog", "a.dialogs", "a.batch",
            ]])
        }
    }

    /// What happened in the tab meanwhile, told with the answer: a dialog a
    /// page put up, a tab it opened.
    private func decorated(_ out: [String: Any], _ tab: Tab) -> [String: Any] {
        var out = out
        if let asked = Agent.asked.removeValue(forKey: tab.id), !asked.isEmpty { out["dialogs"] = asked }
        let opened = Agent.popups.filter { $0.from == tab.id }
        if !opened.isEmpty {
            Agent.popups.removeAll { $0.from == tab.id }
            out["opened"] = opened.map { String($0.to.uuidString.prefix(8)).lowercased() }
        }
        return out
    }

    /// After a click or a key: a beat for what it set off, and if that was a
    /// page loading, until it has — so the next read is of the new page.
    private func settled(_ tab: Tab, _ out: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        let before = tab.address
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            var out = out
            guard tab.loading else {
                if tab.address != before { out["url"] = tab.address?.absoluteString ?? "" }
                answer(decorated(out, tab))
                return
            }
            wait(for: tab, until: Date().addingTimeInterval(15)) { page in
                out["navigated"] = ["url": page["url"] ?? "", "title": page["title"] ?? "", "timeout": page["timeout"] ?? false]
                answer(self.decorated(out, tab))
            }
        }
    }

    /// Once a new page has begun in the tab — it is loading, or it is a
    /// document without the mark a.navigate left — or the time is up, for a
    /// move within the page, which starts nothing.
    private func arrived(_ tab: Tab, within seconds: Double, _ then: @escaping () -> Void) {
        let started = Date()
        func look() {
            guard !tab.loading, Date().timeIntervalSince(started) < seconds else { then(); return }
            tab.web.evaluateJavaScript("!window.__claudeOld", in: nil, in: Web.world) { result in
                MainActor.assumeIsolated {
                    if case .success(let fresh) = result, fresh as? Bool == true { then(); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { look() }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { look() }
    }

    private func forget(_ tab: Tab) {
        Agent.sizes[tab.id] = nil
        Agent.next[tab.id] = nil
        Agent.asked[tab.id] = nil
        rooms.removeValue(forKey: tab.id)?.close()
    }

    // MARK: - pointing

    /// Where to act, in the view's own points: a ref or selector's middle,
    /// scrolled into view first, or x and y on the page as a screenshot
    /// shows it — with what is there, as the page's side found it.
    private func point(on tab: Tab, _ request: [String: Any], _ then: @escaping (NSPoint?, [String: Any]) -> Void) {
        let web = tab.web
        let scale = web.pageZoom * web.magnification
        let at = request["ref"] == nil && request["selector"] == nil
        guard !at || (request["x"] != nil && request["y"] != nil) else {
            then(nil, ["error": "needs a ref, or x and y"])
            return
        }
        page(at ? "a.at" : "a.point", request, on: tab) { result in
            switch result {
            case .success(var out):
                guard let x = out["x"] as? Double, let y = out["y"] as? Double else { then(nil, ["error": "no place"]); return }
                out["at"] = [Int(x.rounded()), Int(y.rounded())]
                let local = NSPoint(x: x * scale, y: y * scale)
                then(web.isFlipped ? local : NSPoint(x: local.x, y: web.bounds.height - local.y), out)
            case .failure(let error): then(nil, ["error": error.said])
            }
        }
    }

    private func mouse(_ web: WKWebView, at spot: NSPoint, kinds: [NSEvent.EventType], clicks: Int, mods: NSEvent.ModifierFlags) {
        guard let window = web.window else { return }
        let location = web.convert(spot, to: nil)
        for type in kinds {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: mods,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp || type == .mouseMoved ? 0 : 1
            ) else { continue }
            switch type {
            case .leftMouseDown:
                window.makeFirstResponder(web)
                web.mouseDown(with: event)
            case .leftMouseUp: web.mouseUp(with: event)
            case .leftMouseDragged: web.mouseDragged(with: event)
            default: web.mouseMoved(with: event)
            }
        }
    }

    // MARK: - keys

    /// Text into the focused field, as Chrome's Input.insertText puts it:
    /// one edit, beforeinput and input fired, any character — ş and emoji
    /// included — and in order with whatever comes after it. With `keys`,
    /// a key press per character instead, for a page that listens to keys.
    private func typeText(_ text: String, into web: WKWebView, keys: Bool, _ done: @escaping () -> Void) {
        web.window?.makeFirstResponder(web)
        guard keys else {
            // Lines as Enter, so a form or a chat sees them as a hand's.
            let lines = text.components(separatedBy: "\n")
            var steps: [Step] = []
            for (n, line) in lines.enumerated() {
                if n > 0 { steps.append { next in self.send(Agent.chord("Enter")!, to: web, next) } }
                if !line.isEmpty { steps.append { next in web.insertText(line); next() } }
            }
            settle(steps, on: web, done)
            return
        }
        let chords: [Agent.Chord] = text.map { character in
            if character == "\n" { return Agent.chord("Enter")! }
            if character == "\t" { return Agent.chord("Tab")! }
            let chars = String(character)
            return Agent.Chord(name: chars, code: Agent.code(for: character), chars: chars, ignoring: chars.lowercased(), mods: character.isUppercase ? [.shift] : [])
        }
        settle(chords.map { chord in { next in self.send(chord, to: web, next) } }, on: web, done)
    }

    /// Chords — "Enter", "cmd+a", "shift+Tab" — pressed one after another.
    private func pressAll(_ chords: [String], on web: WKWebView, _ done: @escaping () -> Void) {
        web.window?.makeFirstResponder(web)
        settle(chords.compactMap(Agent.chord).map { chord in { next in self.send(chord, to: web, next) } }, on: web, done)
    }

    typealias Step = (@escaping () -> Void) -> Void

    /// Steps that each hand the page something, run one at a time: the next
    /// only once the page has done with the last. WebKit queues key events
    /// and sends each after the one before is handled, while an edit command
    /// or a script goes at once — ⌘A after typing selected the half typed so
    /// far. A script's round trip behind each step keeps them in order.
    private func settle(_ steps: [Step], on web: WKWebView, _ done: @escaping () -> Void) {
        guard let first = steps.first else { done(); return }
        first {
            web.evaluateJavaScript("0") { [weak self] _, _ in
                MainActor.assumeIsolated { self?.settle(Array(steps.dropFirst()), on: web, done) }
            }
        }
    }

    /// One chord, pressed on the page.
    ///
    /// Never a key with ⌘ as a real key event: WebKit takes those as the
    /// app's key equivalents, and whatever the page doesn't use runs the
    /// app's menu — ⌘W sent to a tab of Claude's closed the tab you were
    /// looking at. The page is told the key as its own event instead, and
    /// the edit menu's ones — ⌘A, ⌘C, ⌘V, ⌘X, ⌘Z — are done as the
    /// commands, on this view only, unless the page took the key itself.
    private func send(_ chord: Agent.Chord, to web: WKWebView, _ done: @escaping () -> Void) {
        if chord.mods.contains(.command) {
            let dom = Agent.dom(chord)
            web.callAsyncJavaScript(Agent.synthetic, arguments: dom, in: nil, in: .page) { result in
                MainActor.assumeIsolated {
                    let taken = (try? result.get()) as? Bool == false
                    if !taken, let command = Agent.editing(chord.ignoring, shift: chord.mods.contains(.shift)) {
                        web.tryToPerform(command, with: nil)
                    }
                    done()
                }
            }
            return
        }
        let number = web.window?.windowNumber ?? 0
        Agent.guardKeys()
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: chord.mods,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: number, context: nil,
                characters: chord.chars, charactersIgnoringModifiers: chord.ignoring,
                isARepeat: false, keyCode: chord.code
            ) else { continue }
            Agent.sent.append(event)
            if Agent.sent.count > 64 { Agent.sent.removeFirst(Agent.sent.count - 64) }
            if type == .keyDown { web.keyDown(with: event) } else { web.keyUp(with: event) }
        }
        done()
    }

    // MARK: - looking

    /// The page as it is on screen, one pixel per CSS pixel: a point on the
    /// picture is a point for `a.click`. `rect`, in the page's CSS pixels,
    /// for one element's part of it.
    private func picture(_ web: WKWebView, of rect: CGRect?, quality: Double, _ answer: @escaping ([String: Any]) -> Void) {
        let scale = web.pageZoom * web.magnification
        let whole = CGRect(x: 0, y: 0, width: web.bounds.width / scale, height: web.bounds.height / scale)
        let area = (rect ?? whole).intersection(whole)
        guard !area.isNull, area.width >= 1, area.height >= 1 else { answer(["error": "that is not on screen — scroll to it first"]); return }
        let size = NSSize(width: area.width.rounded(), height: area.height.rounded())
        let shot = WKSnapshotConfiguration()
        shot.afterScreenUpdates = true
        if rect != nil {
            let y = web.isFlipped ? area.minY * scale : web.bounds.height - area.maxY * scale
            shot.rect = CGRect(x: area.minX * scale, y: y, width: area.width * scale, height: area.height * scale)
        }
        shot.snapshotWidth = NSNumber(value: Double(size.width))
        web.takeSnapshot(with: shot) { image, error in
            MainActor.assumeIsolated {
                guard let image, size.width > 0, size.height > 0,
                      let rep = NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                else {
                    answer(["error": error?.localizedDescription ?? "no picture"])
                    return
                }
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor.white.setFill()
                NSRect(origin: .zero, size: size).fill()
                image.draw(in: NSRect(origin: .zero, size: size))
                NSGraphicsContext.restoreGraphicsState()
                guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: max(0.1, min(1, quality))]) else {
                    answer(["error": "no picture"])
                    return
                }
                answer(["jpeg": jpeg.base64EncodedString(), "width": Int(size.width), "height": Int(size.height),
                        "left": Int(area.minX), "top": Int(area.minY)])
            }
        }
    }
}

// MARK: - what a page in Claude's tab asks

extension Browser {
    /// A page in one of Claude's tabs asked something — an alert, a confirm,
    /// a prompt, a login, a file. Answered here, and told to Claude with its
    /// next answer: a sheet on a window nobody sees would hold the page for
    /// good. Nil for your own tabs, which ask you as they always did.
    func claudeAnswers(_ webView: WKWebView, _ kind: String, _ message: String) -> Agent.Answer? {
        guard let tab = tab(for: webView), tab.bench else { return nil }
        let answer = Agent.next.removeValue(forKey: tab.id) ?? Agent.Answer(accept: kind != "login" && kind != "certificate", text: nil)
        var entry: [String: Any] = ["kind": kind, "message": message, "accepted": answer.accept]
        if let text = answer.text, kind == "prompt" { entry["answered"] = text }
        Agent.asked[tab.id, default: []].append(entry)
        return answer
    }
}

/// The page-side half, and the names of keys.
@MainActor
enum Agent {
    struct Answer {
        let accept: Bool
        let text: String?
    }

    struct Failure: Error {
        let said: String
    }

    /// How the next dialog in a tab of Claude's is answered, when told.
    static var next: [Tab.ID: Answer] = [:]
    /// What pages in Claude's tabs asked, until Claude has been told.
    static var asked: [Tab.ID: [[String: Any]]] = [:]
    /// Tabs Claude's tabs opened, until Claude has been told.
    static var popups: [(from: Tab.ID, to: Tab.ID)] = []
    /// The size a tab of Claude's was given, when not the usual.
    static var sizes: [Tab.ID: NSSize] = [:]

    /// The keys Claude pressed, lately. A key a page doesn't use, WebKit
    /// sends on through the app — NSApp.sendEvent — which hands it to the
    /// window in front, whatever window the page is in: a key Claude pressed
    /// in a tab of its own was typed into your address field, and ⌘W would
    /// have closed your tab. So none of them goes past the page: seen coming
    /// back through the app, it stops there.
    static var sent: [NSEvent] = []
    /// How many were stopped on their way back, for the bench.
    static var stopped = 0
    private static var watching: Any?

    static func guardKeys() {
        guard watching == nil else { return }
        watching = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            // A local monitor runs on the main thread, as the app's events do.
            nonisolated(unsafe) let seen = event
            let ours = MainActor.assumeIsolated { () -> Bool in
                guard let at = sent.firstIndex(where: { PageView.same($0, seen) }) else { return false }
                sent.remove(at: at)
                stopped += 1
                return true
            }
            return ours ? nil : event
        }
    }

    static let phone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static func size(_ request: [String: Any]) -> NSSize? {
        guard let w = request["width"] as? Double, let h = request["height"] as? Double,
              (200...4000).contains(w), (200...4000).contains(h) else { return nil }
        return NSSize(width: w.rounded(), height: h.rounded())
    }

    /// The key an expression's error comes back under.
    static let threw = "__searchThrew"

    static func said(_ error: Error) -> String {
        let info = (error as NSError).userInfo
        return (info["WKJavaScriptExceptionMessage"] as? String) ?? error.localizedDescription
    }

    static func flags(_ value: Any?) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in value as? [String] ?? (value as? String).map({ $0.split(separator: "+").map(String.init) }) ?? [] {
            switch name.lowercased() {
            case "cmd", "command", "meta": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "ctrl", "control": flags.insert(.control)
            case "alt", "opt", "option": flags.insert(.option)
            default: break
            }
        }
        return flags
    }

    /// The edit menu's command a ⌘ key stands for.
    static func editing(_ key: String, shift: Bool) -> Selector? {
        switch key.lowercased() {
        case "a": return #selector(NSResponder.selectAll(_:))
        case "c": return #selector(NSText.copy(_:))
        case "v": return #selector(NSText.paste(_:))
        case "x": return #selector(NSText.cut(_:))
        case "z": return shift ? Selector(("redo:")) : Selector(("undo:"))
        default: return nil
        }
    }

    struct Chord {
        let name: String
        let code: UInt16
        let chars: String
        let ignoring: String
        let mods: NSEvent.ModifierFlags
    }

    /// "cmd+shift+z", "Enter", "a" as a key and the keys held with it.
    static func chord(_ text: String) -> Chord? {
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "+" and "cmd++": the plus is the key.
        if parts.count >= 2, parts[parts.count - 1].isEmpty, parts[parts.count - 2].isEmpty {
            parts.removeLast(2)
            parts.append("+")
        }
        guard let name = parts.last, !name.isEmpty else { return nil }
        var mods: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part.lowercased() {
            case "cmd", "command", "meta", "super": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "ctrl", "control": mods.insert(.control)
            case "alt", "opt", "option": mods.insert(.option)
            default: return nil
            }
        }
        guard let (code, chars) = key(name) else { return nil }
        // A character typed with shift on a US keyboard says so, as a hand's does.
        if chars.count == 1, let c = chars.first, c.isUppercase || "!@#$%^&*()_+{}|:\"<>?~".contains(c) { mods.insert(.shift) }
        return Chord(name: name, code: code, chars: chars, ignoring: mods.contains(.shift) ? chars.uppercased() : chars.lowercased(), mods: mods)
    }

    /// A key's code on a US keyboard and the characters it sends.
    static func key(_ name: String) -> (UInt16, String)? {
        func fn(_ value: Int) -> String { String(UnicodeScalar(UInt32(value)).map(Character.init) ?? " ") }
        switch name.lowercased() {
        case "enter", "return": return (36, "\r")
        case "tab": return (48, "\t")
        case "space": return (49, " ")
        case "backspace": return (51, "\u{7F}")
        case "escape", "esc": return (53, "\u{1B}")
        case "delete": return (117, fn(NSDeleteFunctionKey))
        case "arrowleft", "left": return (123, fn(NSLeftArrowFunctionKey))
        case "arrowright", "right": return (124, fn(NSRightArrowFunctionKey))
        case "arrowdown", "down": return (125, fn(NSDownArrowFunctionKey))
        case "arrowup", "up": return (126, fn(NSUpArrowFunctionKey))
        case "home": return (115, fn(NSHomeFunctionKey))
        case "end": return (119, fn(NSEndFunctionKey))
        case "pageup": return (116, fn(NSPageUpFunctionKey))
        case "pagedown": return (121, fn(NSPageDownFunctionKey))
        case "f1": return (122, fn(NSF1FunctionKey))
        case "f2": return (120, fn(NSF2FunctionKey))
        case "f3": return (99, fn(NSF3FunctionKey))
        case "f4": return (118, fn(NSF4FunctionKey))
        case "f5": return (96, fn(NSF5FunctionKey))
        case "f6": return (97, fn(NSF6FunctionKey))
        case "f7": return (98, fn(NSF7FunctionKey))
        case "f8": return (100, fn(NSF8FunctionKey))
        case "f9": return (101, fn(NSF9FunctionKey))
        case "f10": return (109, fn(NSF10FunctionKey))
        case "f11": return (103, fn(NSF11FunctionKey))
        case "f12": return (111, fn(NSF12FunctionKey))
        case "+": return (24, "+")
        default:
            guard name.count == 1, let character = name.first else { return nil }
            return (code(for: character), name)
        }
    }

    /// The key that types a character on a US keyboard, shifted or not —
    /// letters, digits and punctuation; any other character goes as a key
    /// no keyboard has, so a page never takes ş for the space bar.
    static func code(for character: Character) -> UInt16 {
        let row = "asdfhgzxcv\u{0}bqweryt123465=97-80]ou[ip\u{0}lj'k;\\,/nm."
        let lower = Character(character.lowercased())
        let shifted: [Character: Character] = ["!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
                                               "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`"]
        let key = shifted[lower] ?? lower
        if key == "`" { return 50 }
        if key == " " { return 49 }
        if let at = row.firstIndex(of: key), key != "\u{0}" { return UInt16(row.distance(from: row.startIndex, to: at)) }
        return 0xFF
    }

    /// A chord as the page's KeyboardEvent names it.
    static func dom(_ chord: Chord) -> [String: Any] {
        let named: [String: String] = ["enter": "Enter", "return": "Enter", "tab": "Tab", "space": " ", "backspace": "Backspace",
                                       "escape": "Escape", "esc": "Escape", "delete": "Delete", "arrowleft": "ArrowLeft", "left": "ArrowLeft",
                                       "arrowright": "ArrowRight", "right": "ArrowRight", "arrowdown": "ArrowDown", "down": "ArrowDown",
                                       "arrowup": "ArrowUp", "up": "ArrowUp", "home": "Home", "end": "End", "pageup": "PageUp", "pagedown": "PageDown"]
        let lower = chord.name.lowercased()
        var key = named[lower] ?? (lower.hasPrefix("f") && lower.count > 1 && Int(lower.dropFirst()) != nil ? lower.uppercased() : chord.name)
        var code = key == " " ? "Space" : key
        if chord.name.count == 1, let c = chord.name.first {
            key = chord.mods.contains(.shift) ? chord.name.uppercased() : chord.name.lowercased()
            if c.isLetter, c.isASCII { code = "Key" + chord.name.uppercased() }
            else if c.isNumber, c.isASCII { code = "Digit" + chord.name }
            else { code = "" }
        }
        return ["key": key, "code": code, "meta": chord.mods.contains(.command), "ctrl": chord.mods.contains(.control),
                "alt": chord.mods.contains(.option), "shift": chord.mods.contains(.shift)]
    }

    /// A key told to the page as its own events, on what has the focus —
    /// through frames from the same site. False when the page took it.
    static let synthetic = #"""
    var t = document.activeElement;
    while (t && (t.tagName === 'IFRAME' || t.tagName === 'FRAME')) { try { t = t.contentDocument.activeElement; } catch (e) { break; } }
    t = t || document.body || document.documentElement;
    var o = { key: key, code: code, bubbles: true, cancelable: true, composed: true, metaKey: meta, ctrlKey: ctrl, altKey: alt, shiftKey: shift };
    var kept = t.dispatchEvent(new KeyboardEvent('keydown', o));
    t.dispatchEvent(new KeyboardEvent('keyup', o));
    return kept;
    """#

    /// True once the selector matches, or the text is on the page.
    static let present = #"""
    if (selector) return !!document.querySelector(selector);
    return !!(document.body && document.body.innerText.indexOf(text) >= 0);
    """#

    /// True while the page has loaded and has no request of its own open.
    static let idle = #"""
    var box = window[Symbol.for('search.claude')];
    return document.readyState === 'complete' && (!box || box.inflight <= 0);
    """#

    /// A right-click, told to the page as its events.
    static let contextMenu = #"""
    var el = document.elementFromPoint(x, y);
    if (!el) return false;
    var o = { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 2, buttons: 2, view: window };
    el.dispatchEvent(new PointerEvent('pointerdown', o));
    el.dispatchEvent(new MouseEvent('mousedown', o));
    el.dispatchEvent(new PointerEvent('pointerup', o));
    el.dispatchEvent(new MouseEvent('mouseup', o));
    el.dispatchEvent(new MouseEvent('contextmenu', o));
    return true;
    """#

    /// What listens, in the page's own world, to what a page says and asks
    /// for: the console, uncaught errors and rejections, files that fail to
    /// load, blocked content, and every fetch and XMLHttpRequest with its
    /// status and time. Put in at the start of each page in Claude's tabs,
    /// and of each page from this Mac (`always` false: it checks the host);
    /// in any other page the first time it is asked for. Under a symbol
    /// nothing of the page's names, once per page.
    static let hook = #"""
    function (always, since) {
      var K = Symbol.for('search.claude');
      if (window[K]) return window[K];
      if (!always) {
        var h = location.hostname;
        if (!(h === 'localhost' || h === '0.0.0.0' || h === '[::1]' || /^127\./.test(h) || /\.(localhost|local|test)$/.test(h))) return null;
      }
      var box = { log: [], net: [], inflight: 0, since: since };
      Object.defineProperty(window, K, { value: box });
      function keep(list, item, max) { list.push(item); if (list.length > max) list.shift(); }
      function show(x) {
        if (typeof x === 'string') return x;
        if (x instanceof Error) return x.stack && x.stack.indexOf(x.message) >= 0 ? x.name + ': ' + x.message + '\n' + x.stack : x.name + ': ' + x.message + (x.stack ? '\n' + x.stack : '');
        try { var s = JSON.stringify(x); return s === undefined ? String(x) : s; } catch (e) { return String(x); }
      }
      function say(level, parts) {
        keep(box.log, { level: level, time: Date.now(), text: Array.prototype.map.call(parts, show).join(' ').slice(0, 4000) }, 1000);
      }
      ['log', 'info', 'warn', 'error', 'debug', 'trace'].forEach(function (level) {
        var original = console[level];
        if (typeof original !== 'function') return;
        console[level] = function () { try { say(level, arguments); } catch (e) {} return original.apply(this, arguments); };
      });
      addEventListener('error', function (e) {
        var t = e.target;
        if (t && t !== window && t.tagName) {
          var src = t.currentSrc || t.src || t.href || '';
          keep(box.net, { method: 'GET', url: String(src), type: t.tagName.toLowerCase(), failed: 'did not load', time: Date.now() }, 500);
          say('error', ['Failed to load ' + t.tagName.toLowerCase() + ': ' + src]);
          return;
        }
        say('exception', [e.error ? show(e.error) : (e.message || 'error') + ' @ ' + (e.filename || '') + ':' + (e.lineno || 0) + ':' + (e.colno || 0)]);
      }, true);
      addEventListener('unhandledrejection', function (e) { say('exception', ['Unhandled rejection: ' + show(e.reason)]); });
      addEventListener('securitypolicyviolation', function (e) { say('error', ['Content Security Policy blocked ' + (e.blockedURI || 'inline') + ' (' + e.violatedDirective + ')']); });
      function where(url) { try { return new URL(url, location.href).href; } catch (e) { return String(url); } }
      var fetch0 = window.fetch;
      if (typeof fetch0 === 'function') {
        window.fetch = function (input, init) {
          var entry = { method: String((init && init.method) || (input && input.method) || 'GET').toUpperCase(),
                        url: where(typeof input === 'string' || input instanceof URL ? input : input && input.url), type: 'fetch', time: Date.now() };
          var t0 = performance.now();
          var p;
          try { p = fetch0.apply(this, arguments); } catch (e) { entry.failed = String(e); keep(box.net, entry, 500); throw e; }
          box.inflight++;
          return p.then(function (r) {
            entry.status = r.status; entry.ms = Math.round(performance.now() - t0); box.inflight--; keep(box.net, entry, 500); return r;
          }, function (err) {
            entry.failed = String(err && err.message || err); entry.ms = Math.round(performance.now() - t0); box.inflight--; keep(box.net, entry, 500); throw err;
          });
        };
      }
      var X = window.XMLHttpRequest && XMLHttpRequest.prototype;
      if (X) {
        var open0 = X.open, send0 = X.send, calls = new WeakMap();
        X.open = function (method, url) { calls.set(this, { method: String(method).toUpperCase(), url: where(url), type: 'xhr' }); return open0.apply(this, arguments); };
        X.send = function () {
          var entry = calls.get(this), xhr = this;
          if (entry) {
            entry.time = Date.now();
            var t0 = performance.now();
            box.inflight++;
            xhr.addEventListener('loadend', function () {
              entry.status = xhr.status;
              if (!xhr.status) entry.failed = 'network error, blocked or aborted';
              entry.ms = Math.round(performance.now() - t0);
              box.inflight--;
              keep(box.net, entry, 500);
            });
          }
          return send0.apply(this, arguments);
        };
      }
      return box;
    }
    """#

    /// The hook put in at the start of a page.
    static func hookAtStart(always: Bool) -> String { "(" + hook + ")(\(always), 'start');" }

    /// The console, as `hook` heard it.
    static let console = "var box = (" + hook + ")(true, 'now');\n" + #"""
    var out = box.log.slice();
    if (clear) box.log.length = 0;
    return { since: box.since, messages: out };
    """#

    /// What the page asked for, as `hook` heard it, and what it loaded, as
    /// its own timing records it.
    static let network = "var box = (" + hook + ")(true, 'now');\n" + #"""
    var seen = {};
    var out = box.net.map(function (e) { seen[e.url] = true; return e; });
    performance.getEntriesByType('navigation').concat(performance.getEntriesByType('resource')).forEach(function (e) {
      if (seen[e.name] && (e.initiatorType === 'fetch' || e.initiatorType === 'xmlhttprequest')) return;
      var r = { method: 'GET', url: e.name, type: e.initiatorType || e.entryType, ms: Math.round(e.duration), time: Math.round(performance.timeOrigin + e.startTime) };
      if (e.responseStatus) r.status = e.responseStatus;
      if (e.transferSize) r.bytes = e.transferSize;
      out.push(r);
    });
    out.sort(function (a, b) { return (a.time || 0) - (b.time || 0); });
    if (clear) { box.net.length = 0; performance.clearResourceTimings(); }
    return { since: box.since, requests: out.slice(-400) };
    """#

    /// Reading, finding, filling, scrolling and pointing, in Search's world.
    /// Refs are kept here, per element, for as long as the element lives.
    /// Frames from the same site are read as part of the page; a frame from
    /// another site is listed with where it is, for a screenshot and a click.
    static let page = #"""
    var S = window.__claude || (window.__claude = { byId: new Map(), ids: new WeakMap(), next: 1 });
    if (S.byId.size > 5000) S.byId.forEach(function (w, id) { if (!w.deref()) S.byId.delete(id); });
    function refOf(el) {
      var id = S.ids.get(el);
      if (!id) { id = 'r' + (S.next++); S.ids.set(el, id); S.byId.set(id, new WeakRef(el)); }
      return id;
    }
    function byRef(ref) {
      var w = S.byId.get(String(ref).replace(/^\[|\]$/g, ''));
      var el = w && w.deref();
      if (!el || !el.isConnected) throw new Error('ref ' + ref + ' is gone — read the page again');
      return el;
    }
    function target() {
      if (args.ref) return byRef(args.ref);
      if (args.selector) {
        var el = document.querySelector(args.selector);
        if (!el) throw new Error('nothing matches ' + args.selector);
        return el;
      }
      throw new Error('needs a ref or a selector');
    }
    function clean(s, n) { s = (s || '').replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; }
    function win(el) { return (el.ownerDocument && el.ownerDocument.defaultView) || window; }
    function frameDoc(f) { try { var d = f.contentDocument; return d && d.documentElement ? d : null; } catch (e) { return null; } }
    // Where an element of a frame from the same site is on the top page.
    function box(el) {
      var r = el.getBoundingClientRect(), x = 0, y = 0, w = win(el);
      try {
        while (w && w !== window && w.frameElement) {
          var f = w.frameElement, fr = f.getBoundingClientRect();
          x += fr.left + f.clientLeft; y += fr.top + f.clientTop;
          w = win(f);
        }
      } catch (e) {}
      return { left: r.left + x, top: r.top + y, right: r.right + x, bottom: r.bottom + y, width: r.width, height: r.height };
    }
    function visible(el, r) {
      if (!r.width && !r.height) return false;
      var st = win(el).getComputedStyle(el);
      return st.visibility !== 'hidden' && st.display !== 'none' && st.opacity !== '0';
    }
    // What is under a point of the top page, through frames from the same site.
    function hitAt(x, y) {
      var h = document.elementFromPoint(x, y), ox = 0, oy = 0;
      while (h && (h.tagName === 'IFRAME' || h.tagName === 'FRAME')) {
        var d = frameDoc(h);
        if (!d) break;
        var r = h.getBoundingClientRect();
        ox += r.left + h.clientLeft; oy += r.top + h.clientTop;
        var inner = d.elementFromPoint(x - ox, y - oy);
        if (!inner) break;
        h = inner;
      }
      return h;
    }
    function deepActive() {
      var a = document.activeElement;
      while (a && (a.tagName === 'IFRAME' || a.tagName === 'FRAME')) { var d = frameDoc(a); if (!d) break; a = d.activeElement; }
      return a;
    }
    function selectOf(el) { return el ? (el.tagName === 'SELECT' ? el : (el.closest && el.closest('select'))) : null; }
    function draggableOf(el) {
      for (var n = el; n && n.nodeType === 1; n = n.parentElement) {
        var d = n.getAttribute('draggable');
        if (d === 'true') return n;
        if (d === 'false') return null;
        if ((n.tagName === 'A' && n.hasAttribute('href')) || n.tagName === 'IMG') return n;
      }
      return null;
    }
    var INPUT_ROLE = { checkbox: 'checkbox', radio: 'radio', range: 'slider', button: 'button', submit: 'button', reset: 'button', image: 'button', file: 'file', color: 'button' };
    function role(el) {
      var r = el.getAttribute('role');
      if (r) return r.split(' ')[0];
      var t = el.tagName;
      if (t === 'A') return el.hasAttribute('href') ? 'link' : null;
      if (t === 'BUTTON' || t === 'SUMMARY') return 'button';
      if (t === 'INPUT') { var ty = (el.type || 'text').toLowerCase(); return ty === 'hidden' ? null : (INPUT_ROLE[ty] || (ty === 'search' ? 'searchbox' : 'textbox')); }
      if (t === 'SELECT') return 'combobox';
      if (t === 'TEXTAREA') return 'textbox';
      if (/^H[1-6]$/.test(t)) return 'heading';
      if (t === 'IMG') return el.alt ? 'img' : null;
      if (t === 'DIALOG') return 'dialog';
      if (el.isContentEditable && (!el.parentElement || !el.parentElement.isContentEditable)) return 'textbox';
      if (el.hasAttribute('onclick') || (el.hasAttribute('tabindex') && el.getAttribute('tabindex') !== '-1')) return 'clickable';
      return null;
    }
    var ACTIVE = { link: 1, button: 1, textbox: 1, searchbox: 1, checkbox: 1, radio: 1, slider: 1, combobox: 1, clickable: 1, tab: 1, menuitem: 1, option: 1, switch: 1, menuitemcheckbox: 1, menuitemradio: 1, spinbutton: 1, treeitem: 1, listbox: 1, file: 1 };
    function name(el) {
      var l = el.getAttribute('aria-label');
      if (l) return clean(l, 100);
      var by = el.getAttribute('aria-labelledby');
      if (by) { var t = by.split(' ').map(function (i) { var n = el.ownerDocument.getElementById(i); return n ? n.innerText : ''; }).join(' '); if (t.trim()) return clean(t, 100); }
      if (el.labels && el.labels.length) return clean(Array.prototype.map.call(el.labels, function (x) { return x.innerText; }).join(' '), 100);
      if (el.tagName === 'IMG') return clean(el.alt, 100);
      if (el.tagName === 'INPUT' && /^(submit|button|reset)$/i.test(el.type)) return clean(el.value, 100);
      var text = clean(el.innerText || el.textContent, 100);
      if (text) return text;
      var img = el.querySelector && el.querySelector('img[alt]');
      return clean(el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('name') || (img ? img.alt : ''), 100);
    }
    function place(r) {
      var inView = r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
      return inView ? ' @' + Math.round(r.left + r.width / 2) + ',' + Math.round(r.top + r.height / 2) : ' (offscreen)';
    }
    function line(el, r, rl) {
      var s = '[' + refOf(el) + '] ' + rl;
      if (rl === 'heading') s += ' h' + el.tagName.slice(1);
      var n = name(el);
      if (n) s += ' "' + n.replace(/"/g, '\\"') + '"';
      if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') {
        var ty = el.type;
        if (ty === 'password') s += el.value ? ' value=•••' : '';
        else if (ty === 'checkbox' || ty === 'radio') s += el.checked ? ' checked' : '';
        else if (ty === 'file') s += el.files && el.files.length ? ' files=' + Array.prototype.map.call(el.files, function (f) { return f.name; }).join(',') : '';
        else if (el.tagName === 'SELECT') s += ' value="' + clean(el.options[el.selectedIndex] ? el.options[el.selectedIndex].text : '', 60) + '"';
        else if (el.value && clean(el.value, 100) !== n) s += ' value="' + clean(el.value, 80) + '"';
        if (el.placeholder && n !== clean(el.placeholder, 100)) s += ' placeholder="' + clean(el.placeholder, 60) + '"';
        if (ty && el.tagName === 'INPUT' && ['text', 'checkbox', 'radio', 'file'].indexOf(ty) < 0) s += ' type=' + ty;
        if (el.required) s += ' required';
        if (el.validity && !el.validity.valid && (el.value || el.checked)) s += ' invalid';
      }
      if (el.getAttribute('aria-expanded')) s += ' expanded=' + el.getAttribute('aria-expanded');
      if (el.getAttribute('aria-selected') === 'true' || el.getAttribute('aria-current')) s += ' current';
      if (el.getAttribute('aria-invalid') === 'true') s += ' invalid';
      if (el.disabled || el.getAttribute('aria-disabled') === 'true') s += ' disabled';
      if (el.ownerDocument.activeElement === el) s += ' focused';
      if (rl === 'link') { var h = el.getAttribute('href') || ''; if (h && h.indexOf('javascript:') !== 0) s += ' → ' + clean(h, 80); }
      if (win(el) !== window) s += ' (in a frame)';
      return s + place(r);
    }
    // Every element under root, into shadow roots and frames from the same
    // site; each() returning false skips what is under that element.
    function walk(root, each) {
      var stack = [root];
      while (stack.length) {
        var node = stack.pop();
        if (node !== root && each(node) === false) continue;
        if (node.tagName === 'IFRAME' || node.tagName === 'FRAME') {
          var d = frameDoc(node);
          if (d) stack.push(d.documentElement);
          continue;
        }
        var kids = node.children;
        if (kids) for (var j = kids.length - 1; j >= 0; j--) stack.push(kids[j]);
        if (node.shadowRoot) for (var i = node.shadowRoot.children.length - 1; i >= 0; i--) stack.push(node.shadowRoot.children[i]);
      }
    }
    function header() {
      return document.title + ' — ' + location.href + '\nviewport ' + innerWidth + '×' + innerHeight + ', scrolled ' + Math.round(scrollY) + ' of ' + Math.max(0, document.documentElement.scrollHeight - innerHeight);
    }
    var SKIP = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, SVG: 1, svg: 1, HEAD: 1 };

    var verb = args.verb;
    if (verb === 'a.read') {
      var all = args.filter === 'all';
      var max = args.max || (all ? 600 : 400);
      var root = args.ref ? byRef(args.ref) : document.documentElement;
      var out = [], count = 0, cut = false;
      walk(root, function (el) {
        var t = el.tagName;
        if (SKIP[t]) return false;
        if (el.getAttribute('aria-hidden') === 'true') return false;
        if (t === 'IFRAME' || t === 'FRAME') {
          var fr = box(el);
          if (!visible(el, fr)) return false;
          if (frameDoc(el)) return;
          if (count >= max) { cut = true; return false; }
          out.push('[' + refOf(el) + '] frame from another site ' + clean(el.src, 80) + ' — not readable here; a screenshot shows it and clicks at its points reach it' + place(fr));
          count++;
          return false;
        }
        var rl = role(el);
        if (!rl) return;
        if (!all && !ACTIVE[rl] && rl !== 'heading' && rl !== 'dialog' && rl !== 'alert') return;
        var r = box(el);
        if (!visible(el, r)) return false;
        if (count >= max) { cut = true; return false; }
        out.push(line(el, r, rl));
        count++;
        if (rl === 'link' || rl === 'button') return false;
      });
      var text = header() + '\n' + out.join('\n');
      if (cut) text += '\n… more than ' + max + ' — read a part with ref, or use find';
      return { page: text, count: count };
    }
    if (verb === 'a.find') {
      var q = String(args.query || '').toLowerCase().split(/\s+/).filter(Boolean);
      if (!q.length) throw new Error('find needs a query');
      var hits = [];
      walk(document.documentElement, function (el) {
        var t = el.tagName;
        if (SKIP[t]) return false;
        var rl = role(el);
        var own = rl ? (name(el) + ' ' + (el.getAttribute('placeholder') || '') + ' ' + (el.getAttribute('title') || '') + ' ' + rl + ' ' + (el.id || '') + ' ' + (el.getAttribute('name') || '')) : '';
        if (!own) {
          var direct = Array.prototype.filter.call(el.childNodes, function (n) { return n.nodeType === 3; }).map(function (n) { return n.textContent; }).join(' ').trim();
          if (!direct) return;
          own = direct;
          rl = 'text';
        }
        var low = own.toLowerCase();
        var score = q.reduce(function (s, w) { return s + (low.indexOf(w) >= 0 ? 1 : 0); }, 0);
        if (!score) return;
        var r = box(el);
        if (!visible(el, r)) return;
        hits.push({ score: score + (ACTIVE[rl] ? 0.5 : 0), line: rl === 'text' ? '[' + refOf(el) + '] text "' + clean(own, 120) + '"' + place(r) : line(el, r, rl) });
      });
      hits.sort(function (a, b) { return b.score - a.score; });
      return { found: hits.slice(0, args.max || 20).map(function (h) { return h.line; }), total: hits.length };
    }
    if (verb === 'a.text') {
      var node = args.ref ? byRef(args.ref) : (document.querySelector('article, main, [role=main]') || document.body);
      var txt = (node && node.innerText) || '';
      var limit = args.max || 60000;
      return { title: document.title, url: location.href, text: txt.length > limit ? txt.slice(0, limit) : txt, truncated: txt.length > limit };
    }
    if (verb === 'a.active') {
      var a = deepActive();
      var sel = selectOf(a);
      return { select: !!sel, ref: sel ? refOf(sel) : (a && a !== document.body ? refOf(a) : null) };
    }
    if (verb === 'a.point' || verb === 'a.focus' || verb === 'a.at' || verb === 'a.rect') {
      var el = null, x, y;
      if (verb === 'a.at') {
        x = Number(args.x); y = Number(args.y);
        if (!(x >= 0 && y >= 0 && x <= innerWidth && y <= innerHeight)) throw new Error('(' + x + ', ' + y + ') is outside the page\'s ' + innerWidth + '×' + innerHeight + ' — scroll first');
      } else {
        el = target();
        el.scrollIntoView({ block: verb === 'a.rect' ? 'nearest' : 'center', inline: 'nearest', behavior: 'instant' });
        if (verb === 'a.focus') { el.focus(); return { ok: true }; }
        var r = box(el);
        if (!r.width && !r.height) throw new Error((args.ref || args.selector) + ' has no size — hidden?');
        if (verb === 'a.rect') return { x: r.left, y: r.top, width: r.width, height: r.height };
        x = r.left + r.width / 2; y = r.top + r.height / 2;
      }
      var hit = hitAt(x, y), note = null;
      if (el && hit && hit !== el && !el.contains(hit) && !hit.contains(el)) {
        note = 'covered by ' + hit.tagName.toLowerCase() + (hit.id ? '#' + hit.id : '') + ' "' + clean(hit.innerText, 40) + '" — clicked there anyway';
      }
      var at = el || hit;
      var sel = selectOf(at);
      var drag = at ? draggableOf(at) : null;
      var out = { x: x, y: y, note: note, draggable: !!drag, tag: at ? at.tagName.toLowerCase() : null };
      if (sel) { out.select = Array.prototype.map.call(sel.options, function (o) { return clean(o.text, 40); }).slice(0, 40); out.selectRef = refOf(sel); }
      return out;
    }
    if (verb === 'a.dnd') {
      // A drag the HTML way, told to the page: dragstart on what is dragged,
      // dragenter, dragover and drop on what is under the end, dragend.
      var from = hitAt(Number(args.x), Number(args.y)), onto = hitAt(Number(args.toX), Number(args.toY));
      if (!from || !onto) throw new Error('nothing there to drag or drop on');
      var source = draggableOf(from) || from;
      var dt = new DataTransfer();
      function fire(el, type, px, py) {
        var ev = new DragEvent(type, { bubbles: true, cancelable: true, clientX: px, clientY: py, dataTransfer: dt });
        return el.dispatchEvent(ev);
      }
      fire(source, 'dragstart', args.x, args.y);
      fire(onto, 'dragenter', args.toX, args.toY);
      var over = fire(onto, 'dragover', args.toX, args.toY);
      var dropped = !over;
      if (dropped) fire(onto, 'drop', args.toX, args.toY);
      fire(source, 'dragend', args.toX, args.toY);
      return { ok: true, dropped: dropped, note: dropped ? null : 'the target did not take the drop (no dragover handler called preventDefault)' };
    }
    if (verb === 'a.fill') {
      var el = target();
      el.scrollIntoView({ block: 'center', behavior: 'instant' });
      el.focus();
      var v = args.value;
      if (el.tagName === 'SELECT') {
        var want = [].concat(v).map(String);
        var found = 0;
        Array.prototype.forEach.call(el.options, function (o) {
          var hit = want.indexOf(o.value) >= 0 || want.indexOf(o.text.trim()) >= 0;
          if (el.multiple) o.selected = hit; else if (hit && !found) el.value = o.value;
          if (hit) found++;
        });
        if (!found) throw new Error('no option ' + v + ' — there are: ' + Array.prototype.map.call(el.options, function (o) { return o.text.trim(); }).slice(0, 30).join(' | '));
      } else if (el.type === 'checkbox' || el.type === 'radio') {
        var on = v === true || v === 'true' || v === 'on' || v === 1;
        if (el.checked !== on) el.click();
        return { ok: true, checked: el.checked };
      } else if (el.type === 'file') {
        throw new Error('a file field: use upload');
      } else if (el.isContentEditable) {
        el.textContent = String(v);
        el.dispatchEvent(new InputEvent('input', { bubbles: true, data: String(v), inputType: 'insertText' }));
        return { ok: true };
      } else {
        var proto = el.tagName === 'TEXTAREA' ? win(el).HTMLTextAreaElement.prototype : win(el).HTMLInputElement.prototype;
        var d = Object.getOwnPropertyDescriptor(proto, 'value');
        if (d && d.set) d.set.call(el, String(v)); else el.value = String(v);
        el.dispatchEvent(new Event('input', { bubbles: true }));
      }
      el.dispatchEvent(new Event('change', { bubbles: true }));
      return { ok: true };
    }
    if (verb === 'a.upload') {
      // Files into a file field, or dropped on a drop zone, as the page would
      // get them from the chooser or from a drag.
      var el = target();
      var input = el.tagName === 'INPUT' && el.type === 'file' ? el : (el.querySelector && el.querySelector('input[type=file]'));
      var dt = new DataTransfer();
      (args.files || []).forEach(function (f) {
        var bin = atob(f.data), bytes = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        dt.items.add(new File([bytes], f.name, { type: f.type || '', lastModified: Date.now() }));
      });
      if (!dt.files.length) throw new Error('upload needs files');
      if (input) {
        input.files = dt.files;
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
        return { ok: true, files: input.files.length, into: 'field' };
      }
      var r = box(el), px = r.left + r.width / 2, py = r.top + r.height / 2;
      ['dragenter', 'dragover', 'drop'].forEach(function (type) {
        el.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, clientX: px, clientY: py, dataTransfer: dt }));
      });
      return { ok: true, files: dt.files.length, into: 'drop' };
    }
    if (verb === 'a.scroll') {
      var dx = Number(args.dx || 0), dy = Number(args.dy || 0);
      function scroller(n) {
        while (n && n !== document.body && n !== document.documentElement) {
          var st = win(n).getComputedStyle(n);
          if ((n.scrollHeight > n.clientHeight + 1 && /(auto|scroll|overlay)/.test(st.overflowY)) || (n.scrollWidth > n.clientWidth + 1 && /(auto|scroll|overlay)/.test(st.overflowX))) return n;
          n = n.parentElement || (win(n).frameElement);
        }
        return null;
      }
      var at = args.ref || args.selector ? target() : (args.x != null && args.y != null ? hitAt(Number(args.x), Number(args.y)) : null);
      if (at && !dx && !dy) { at.scrollIntoView({ block: 'center', behavior: 'instant' }); return { ok: true, scrolled: 'into view' }; }
      var s = at ? scroller(at) : null;
      (s || (at ? win(at) : window)).scrollBy({ left: dx, top: dy, behavior: 'instant' });
      return s ? { ok: true, scrolled: 'inside ' + s.tagName.toLowerCase(), top: Math.round(s.scrollTop), of: s.scrollHeight - s.clientHeight }
               : { ok: true, scrollY: Math.round(scrollY), of: Math.max(0, document.documentElement.scrollHeight - innerHeight) };
    }
    throw new Error('unknown verb ' + verb);
    """#
}
