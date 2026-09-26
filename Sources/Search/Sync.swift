import AppKit
import CryptoKit
import Foundation

// Settings that follow you from one Mac to the next, through iCloud Drive.
//
// No account and no server of Search's: a file in your own iCloud Drive,
// Search/Settings.json, that each Mac writes when its settings change and
// reads when it opens. Settings › General › Sync settings through iCloud
// Drive, off unless turned on, on each Mac.
//
// What goes: the settings, the shortcuts, where each site is zoomed and
// where ads aren't blocked, the sites never to save a password for, the
// bookmarks, what is hidden on each site, and which extensions are
// installed — added on the other Mac only when you say so there. What
// never goes: passwords, sign-ins and cookies, history and tabs (Transfer
// Tabs is for those), and anything that grants something — the script and
// Claude switches, the access an extension was given, the camera and the
// microphone. Those are for each Mac to say for itself, and a file in the
// cloud is not trusted to say them: only the names below are read from it.
//
// The last Mac to change something wins. What another Mac wrote is taken in
// when Search opens, before anything has been read, since the window reads
// its settings once; one arriving while Search is open waits for the next
// time, and meanwhile nothing is written over it.

@MainActor
enum SettingsSync {
    // MARK: - what goes

    /// The settings that go, by name. Nothing else is read from the file.
    static let names: Set<String> = [
        "autocorrect", "autoscroll", "bookmarks.bar", "extensions.private",
        "float.away", "float.flicks", "float.leave", "fullscreen.window",
        "glance", "glance.trigger", "glyph", "inspector", "links.little", "links.peek", "links.show",
        "look", "manner", "newtab.over", "newtab.spot", "pages.120", "passkeys",
        "passwords.fill", "passwords.save", "passwords.never", "pinned.load",
        "search.custom", "search.engine", "shield", "shield.paused",
        "sidebar", "sidebar.address", "sidebar.hides", "sidebar.newtab.foot", "sidebar.pinned.folded",
        "sidebar.reveal", "sidebar.width", "start.load", "tabs.reading", "tabs.size", "tabs.sleep",
        "theme", "zoomspot", "downloads.ask", "shortcuts", "shortcuts.extensions",
        "WebAutomaticDashSubstitutionEnabled", "WebAutomaticQuoteSubstitutionEnabled",
        "WebAutomaticSpellingCorrectionEnabled",
    ]
    /// And every setting under these: a site's zoom.
    static let prefixes = ["zoom."]
    /// Files of Search's folder that go, whole.
    static let files = ["bookmarks.json", "hidden.json"]

    static func goes(_ key: String) -> Bool {
        names.contains(key) || prefixes.contains { key.hasPrefix($0) }
    }

    // MARK: - where

    private static let store = Store.settings

    /// Settings › General. This Mac's own, never synced.
    static var on: Bool {
        get { store.bool(forKey: "sync.on") }
        set { store.set(newValue, forKey: "sync.on") }
    }

    /// iCloud Drive's folder on this Mac; nil when iCloud Drive is off.
    static var drive: URL? {
        let docs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: docs.path) ? docs : nil
    }

    /// Search/Settings.json in it. Test worlds share one of their own, so
    /// two of them stand in for two Macs and never touch yours.
    static var file: URL? {
        drive?.appendingPathComponent("Search", isDirectory: true)
            .appendingPathComponent(Store.testing ? "Settings (test).json" : "Settings.json")
    }

    /// This Mac, to know its own writing when it comes back.
    static var device: String {
        if let id = store.string(forKey: "sync.device") { return id }
        let id = UUID().uuidString
        store.set(id, forKey: "sync.device")
        return id
    }

    static var macName: String { Host.current().localizedName ?? "Mac" }

    // MARK: - the file

    struct Snapshot: Codable {
        var format = 1
        var from: String
        var device: String
        var saved: Date
        /// The settings, as a property list — they are of every kind.
        var settings: Data
        var files: [String: Data]
        var extensions: [Extension]

        struct Extension: Codable, Equatable {
            let id: String
            let name: String
        }

        /// What it holds, not who wrote it when: two Macs with the same
        /// settings hold the same. Not the extensions: each Mac has those it
        /// was let add, and the list is every Mac's together (see push).
        var content: String {
            var hash = SHA256()
            // The settings as read, in order: a property list of the same
            // settings comes out in a different order from each process, and
            // two Macs alike looked different to each other.
            let read = (try? PropertyListSerialization.propertyList(from: settings, options: [], format: nil)) ?? [:]
            hash.update(data: Data(Snapshot.canonical(read).utf8))
            for name in files.keys.sorted() {
                hash.update(data: Data(name.utf8))
                hash.update(data: files[name] ?? Data())
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }

        /// A value written the same way wherever and whenever it is.
        static func canonical(_ value: Any) -> String {
            switch value {
            case let d as [String: Any]:
                return "{" + d.keys.sorted().map { "\($0.debugDescription):\(canonical(d[$0]!))" }.joined(separator: ",") + "}"
            case let a as [Any]:
                return "[" + a.map(canonical).joined(separator: ",") + "]"
            case let data as Data:
                return "d:" + data.base64EncodedString()
            case let date as Date:
                return "t:\(date.timeIntervalSince1970)"
            case let string as String:
                return string.debugDescription
            case let number as NSNumber:
                return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : "n:\(number.doubleValue)"
            default:
                return "\(value)"
            }
        }
    }

    /// What this Mac has now.
    static func current() -> Snapshot {
        var settings: [String: Any] = [:]
        for (key, value) in store.dictionaryRepresentation() where goes(key) { settings[key] = value }
        let plist = (try? PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0)) ?? Data()
        var files: [String: Data] = [:]
        for name in SettingsSync.files {
            if let data = try? Data(contentsOf: Store.file(name)) { files[name] = data }
        }
        var extensions: [Snapshot.Extension] = []
        let list = Store.folder.appendingPathComponent("Extensions", isDirectory: true).appendingPathComponent("installed.json")
        if let data = try? Data(contentsOf: list),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for item in list where item["fromStore"] as? Bool == true {
                if let id = item["id"] as? String { extensions.append(.init(id: id, name: item["name"] as? String ?? id)) }
            }
        }
        extensions.sort { $0.id < $1.id }
        return Snapshot(from: macName, device: device, saved: Date(), settings: plist, files: files, extensions: extensions)
    }

    /// The file as it is in iCloud Drive, if it is there to read — asked to
    /// come down if iCloud has only its name on this Mac.
    static func remote() -> Snapshot? {
        guard let file else { return nil }
        let manager = FileManager.default
        let placeholder = file.deletingLastPathComponent().appendingPathComponent("." + file.lastPathComponent + ".icloud")
        if !manager.fileExists(atPath: file.path) {
            if manager.fileExists(atPath: placeholder.path) { try? manager.startDownloadingUbiquitousItem(at: file) }
            return nil
        }
        var data: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &error) { url in
            data = try? Data(contentsOf: url)
        }
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    // MARK: - who is newer

    /// The last change here to what goes, as far as Search has seen one.
    private static var changed: Date {
        get { store.object(forKey: "sync.changed") as? Date ?? .distantPast }
        set { store.set(newValue, forKey: "sync.changed") }
    }
    /// When the settings last written or taken in were saved.
    private static var synced: Date {
        get { store.object(forKey: "sync.synced") as? Date ?? .distantPast }
        set { store.set(newValue, forKey: "sync.synced") }
    }
    /// What this Mac had the last time it was looked at, this launch.
    private static var seen: String?

    /// A change here is noted when what this Mac has differs from what it
    /// had when last looked at.
    private static func note(_ now: Snapshot) {
        if let seen, seen != now.content { changed = Date() }
        seen = now.content
    }

    /// Another Mac's, saved after this one last synced and after anything
    /// here last changed: the last change anywhere wins.
    private static func newer(_ there: Snapshot, than now: Snapshot) -> Bool {
        there.device != device && there.content != now.content && there.saved > synced && there.saved > changed
    }

    /// Another Mac's that holds just what this one has: nothing to write,
    /// nothing to wait for.
    private static func same(_ there: Snapshot, as now: Snapshot) -> Bool {
        guard there.content == now.content else { return false }
        store.set(there.content, forKey: "sync.content")
        if there.saved > synced { synced = there.saved }
        return true
    }

    // MARK: - out

    /// Written when what this Mac has differs from what was last written or
    /// taken in — unless another Mac's is newer, which waits for the next
    /// launch rather than being written over.
    static func push() {
        guard on, !leaving, let file else { return }
        let there = remote()
        var now = current()
        note(now)
        if let there {
            _ = same(there, as: now)
            if newer(there, than: now) {
                waiting = true
                return
            }
        }
        waiting = false
        // Every Mac's extensions together: one without an extension another
        // has doesn't take it off the list — it has it offered instead. By id:
        // the names are in each Mac's language.
        let theirs = there?.extensions ?? []
        let merged = (now.extensions + theirs.filter { t in !now.extensions.contains { $0.id == t.id } }).sorted { $0.id < $1.id }
        let grew = Set(merged.map(\.id)) != Set(theirs.map(\.id))
        now.extensions = merged
        guard now.content != store.string(forKey: "sync.content") || grew else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(now) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var error: NSError?
        var wrote = false
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &error) { url in
            wrote = (try? data.write(to: url, options: .atomic)) != nil
        }
        guard wrote else { return }
        store.set(now.content, forKey: "sync.content")
        synced = now.saved
        store.set(Date(), forKey: "sync.when")
        store.set(macName, forKey: "sync.who")
    }

    // MARK: - in

    /// Another Mac's settings, newer than what this one has, waiting for the
    /// next launch to be taken in.
    private(set) static var waiting = false
    /// Closing to open again with another Mac's: nothing more is written.
    private static var leaving = false

    /// At launch, before the window reads a single setting: what another Mac
    /// wrote, if it is newer, taken in. Extensions it has are asked about
    /// once the window is up (see offerExtensions).
    static func pullAtLaunch() {
        guard on, let theirs = remote() else { return }
        let now = current()
        if !same(theirs, as: now), newer(theirs, than: now) { apply(theirs) }
        remember(missingFrom: theirs)
    }

    /// The extensions another Mac has and this one hasn't — nor has said no to.
    private static func remember(missingFrom theirs: Snapshot) {
        let mine = Set(current().extensions.map(\.id))
        let declined = Set(store.stringArray(forKey: "sync.declined") ?? [])
        let missing = theirs.extensions.filter {
            !mine.contains($0.id) && !declined.contains($0.id) && $0.id.range(of: "^[a-p]{32}$", options: .regularExpression) != nil
        }
        if missing.isEmpty { store.removeObject(forKey: "sync.extensions") }
        else if let data = try? JSONEncoder().encode(missing) { store.set(data, forKey: "sync.extensions") }
    }

    private static func apply(_ theirs: Snapshot) {
        // Settings: only the names that go, and only values a setting can be.
        if let settings = try? PropertyListSerialization.propertyList(from: theirs.settings, options: [], format: nil) as? [String: Any] {
            for (key, value) in settings where goes(key) {
                switch value {
                case is Bool, is String, is NSNumber, is Data, is [String], is [String: Any], is Date: store.set(value, forKey: key)
                default: continue
                }
            }
            // A setting the other Mac no longer has goes here too.
            for key in store.dictionaryRepresentation().keys where goes(key) && settings[key] == nil {
                store.removeObject(forKey: key)
            }
        }
        for (name, data) in theirs.files where files.contains(name) {
            // Only files that read as what they are.
            guard (try? JSONSerialization.jsonObject(with: data)) != nil else { continue }
            try? data.write(to: Store.file(name), options: .atomic)
        }
        // What was taken in, as it was: what this Mac has beyond it — a file
        // the other Mac hasn't got, bookmarks it never made — goes out next,
        // rather than being taken for a change of theirs still to come.
        store.set(theirs.content, forKey: "sync.content")
        synced = theirs.saved
        store.set(theirs.saved, forKey: "sync.when")
        store.set(theirs.from, forKey: "sync.who")
    }

    /// Once the window is up: the extensions the other Mac has, asked about
    /// once, each then added the way any is — asked again with what it wants.
    @available(macOS 15.4, *)
    static func offerExtensions(_ extensions: Extensions) {
        guard let data = store.data(forKey: "sync.extensions"),
              let missing = try? JSONDecoder().decode([Snapshot.Extension].self, from: data), !missing.isEmpty
        else { return }
        store.removeObject(forKey: "sync.extensions")
        // A test run has nobody to ask: what would have been offered is kept for the bench.
        if Store.testing {
            offered = missing.map(\.name)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Add the extensions your other Mac has?"
        alert.informativeText = missing.map(\.name).joined(separator: ", ")
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Not on This Mac")
        guard alert.runModal() == .alertFirstButtonReturn else {
            // Not asked again for these.
            store.set(Array(Set((store.stringArray(forKey: "sync.declined") ?? []) + missing.map(\.id))).sorted(), forKey: "sync.declined")
            return
        }
        for item in missing { extensions.install(from: item.id) }
    }

    /// What differs between this Mac and the file, by setting — for the bench.
    static func differences() -> [String] {
        guard let theirs = remote() else { return ["no file"] }
        let now = current()
        func read(_ data: Data) -> [String: Any] {
            (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]) ?? [:]
        }
        let mine = read(now.settings), there = read(theirs.settings)
        var out: [String] = []
        for key in Set(mine.keys).union(there.keys).sorted() {
            let a = mine[key].map { "\($0)" }, b = there[key].map { "\($0)" }
            if a != b { out.append("\(key): \(a ?? "–") ≠ \(b ?? "–")") }
        }
        for name in Set(now.files.keys).union(theirs.files.keys).sorted() where now.files[name] != theirs.files[name] {
            out.append("file \(name)")
        }
        return out
    }

    /// The extensions last offered, in a test run (see offerExtensions).
    static var offered: [String] = []

    // MARK: - while open

    private static var watcher: DispatchSourceFileSystemObject?
    private static var pending: DispatchWorkItem?
    private static var observers: [NSObjectProtocol] = []
    private static var timer: Timer?

    /// Changes here written out a moment after they settle, and the file
    /// watched for another Mac's.
    static func start(announce: @escaping (String) -> Void) {
        stop()
        guard on else { return }
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { soon() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { push() }
        })
        // Bookmarks and what is hidden are files, not settings: looked at
        // now and then.
        let every = Timer(timeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { push() } }
        every.tolerance = 15
        RunLoop.main.add(every, forMode: .common)
        timer = every
        watch(announce: announce)
        push()
    }

    static func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        timer?.invalidate()
        timer = nil
        watcher?.cancel()
        watcher = nil
    }

    private static func soon() {
        pending?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { push() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// The folder rather than the file: iCloud puts a new file in place of
    /// the old one, and a watch on the old one hears nothing more.
    private static func watch(announce: @escaping (String) -> Void) {
        guard let folder = file?.deletingLastPathComponent() else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let handle = open(folder.path, O_EVTONLY)
        guard handle >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: handle, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                guard let theirs = remote(), theirs.device != device else { return }
                let now = current()
                note(now)
                // What this Mac has already: nothing to wait for.
                if same(theirs, as: now) {
                    waiting = false
                    return
                }
                guard newer(theirs, than: now) else { return }
                if !waiting { announce("Settings from \(theirs.from) — they apply the next time Search opens") }
                waiting = true
            }
        }
        source.setCancelHandler { close(handle) }
        source.resume()
        watcher = source
    }

    // MARK: - turning it on

    /// Settings › General's switch turned on. With another Mac's settings
    /// already there, asked which to keep; taking theirs opens Search again
    /// to take them in.
    static func turnOn(announce: @escaping (String) -> Void) {
        if let theirs = another() {
            let alert = NSAlert()
            let when = DateFormatter.localizedString(from: theirs.saved, dateStyle: .medium, timeStyle: .short)
            alert.messageText = "Use the settings from \(theirs.from)?"
            alert.informativeText = "Saved \(when). Search opens again to take them in; your tabs come back. Or keep this Mac's, and \(theirs.from) takes these the next time it opens."
            alert.addButton(withTitle: "Use Them")
            alert.addButton(withTitle: "Keep This Mac's")
            if alert.runModal() == .alertFirstButtonReturn { useTheirs() } else { keepMine(announce: announce) }
            return
        }
        on = true
        start(announce: announce)
    }

    /// Another Mac's settings in iCloud Drive, differing from this one's.
    static func another() -> Snapshot? {
        guard let theirs = remote(), theirs.device != device, theirs.content != current().content else { return nil }
        return theirs
    }

    /// Theirs: Search opens again and takes them in before it reads anything.
    static func useTheirs() {
        on = true
        // Not written over while Search closes and opens again.
        leaving = true
        relaunch()
    }

    /// This Mac's: written over theirs, which the other Mac takes the next time it opens.
    static func keepMine(announce: @escaping (String) -> Void) {
        on = true
        // Theirs seen and passed over: this Mac's is written in its place, as
        // the newer.
        if let theirs = remote() { synced = theirs.saved }
        store.removeObject(forKey: "sync.content")
        changed = Date()
        start(announce: announce)
    }

    static func turnOff() {
        on = false
        stop()
    }

    /// Search again, as it was: its session brings the tabs back.
    static func relaunch() {
        // The new one once this one has gone, so they don't share the folder:
        // open(1), a second after, outlives this process.
        var arguments = ["-c", "sleep 1; exec /usr/bin/open -n \"$0\" \"$@\"", Bundle.main.bundleURL.path]
        if let world = Store.world { arguments += ["--env", "SEARCH_PROBE=\(world)"] }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = arguments
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    }
}
