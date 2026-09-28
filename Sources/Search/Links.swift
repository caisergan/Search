import AppKit

// Links from elsewhere. A click in Mail, in Slack, in a PDF — macOS hands the
// address to whichever app owns http, and this is how that app takes it.
//
// The bundle says it owns http and https (build.sh writes that into the
// plist); this is the other half. Addresses can arrive before the window has
// been built, so they wait here until the browser says it is ready for them.

final class Links: NSObject, NSApplicationDelegate {
    /// Where an address goes once there is somewhere for it to go.
    private static var deliver: ((URL) -> Void)?
    /// Addresses that arrived first.
    private static var waiting: [URL] = []
    /// The browser's window, once there is one.
    static weak var window: NSWindow?
    /// Whether the window has been asked for on a link's behalf (summon).
    private static var summoned = false
    /// The session, written now rather than whenever its own debounce was
    /// going to get to it. ⌘Q, the red button and an update's relaunch all
    /// end the process the same way, and none of them owed the last 1.2
    /// seconds of typing anywhere to finish writing it down on their own.
    private static var flush: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        Links.flush?()
    }

    /// Downloads still coming in are asked about first, and kept to go on
    /// with next time (see Downloads.swift).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { Downloads.shared.shouldQuit() }
    }

    /// The nearest thing to a crash reporter a browser with no server can
    /// have: nothing is sent anywhere, but a beta with no record of what
    /// went wrong is a beta nobody can fix. One line, appended, so it
    /// survives the crash that is about to end the process.
    static func watchForTrouble() {
        NSSetUncaughtExceptionHandler { exception in
            let line = "\(Date()) — \(exception.name.rawValue): \(exception.reason ?? "?")\n"
                + exception.callStackSymbols.joined(separator: "\n") + "\n\n"
            let file = Store.file("crash.log")
            if let handle = FileHandle(forWritingAtPath: file.path) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8) ?? Data())
                handle.closeFile()
            } else {
                try? FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true)
                try? line.write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Addresses and files come in as Apple Events. Taking them straight
    /// from the event manager keeps them out of SwiftUI's hands: left to it,
    /// every address handed at launch had the window presented afresh, and
    /// five of them meant five rebuilds of the content before the window
    /// had shown once. A file it handled by closing the window and opening
    /// it again — and a window in full screen came out of that belonging to
    /// no Space at all: still open, on no screen, with the page nobody could
    /// see. Set here, before the launch's own event arrives, they stand in
    /// for AppKit's.
    func applicationWillFinishLaunching(_ notification: Notification) {
        Links.watchForTrouble()
        let events = NSAppleEventManager.shared()
        events.setEventHandler(
            self, andSelector: #selector(handle(getURL:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
        events.setEventHandler(
            self, andSelector: #selector(handle(openDocuments:reply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    /// A launch macOS doesn't call a plain one — started hidden, as `open -j`
    /// or anything asking for a hidden launch does — SwiftUI treats like the
    /// launch a link makes below: it leaves its window to whatever the launch
    /// came for, and nothing comes. The app ran with no window at all. The
    /// window is asked for here instead; started hidden, it stays hidden
    /// with the app until the app is shown.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Launch.mark("launched")
        let plain = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        guard !plain else { return }
        DispatchQueue.main.async {
            guard Links.browserWindow() == nil else { return }
            Links.summon()
        }
    }

    @objc private func handle(getURL event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text), url.scheme?.lowercased().hasPrefix("http") == true
        else { return }
        Links.take(url)
    }

    /// Files the system opens with the app: a page on this Mac — an .html
    /// or .xhtml double-clicked in the Finder once Search is the Mac's
    /// browser (it says it can open them, see build.sh), dropped on the Dock
    /// icon, or opened with Search — or a saved link.
    @objc private func handle(openDocuments event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let files = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return }
        let items = files.numberOfItems > 0 ? (1...files.numberOfItems).compactMap { files.atIndex($0) } : [files]
        for file in items.compactMap(\.fileURLValue) {
            if let url = Links.address(of: file) { Links.take(url) }
        }
    }

    /// Where a file opened with the app goes: a page is itself; a saved link
    /// (.webloc, which the Finder hands here too) is the address inside it,
    /// rather than the file drawn as text.
    private static func address(of file: URL) -> URL? {
        guard file.pathExtension.lowercased() == "webloc" else { return file }
        guard let data = try? Data(contentsOf: file),
              let saved = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let text = saved["URL"] as? String, let url = URL(string: text),
              url.isFileURL || url.scheme?.lowercased().hasPrefix("http") == true
        else { return nil }
        return url
    }

    /// The Dock icon clicked with the window closed, or put in the Dock:
    /// bring the window back rather than doing nothing, which is what a
    /// hidden-title-bar SwiftUI window does by default. Whether macOS says a
    /// window is showing doesn't decide it — the rooms pages wait in count
    /// (see Backstage), so it always said one was.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if let window = Links.browserWindow(), window.isVisible, !window.isMiniaturized { return }
            Links.bringWindow()
        }
        return false
    }

    /// The browser, once it has a window. Anything that came earlier is
    /// handed over now — but none of it before the window is on screen.
    ///
    /// Five addresses at launch used to mean five web views built before the
    /// first frame, and a window that took a second to appear instead of a
    /// third of one. Now the window comes first; the first page goes into
    /// the blank tab that is already there, and the others fill in behind
    /// it, a few frames apart, in the order they came.
    @MainActor
    static func hand(to browser: Browser) {
        deliver = { [weak browser] url in
            // In a small window of its own, for whoever chose that.
            if let browser, browser.prefs.littleLinks {
                LittleWindow.show(url, for: browser)
                return
            }
            browser?.arrive(url)
            // The window closed with the app still running: the link brings
            // it back, rather than landing in a tab nobody can see.
            bringWindow()
            comeForward()
        }
        flush = { [weak browser] in browser?.flushSession() }
        let early = waiting
        waiting = []
        guard let first = early.first else { return }
        onceShown { [weak browser] in
            browser?.arrive(first)
            comeForward()
            for (n, url) in early.dropFirst().enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(n + 1)) { [weak browser] in
                    browser?.open(url, foreground: false, atEnd: true)
                }
            }
        }
    }

    /// Runs once a window is actually showing, and one turn of the run loop
    /// after that, so the frame is on the screen before the work starts.
    /// Gives up waiting after a second or so and runs anyway — a launch
    /// started hidden has a window nobody can see yet.
    @MainActor
    static func onceShown(_ then: @escaping () -> Void, tries: Int = 0) {
        let shown = NSApp.windows.contains { $0.isVisible && $0.contentView != nil && !($0 is Room) }
        if shown || tries > 40 {
            DispatchQueue.main.async(execute: then)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { onceShown(then, tries: tries + 1) }
        }
    }

    /// In front of the app the link was clicked in, the way a browser comes
    /// forward for Mail. Since macOS 14 an app is let in front when it is
    /// asked to open something, and asks with `activate()`; the old call's
    /// "ignoring other apps" is ignored.
    @MainActor
    private static func comeForward() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// The browser's window: what `window` points at, or found again in the
    /// app's own list if that reference lapsed — which once opened a second,
    /// empty window behind the other app. Never a room a page waits in (see
    /// Backstage): a window too, and always open.
    @MainActor
    static func browserWindow() -> NSWindow? {
        if let window { return window }
        let found = NSApp.windows.first { $0.contentView != nil && !($0 is NSPanel) && !($0 is Room) && $0.canBecomeMain }
        if let found { window = found }
        return found
    }

    /// The browser's window in front, wherever it is — in a Space of its own,
    /// full screen, in the Dock — or made again if it was closed.
    @MainActor
    static func bringWindow() {
        guard let window = browserWindow() else {
            _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private static func take(_ url: URL) {
        if let deliver {
            deliver(url)
        } else {
            waiting.append(url)
            DispatchQueue.main.async { summon() }
        }
    }

    /// A link that launches the app arrives as an Apple Event, taken above,
    /// and SwiftUI — seeing a launch that came to open something rather than
    /// a plain one — leaves its window for that event to open. It never sees
    /// the event, so nothing opened it: every link clicked in another app
    /// while Search was closed launched it with no window and the page
    /// nowhere. SwiftUI's delegate is asked instead for what a plain launch
    /// gets, its window; a single window, so asking twice can't make two.
    @MainActor
    private static func summon() {
        guard deliver == nil, window == nil, !summoned else { return }
        summoned = true
        _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
    }

    /// ⌘⇧F, the Help menu, and the About page all come here: a draft, in
    /// Mail, that already knows what build this is. The person still reads
    /// it and presses send themselves — nothing here sends anything.
    static func writeFeedback() {
        var text = URLComponents()
        text.scheme = "mailto"
        text.path = "hello@officecommun.com"
        text.queryItems = [
            URLQueryItem(name: "subject", value: "Search feedback — \(Updater.version) (\(Updater.build))"),
            URLQueryItem(name: "body", value: "\n\n—\nSearch \(Updater.version), build \(Updater.build), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"),
        ]
        guard let url = text.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - being the browser

    private static let probe = URL(string: "https://example.com")!

    /// True when this app is where links from other apps go.
    static var isDefault: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Asks macOS to send http and https here. The system puts up its own
    /// confirmation; the answer arrives through `done`, on the main thread.
    static func becomeDefault(_ done: @escaping (Bool) -> Void) {
        let app = Bundle.main.bundleURL
        let group = DispatchGroup()
        var worked = true
        for scheme in ["http", "https"] {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) { error in
                if error != nil { worked = false }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(worked) }
    }
}
