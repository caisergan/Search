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
// point on the page; and `a.batch` runs several steps in one request.
//
// The refs and the reading live in Search's own world (Web.world): the page
// sees none of it. Only what has to happen in the page's world does — its
// own JavaScript, and the console, which is listened to from the first time
// it is asked for.
//
// Whose tabs: the ones Claude opened (the bench's, with the flask) always;
// yours, the one in front by default, only with Settings › General › "Let
// Claude use your tabs" on.

@MainActor
extension Bench {
    /// How long a verb may take before the bench answers for it.
    static func agentPatience(_ verb: String, _ request: [String: Any]) -> Double? {
        switch verb {
        case "a.wait", "a.navigate": return (request["seconds"] as? Double ?? 20) + 5
        case "a.batch": return 120
        default: return verb.hasPrefix("a.") ? 30 : nil
        }
    }

    /// The tab a request is for. Named by the first characters of its id;
    /// unnamed, the one in front. Claude's own tabs always answer; yours only
    /// with the switch on.
    private func agentTab(_ request: [String: Any], in browser: Browser) -> Tab? {
        let yours = browser.prefs.claudeTabs || Store.testing
        guard let ref = (request["id"] as? String)?.lowercased(), !ref.isEmpty else {
            guard let tab = browser.active, yours || tab.bench else { return nil }
            return tab
        }
        return browser.tabs.first { ($0.bench || yours) && $0.id.uuidString.lowercased().hasPrefix(ref) }
    }

    /// Ready to be read or used: awake, and in a window so it is laid out.
    private func ready(_ tab: Tab) {
        tab.wake()
        if tab.web.window == nil { house(tab, any: true) }
    }

    func agent(_ verb: String, _ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let noTab: [String: Any] = ["error": browser.prefs.claudeTabs || Store.testing
            ? "no tab “\(request["id"] as? String ?? "")” — see a.tabs"
            : "no tab — Claude can use only the tabs it opened; Settings › General › “Let Claude use your tabs” lets it use yours"]

        switch verb {
        case "a.tabs":
            answer(["tabs": browser.tabs.map(describe), "yours": browser.prefs.claudeTabs || Store.testing])

        case "a.open":
            guard let url = (request["url"] as? String).flatMap(Address.url(from:)) else {
                answer(["error": "a.open needs a url"])
                return
            }
            let tab = browser.benchOpen(url)
            if request["show"] as? Bool == true, browser.prefs.claudeTabs || Store.testing { browser.select(tab) } else { house(tab) }
            if request["wait"] as? Bool == false { answer(describe(tab)); return }
            wait(for: tab, until: Date().addingTimeInterval(request["seconds"] as? Double ?? 20), answer)

        case "a.show":
            guard browser.prefs.claudeTabs || Store.testing else {
                answer(["error": "showing a tab takes your window — only with “Let Claude use your tabs” on"])
                return
            }
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            browser.select(tab)
            answer(describe(tab))

        case "a.close":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            guard tab.bench else { answer(["error": "Claude closes only the tabs it opened"]); return }
            browser.close(tab)
            answer(["closed": Bench.short(tab)])

        case "a.navigate":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            ready(tab)
            let to = request["url"] as? String ?? ""
            switch to {
            case "back": tab.back()
            case "forward": tab.forward()
            case "reload": tab.reload()
            default:
                guard let url = Address.url(from: to) else { answer(["error": "a.navigate needs a url, back, forward or reload"]); return }
                tab.go(to: url)
            }
            // A beat for the load to start, so the wait sees it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.wait(for: tab, until: Date().addingTimeInterval(request["seconds"] as? Double ?? 20), answer)
            }

        case "a.wait":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            ready(tab)
            let limit = Date().addingTimeInterval(request["seconds"] as? Double ?? 10)
            let selector = request["selector"] as? String
            let text = request["text"] as? String
            guard selector != nil || text != nil else { wait(for: tab, until: limit, answer); return }
            func poll() {
                tab.web.callAsyncJavaScript(Agent.present, arguments: ["selector": selector ?? "", "text": text ?? ""], in: nil, in: Web.world) { result in
                    MainActor.assumeIsolated {
                        if case .success(let value) = result, value as? Bool == true { answer(["ok": true]); return }
                        guard Date() < limit else { answer(["error": "not there after the wait", "timeout": true]); return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { poll() }
                    }
                }
            }
            poll()

        case "a.read", "a.find", "a.text", "a.fill", "a.scroll", "a.point", "a.focus":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            ready(tab)
            var arguments: [String: Any] = ["verb": verb]
            for key in ["filter", "ref", "query", "value", "dx", "dy", "x", "y", "max", "selector"] {
                if let value = request[key] { arguments[key] = value }
            }
            tab.web.callAsyncJavaScript(Agent.page, arguments: ["args": arguments], in: nil, in: Web.world) { result in
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let value):
                        var out = (value as? [String: Any]) ?? ["value": Bench.plain(value)]
                        if verb == "a.read" || verb == "a.text" { out["tab"] = Bench.short(tab) }
                        answer(out)
                    case .failure(let error): answer(["error": Agent.said(error)])
                    }
                }
            }

        case "a.click", "a.hover":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            ready(tab)
            point(on: tab, request) { [weak self] spot, said in
                guard let self else { return }
                guard let spot else { answer(["error": said ?? "nowhere to click"]); return }
                if verb == "a.hover" {
                    self.mouse(tab.web, at: spot, kinds: [.mouseMoved], clicks: 1, mods: [])
                    answer(["ok": true, "at": [Int(spot.x), Int(spot.y)]])
                    return
                }
                let button = request["button"] as? String ?? "left"
                let mods = Agent.flags(request["mods"])
                if button == "right" {
                    // A real right-click opens the menu modally and holds the whole
                    // app until someone closes it: the page hears the event instead.
                    tab.web.callAsyncJavaScript(Agent.contextMenu, arguments: ["x": spot.x, "y": spot.y], in: nil, in: .page) { _ in
                        MainActor.assumeIsolated { answer(["ok": true, "at": [Int(spot.x), Int(spot.y)]]) }
                    }
                    return
                }
                let count = button == "double" ? 2 : button == "triple" ? 3 : 1
                self.mouse(tab.web, at: spot, kinds: [.mouseMoved], clicks: 1, mods: mods)
                for n in 1...count {
                    self.mouse(tab.web, at: spot, kinds: [.leftMouseDown, .leftMouseUp], clicks: n, mods: mods)
                }
                var out: [String: Any] = ["ok": true, "at": [Int(spot.x), Int(spot.y)]]
                if let said { out["note"] = said }
                self.settled(tab, out, answer)
            }

        case "a.type":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            guard let text = request["text"] as? String else { answer(["error": "a.type needs text"]); return }
            ready(tab)
            let keys = request["keys"] as? Bool == true
            let go = { [weak self] in
                self?.typeText(text, into: tab.web, keys: keys) { answer(["ok": true, "typed": text.count]) }
            }
            guard request["ref"] != nil || request["selector"] != nil else { go(); return }
            // Into a field: clicked first, as a hand would, so the page sees focus.
            point(on: tab, request) { [weak self] spot, said in
                guard let self, let spot else { answer(["error": said ?? "no field"]); return }
                self.mouse(tab.web, at: spot, kinds: [.leftMouseDown, .leftMouseUp], clicks: 1, mods: [])
                go()
            }

        case "a.key":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            guard let keys = request["keys"] as? String, !keys.isEmpty else { answer(["error": "a.key needs keys, like “Enter” or “cmd+a Backspace”"]); return }
            ready(tab)
            let chords = keys.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            let unknown = chords.filter { Agent.chord($0) == nil }
            guard unknown.isEmpty else { answer(["error": "unknown keys: " + unknown.joined(separator: ", ")]); return }
            let times = max(1, min(100, request["repeat"] as? Int ?? 1))
            pressAll(Array(repeating: chords, count: times).flatMap { $0 }, on: tab.web) { [weak self] in self?.settled(tab, ["ok": true], answer) }

        case "a.shot":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            ready(tab)
            picture(tab.web, quality: request["quality"] as? Double ?? 0.6, answer)

        case "a.js":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            guard let code = request["code"] as? String else { answer(["error": "a.js needs code"]); return }
            ready(tab)
            let world: WKContentWorld = request["world"] as? String == "search" ? Web.world : .page
            // An expression's value, or a body that returns one — awaited either way.
            tab.web.callAsyncJavaScript("return (\n" + code + "\n)", arguments: [:], in: nil, in: world) { result in
                MainActor.assumeIsolated {
                    if case .success(let value) = result { answer(["value": Bench.plain(value)]); return }
                    tab.web.callAsyncJavaScript(code, arguments: [:], in: nil, in: world) { again in
                        MainActor.assumeIsolated {
                            switch again {
                            case .success(let value): answer(["value": Bench.plain(value)])
                            case .failure(let error): answer(["error": Agent.said(error)])
                            }
                        }
                    }
                }
            }

        case "a.console":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            ready(tab)
            tab.web.callAsyncJavaScript(Agent.console, arguments: ["clear": request["clear"] as? Bool ?? false], in: nil, in: .page) { result in
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let value): answer((value as? [String: Any]) ?? [:])
                    case .failure(let error): answer(["error": Agent.said(error)])
                    }
                }
            }

        case "a.network":
            guard let tab = agentTab(request, in: browser) else { answer(noTab); return }
            ready(tab)
            tab.web.callAsyncJavaScript(Agent.network, arguments: [:], in: nil, in: Web.world) { result in
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let value): answer(["requests": Bench.plain(value)])
                    case .failure(let error): answer(["error": Agent.said(error)])
                    }
                }
            }

        case "a.batch":
            guard let steps = request["steps"] as? [[String: Any]], !steps.isEmpty else { answer(["error": "a.batch needs steps"]); return }
            var results: [[String: Any]] = []
            func run(_ index: Int) {
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
                    run(index + 1)
                }
            }
            run(0)

        default:
            answer(["error": "unknown command “\(verb)”", "commands": [
                "a.tabs", "a.open", "a.show", "a.close", "a.navigate", "a.wait", "a.read", "a.find", "a.text", "a.click", "a.hover",
                "a.type", "a.key", "a.fill", "a.scroll", "a.focus", "a.point", "a.shot", "a.js", "a.console", "a.network", "a.batch",
            ]])
        }
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
                answer(out)
                return
            }
            wait(for: tab, until: Date().addingTimeInterval(15)) { page in
                out["navigated"] = ["url": page["url"] ?? "", "title": page["title"] ?? "", "timeout": page["timeout"] ?? false]
                answer(out)
            }
        }
    }

    // MARK: - pointing

    /// Where to act, in the view's own points: a ref or selector's middle,
    /// scrolled into view first, or x and y on the page as a screenshot
    /// shows it.
    private func point(on tab: Tab, _ request: [String: Any], _ then: @escaping (NSPoint?, String?) -> Void) {
        let web = tab.web
        let scale = web.pageZoom * web.magnification
        func spot(_ x: Double, _ y: Double) -> NSPoint {
            let local = NSPoint(x: x * scale, y: y * scale)
            return web.isFlipped ? local : NSPoint(x: local.x, y: web.bounds.height - local.y)
        }
        if let x = request["x"] as? Double, let y = request["y"] as? Double {
            then(spot(x, y), nil)
            return
        }
        var arguments: [String: Any] = ["verb": "a.point"]
        if let ref = request["ref"] { arguments["ref"] = ref }
        if let selector = request["selector"] { arguments["selector"] = selector }
        web.callAsyncJavaScript(Agent.page, arguments: ["args": arguments], in: nil, in: Web.world) { result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let value):
                    guard let out = value as? [String: Any] else { then(nil, "no answer"); return }
                    if let error = out["error"] as? String { then(nil, error); return }
                    guard let x = out["x"] as? Double, let y = out["y"] as? Double else { then(nil, "no place"); return }
                    then(spot(x, y), out["note"] as? String)
                case .failure(let error): then(nil, Agent.said(error))
                }
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
                eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            switch type {
            case .leftMouseDown:
                window.makeFirstResponder(web)
                web.mouseDown(with: event)
            case .leftMouseUp: web.mouseUp(with: event)
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
            var steps: [() -> Void] = []
            for (n, line) in lines.enumerated() {
                if n > 0 { steps.append { _ = self.send(Agent.chord("Enter")!, to: web) } }
                if !line.isEmpty { steps.append { web.insertText(line) } }
            }
            settle(steps, on: web, done)
            return
        }
        let chords: [Agent.Chord] = text.map { character in
            if character == "\n" { return Agent.chord("Enter")! }
            if character == "\t" { return Agent.chord("Tab")! }
            let chars = String(character)
            return Agent.Chord(code: Bench.keyCode(for: character), chars: chars, ignoring: chars.lowercased(), mods: character.isUppercase ? [.shift] : [])
        }
        settle(chords.map { chord in { _ = self.send(chord, to: web) } }, on: web, done)
    }

    /// Chords — "Enter", "cmd+a", "shift+Tab" — pressed one after another.
    private func pressAll(_ chords: [String], on web: WKWebView, _ done: @escaping () -> Void) {
        web.window?.makeFirstResponder(web)
        settle(chords.compactMap(Agent.chord).map { chord in { _ = self.send(chord, to: web) } }, on: web, done)
    }

    /// Steps that each hand the page something, run one at a time: the next
    /// only once the page has done with the last. WebKit queues key events
    /// and sends each after the one before is handled, while an edit command
    /// or a script goes at once — ⌘A after typing selected the half typed so
    /// far. A script's round trip behind each step keeps them in order.
    private func settle(_ steps: [() -> Void], on web: WKWebView, _ done: @escaping () -> Void) {
        guard let first = steps.first else { done(); return }
        first()
        web.evaluateJavaScript("0") { [weak self] _, _ in
            MainActor.assumeIsolated { self?.settle(Array(steps.dropFirst()), on: web, done) }
        }
    }

    private func send(_ chord: Agent.Chord, to web: WKWebView) -> Bool {
        let number = web.window?.windowNumber ?? 0
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: chord.mods,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: number, context: nil,
                characters: chord.chars, charactersIgnoringModifiers: chord.ignoring,
                isARepeat: false, keyCode: chord.code
            ) else { continue }
            if type == .keyDown {
                // The page hears the key first, as it does a hand's: ⌘K in
                // Slack, ⌘Enter in a composer. The editing ones — ⌘A, ⌘C,
                // ⌘V, ⌘X, ⌘Z — are menu commands in a Mac app, which a key
                // handed straight to the view never reaches: they are sent
                // as the commands too.
                web.keyDown(with: event)
                if chord.mods.contains(.command), let command = Agent.editing(chord.ignoring, shift: chord.mods.contains(.shift)) {
                    web.tryToPerform(command, with: nil)
                }
            } else {
                web.keyUp(with: event)
            }
        }
        return true
    }

    // MARK: - looking

    /// The page as it is on screen, one pixel per CSS pixel: a point on the
    /// picture is a point for `a.click`.
    private func picture(_ web: WKWebView, quality: Double, _ answer: @escaping ([String: Any]) -> Void) {
        let scale = web.pageZoom * web.magnification
        let size = NSSize(width: (web.bounds.width / scale).rounded(), height: (web.bounds.height / scale).rounded())
        let shot = WKSnapshotConfiguration()
        shot.afterScreenUpdates = true
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
                answer(["jpeg": jpeg.base64EncodedString(), "width": Int(size.width), "height": Int(size.height)])
            }
        }
    }
}

/// The page-side half, and the names of keys.
@MainActor
enum Agent {
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
        let code: UInt16
        let chars: String
        let ignoring: String
        let mods: NSEvent.ModifierFlags
    }

    /// "cmd+shift+z", "Enter", "a" as a key and the keys held with it.
    static func chord(_ text: String) -> Chord? {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.last, !name.isEmpty else { return text == "+" ? chord("shift+=") : nil }
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
        return Chord(code: code, chars: chars, ignoring: mods.contains(.shift) ? chars.uppercased() : chars.lowercased(), mods: mods)
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
        default:
            guard name.count == 1, let character = name.first else { return nil }
            return (Bench.keyCode(for: character), name)
        }
    }

    /// True once the selector matches, or the text is on the page.
    static let present = #"""
    if (selector) return !!document.querySelector(selector);
    return !!(document.body && document.body.innerText.indexOf(text) >= 0);
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

    /// The console, listened to from the first time it is asked for, in the
    /// page's world, under a symbol nothing of the page's names.
    static let console = #"""
    var K = Symbol.for('search.claude.console');
    var fresh = !window[K];
    if (fresh) {
      var buf = [];
      Object.defineProperty(window, K, { value: buf });
      var put = function (level, parts) {
        var text = Array.prototype.map.call(parts, function (x) {
          if (typeof x === 'string') return x;
          if (x instanceof Error) return x.name + ': ' + x.message;
          try { return JSON.stringify(x); } catch (e) { return String(x); }
        }).join(' ');
        buf.push({ level: level, time: Date.now(), text: text.slice(0, 2000) });
        if (buf.length > 1000) buf.shift();
      };
      ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
        var original = console[level];
        console[level] = function () { try { put(level, arguments); } catch (e) {} return original.apply(this, arguments); };
      });
      window.addEventListener('error', function (e) { put('exception', [(e.message || 'error') + ' @ ' + (e.filename || '') + ':' + (e.lineno || 0)]); });
      window.addEventListener('unhandledrejection', function (e) { put('exception', ['unhandled: ' + (e.reason && (e.reason.stack || e.reason.message) || e.reason)]); });
    }
    var out = window[K].slice();
    if (clear) window[K].length = 0;
    return { listening: true, since: fresh ? 'now — what was said before this first call was not heard' : 'the first call on this page', messages: out };
    """#

    /// What the page has fetched, as the page's own timing records it.
    static let network = #"""
    var list = performance.getEntriesByType('navigation').concat(performance.getEntriesByType('resource'));
    return list.slice(-300).map(function (e) {
      var r = { url: e.name, type: e.initiatorType || e.entryType, ms: Math.round(e.duration), start: Math.round(e.startTime) };
      if (e.responseStatus) r.status = e.responseStatus;
      if (e.transferSize) r.bytes = e.transferSize;
      return r;
    });
    """#

    /// Reading, finding, filling, scrolling and pointing, in Search's world.
    /// Refs are kept here, per element, for as long as the element lives.
    static let page = #"""
    var S = window.__claude || (window.__claude = { byId: new Map(), ids: new WeakMap(), next: 1 });
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
    function visible(el, r) {
      if (!r.width && !r.height) return false;
      var st = getComputedStyle(el);
      return st.visibility !== 'hidden' && st.display !== 'none' && st.opacity !== '0';
    }
    var INPUT_ROLE = { checkbox: 'checkbox', radio: 'radio', range: 'slider', button: 'button', submit: 'button', reset: 'button', image: 'button', file: 'button', color: 'button' };
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
      if (t === 'IFRAME') return 'iframe';
      if (t === 'DIALOG') return 'dialog';
      if (el.isContentEditable && (!el.parentElement || !el.parentElement.isContentEditable)) return 'textbox';
      if (el.hasAttribute('onclick') || (el.hasAttribute('tabindex') && el.getAttribute('tabindex') !== '-1')) return 'clickable';
      return null;
    }
    var ACTIVE = { link: 1, button: 1, textbox: 1, searchbox: 1, checkbox: 1, radio: 1, slider: 1, combobox: 1, clickable: 1, tab: 1, menuitem: 1, option: 1, switch: 1, menuitemcheckbox: 1, menuitemradio: 1, spinbutton: 1, treeitem: 1, listbox: 1 };
    function name(el) {
      var l = el.getAttribute('aria-label');
      if (l) return clean(l, 100);
      var by = el.getAttribute('aria-labelledby');
      if (by) { var t = by.split(' ').map(function (i) { var n = document.getElementById(i); return n ? n.innerText : ''; }).join(' '); if (t.trim()) return clean(t, 100); }
      if (el.labels && el.labels.length) return clean(Array.prototype.map.call(el.labels, function (x) { return x.innerText; }).join(' '), 100);
      if (el.tagName === 'IMG') return clean(el.alt, 100);
      if (el.tagName === 'INPUT' && /^(submit|button|reset)$/i.test(el.type)) return clean(el.value, 100);
      var text = clean(el.innerText || el.textContent, 100);
      if (text) return text;
      return clean(el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('name') || (el.querySelector && el.querySelector('img[alt]') ? el.querySelector('img[alt]').alt : ''), 100);
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
        else if (el.tagName === 'SELECT') s += ' value="' + clean(el.options[el.selectedIndex] ? el.options[el.selectedIndex].text : '', 60) + '"';
        else if (el.value && clean(el.value, 100) !== n) s += ' value="' + clean(el.value, 80) + '"';
        if (el.placeholder && n !== clean(el.placeholder, 100)) s += ' placeholder="' + clean(el.placeholder, 60) + '"';
        if (ty && ty !== 'text' && el.tagName === 'INPUT' && ty !== 'checkbox' && ty !== 'radio') s += ' type=' + ty;
      }
      if (el.getAttribute('aria-expanded')) s += ' expanded=' + el.getAttribute('aria-expanded');
      if (el.getAttribute('aria-selected') === 'true' || el.getAttribute('aria-current')) s += ' current';
      if (el.disabled || el.getAttribute('aria-disabled') === 'true') s += ' disabled';
      if (document.activeElement === el) s += ' focused';
      if (rl === 'link') { var h = el.getAttribute('href') || ''; if (h && h.indexOf('javascript:') !== 0) s += ' → ' + clean(h, 80); }
      var inView = r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
      s += inView ? ' @' + Math.round(r.left + r.width / 2) + ',' + Math.round(r.top + r.height / 2) : ' (offscreen)';
      return s;
    }
    function walk(root, each) {
      var stack = [root];
      while (stack.length) {
        var node = stack.pop();
        var kids = node.shadowRoot ? node.shadowRoot.children : node.children;
        if (node.nodeType === 1 && node !== root) { if (each(node) === false) continue; }
        if (kids) for (var i = kids.length - 1; i >= 0; i--) stack.push(kids[i]);
        if (node.shadowRoot && node.children) for (var j = node.children.length - 1; j >= 0; j--) stack.push(node.children[j]);
      }
    }
    function header() {
      return document.title + ' — ' + location.href + '\nviewport ' + innerWidth + '×' + innerHeight + ', scrolled ' + Math.round(scrollY) + ' of ' + Math.max(0, document.documentElement.scrollHeight - innerHeight);
    }

    var verb = args.verb;
    if (verb === 'a.read') {
      var all = args.filter === 'all';
      var max = args.max || (all ? 600 : 400);
      var root = args.ref ? byRef(args.ref) : document.documentElement;
      var out = [], count = 0, frames = 0, cut = false;
      walk(root, function (el) {
        var t = el.tagName;
        if (t === 'SCRIPT' || t === 'STYLE' || t === 'NOSCRIPT' || t === 'TEMPLATE' || t === 'SVG') return false;
        if (el.getAttribute('aria-hidden') === 'true') return false;
        var rl = role(el);
        if (!rl) return;
        if (rl === 'iframe') { frames++; return false; }
        if (!all && !ACTIVE[rl] && rl !== 'heading' && rl !== 'dialog') return;
        var r = el.getBoundingClientRect();
        if (!visible(el, r)) return false;
        if (count >= max) { cut = true; return false; }
        out.push(line(el, r, rl));
        count++;
        if (rl === 'link' || rl === 'button') return false;
      });
      var text = header() + '\n' + out.join('\n');
      if (cut) text += '\n… more than ' + max + ' — read a part with ref, or use find';
      if (frames) text += '\n(' + frames + ' frame' + (frames > 1 ? 's' : '') + ' not read)';
      return { page: text, count: count };
    }
    if (verb === 'a.find') {
      var q = String(args.query || '').toLowerCase().split(/\s+/).filter(Boolean);
      if (!q.length) throw new Error('find needs a query');
      var hits = [];
      walk(document.documentElement, function (el) {
        var t = el.tagName;
        if (t === 'SCRIPT' || t === 'STYLE' || t === 'NOSCRIPT' || t === 'TEMPLATE') return false;
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
        var r = el.getBoundingClientRect();
        if (!visible(el, r)) return;
        hits.push({ score: score + (ACTIVE[rl] ? 0.5 : 0), line: rl === 'text' ? '[' + refOf(el) + '] text "' + clean(own, 120) + '"' + (r.bottom > 0 && r.top < innerHeight ? ' @' + Math.round(r.left + r.width / 2) + ',' + Math.round(r.top + r.height / 2) : ' (offscreen)') : line(el, r, rl) });
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
    if (verb === 'a.point' || verb === 'a.focus') {
      var el = target();
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      if (verb === 'a.focus') { el.focus(); return { ok: true }; }
      var r = el.getBoundingClientRect();
      if (!r.width && !r.height) throw new Error('ref ' + (args.ref || args.selector) + ' has no size — hidden?');
      var x = r.left + r.width / 2, y = r.top + r.height / 2;
      var hit = document.elementFromPoint(x, y), note = null;
      if (hit && hit !== el && !el.contains(hit) && !hit.contains(el)) {
        note = 'covered by ' + hit.tagName.toLowerCase() + (hit.id ? '#' + hit.id : '') + ' "' + clean(hit.innerText, 40) + '" — clicked there anyway';
      }
      return { x: x, y: y, note: note };
    }
    if (verb === 'a.fill') {
      var el = target();
      el.scrollIntoView({ block: 'center', behavior: 'instant' });
      el.focus();
      var v = args.value;
      if (el.tagName === 'SELECT') {
        var opt = Array.prototype.find.call(el.options, function (o) { return o.value === String(v) || o.text.trim() === String(v); });
        if (!opt) throw new Error('no option ' + v + ' — there are: ' + Array.prototype.map.call(el.options, function (o) { return o.text.trim(); }).slice(0, 30).join(' | '));
        el.value = opt.value;
      } else if (el.type === 'checkbox' || el.type === 'radio') {
        var want = v === true || v === 'true' || v === 'on' || v === 1;
        if (el.checked !== want) el.click();
        return { ok: true, checked: el.checked };
      } else if (el.isContentEditable) {
        el.textContent = String(v);
        el.dispatchEvent(new InputEvent('input', { bubbles: true, data: String(v), inputType: 'insertText' }));
        return { ok: true };
      } else {
        var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        var d = Object.getOwnPropertyDescriptor(proto, 'value');
        if (d && d.set) d.set.call(el, String(v)); else el.value = String(v);
        el.dispatchEvent(new Event('input', { bubbles: true }));
      }
      el.dispatchEvent(new Event('change', { bubbles: true }));
      return { ok: true };
    }
    if (verb === 'a.scroll') {
      var dx = Number(args.dx || 0), dy = Number(args.dy || 0);
      if (args.ref || args.selector) {
        var el = target();
        if (!dx && !dy) { el.scrollIntoView({ block: 'center', behavior: 'instant' }); return { ok: true, scrolled: 'into view' }; }
        var box = el;
        while (box && box !== document.body && !(box.scrollHeight > box.clientHeight + 1 || box.scrollWidth > box.clientWidth + 1)) box = box.parentElement;
        (box && box !== document.body ? box : window).scrollBy({ left: dx, top: dy, behavior: 'instant' });
      } else if (args.x != null && args.y != null) {
        var box = document.elementFromPoint(Number(args.x), Number(args.y));
        while (box && box !== document.body && !(box.scrollHeight > box.clientHeight + 1 || box.scrollWidth > box.clientWidth + 1)) box = box.parentElement;
        (box && box !== document.body && box !== document.documentElement ? box : window).scrollBy({ left: dx, top: dy, behavior: 'instant' });
      } else {
        window.scrollBy({ left: dx, top: dy, behavior: 'instant' });
      }
      return { ok: true, scrollY: Math.round(scrollY), height: document.documentElement.scrollHeight };
    }
    throw new Error('unknown verb ' + verb);
    """#
}
