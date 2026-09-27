import AppKit
import Combine
import WebKit

// Every file coming in, and every one that came. WebKit does the fetching and
// the writing; this is the part that watches: how far along each one is, how
// fast, how long it has left, and what can still be done with it — paused and
// picked up again, cancelled, tried again, opened, found.
//
// The list is kept in downloads.json, beside the rest of what Search keeps,
// in the shape the old list of finished files had (name, from, path, date)
// and more beside it, so nothing written before is lost and nothing written
// now is unreadable to the version before.
//
// A download still coming in when Search quits is stopped where it is, and
// what WebKit needs to go on with it is written down: it comes back paused,
// and a click picks it up from there — when the server allows it. One that
// doesn't gets downloaded again from the start instead.

/// One file, coming in or come.
@MainActor
final class Download: ObservableObject, Identifiable {
    enum State: Equatable {
        /// Asked for; the server hasn't answered yet.
        case starting
        case running
        /// Stopped by you, or by Search quitting.
        case paused
        case done
        case failed(String)
        case cancelled
    }

    let id: UUID
    /// A number of its own, for extensions, which count downloads in integers.
    let number: Int
    @Published var name: String
    @Published var file: URL?
    @Published var state: State
    @Published var received: Int64
    /// -1 while the server hasn't said.
    @Published var expected: Int64
    /// Bytes a second, smoothed over the last few seconds.
    @Published var speed: Double = 0
    @Published var finished: Date?
    /// Where it was fetched from, and the page that asked.
    let source: URL?
    let page: URL?
    let started: Date
    var mime: String?

    /// What WebKit needs to go on from where it stopped.
    var resumeData: Data?
    /// WebKit's download, while there is one.
    var task: WKDownload?
    /// The page it came through, to go on with it through the same one.
    weak var web: WKWebView?
    /// How it is being taken up again, so the destination asked for twice
    /// is answered the right way: the partial file kept, or thrown away.
    var again: Again?
    enum Again { case resuming, restarting }
    /// Set while a pause is on its way: the failure WebKit reports for it is
    /// the pause, not a failure.
    var stopping = false
    /// Bytes seen, and when, for the speed.
    var samples: [(time: TimeInterval, bytes: Int64)] = []

    init(id: UUID = UUID(), number: Int, name: String, file: URL?, state: State,
         received: Int64 = 0, expected: Int64 = -1, source: URL?, page: URL?,
         started: Date = Date(), finished: Date? = nil) {
        self.id = id
        self.number = number
        self.name = name
        self.file = file
        self.state = state
        self.received = received
        self.expected = expected
        self.source = source
        self.page = page
        self.started = started
        self.finished = finished
    }

    var active: Bool { state == .starting || state == .running }
    var failed: Bool { if case .failed = state { return true } else { return false } }
    /// Paused, failed or cancelled: something that can be taken up again.
    var stopped: Bool { state == .paused || state == .cancelled || failed }

    /// 0…1, or nil while the size isn't known.
    var fraction: Double? {
        guard expected > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(expected)))
    }

    /// Seconds left at the pace it is going.
    var remaining: TimeInterval? {
        guard state == .running, expected > 0, speed > 1 else { return nil }
        return Double(max(0, expected - received)) / speed
    }

    var host: String { source?.host() ?? page?.host() ?? "" }

    /// On disk, where it was put.
    var there: Bool { file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
}

@MainActor
final class Downloads: NSObject, ObservableObject {
    static let shared = Downloads()

    /// Newest first.
    @Published private(set) var items: [Download] = []
    /// How many are coming in right now.
    @Published private(set) var count = 0
    /// How many are paused, waiting to be picked up again.
    @Published private(set) var held = 0
    /// Everything coming in, together: 0…1, nil when nothing is, or nothing
    /// coming in has said how big it is.
    @Published private(set) var overall: Double?

    /// A download given its name and place — what the window shows arriving.
    let began = PassthroughSubject<Download, Never>()
    /// A download done, failed or cancelled.
    let ended = PassthroughSubject<Download, Never>()

    weak var browser: Browser?

    /// The Finder, the Dock and notifications (see DownloadsMac.swift).
    private let mac = DownloadsMac()
    private var clock: Timer?
    private var numbered = 0
    /// Something to go on with a download through when the page it came
    /// from has gone. Made the first time it is needed.
    private var spare: WKWebView?
    /// Asked once per quit, not once per click on Quit.
    private var quitting = false

    /// A hundred is more than anybody scrolls back through.
    private static let kept = 100

    private override init() {
        super.init()
        load()
        tick()
    }

    var running: [Download] { items.filter(\.active) }

    func item(_ id: UUID) -> Download? { items.first { $0.id == id } }

    // MARK: - coming in

    /// A download WebKit has started, from a link, a response it can't show,
    /// a menu, or an extension. Heard from until it ends.
    @discardableResult
    func track(_ task: WKDownload, page: URL? = nil) -> Download {
        numbered += 1
        let item = Download(
            number: numbered,
            name: task.originalRequest?.url?.lastPathComponent ?? "download",
            file: nil,
            state: .starting,
            source: task.originalRequest?.url,
            page: page ?? task.webView?.url
        )
        attach(task, to: item)
        items.insert(item, at: 0)
        trim()
        if heard {
            told[item.id] = fields(item)
            note("onCreated", Downloads.chrome(item))
        }
        tick()
        return item
    }

    /// A file handed over whole rather than fetched — the PDF viewer's own
    /// download button — written where downloads go and listed as one that
    /// has come, arriving at the button like any other.
    func keep(_ data: Data, named suggested: String, from source: URL?, page: URL?) {
        let name = suggested.isEmpty ? (source?.lastPathComponent ?? "download") : suggested
        let folder = browser?.downloadsFolder
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var file = free(name, in: folder)
        if browser?.prefs.asksWhereToSave == true {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.directoryURL = folder
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
            file = url
        }
        do {
            try data.write(to: file, options: .withoutOverwriting)
        } catch {
            browser?.announce("Couldn't save \(name)")
            return
        }
        // Marked as from the web, as WebKit marks what it downloads itself.
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Search",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ].merging(source.map { [kLSQuarantineDataURLKey as String: $0] } ?? [:]) { a, _ in a }
            .merging(page.map { [kLSQuarantineOriginURLKey as String: $0] } ?? [:]) { a, _ in a }
        try? file.setResourceValues(values)

        numbered += 1
        let size = Int64(data.count)
        let item = Download(
            number: numbered, name: file.lastPathComponent, file: file, state: .running,
            received: 0, expected: size, source: source, page: page
        )
        items.insert(item, at: 0)
        trim()
        if heard {
            told[item.id] = fields(item)
            note("onCreated", Downloads.chrome(item))
        }
        began.send(item)
        item.state = .done
        item.received = size
        item.finished = Date()
        tick()
        save()
        ended.send(item)
        mac.ended(item)
    }

    private func attach(_ task: WKDownload, to item: Download) {
        task.delegate = self
        item.task = task
        if let web = task.webView { item.web = web }
        item.samples = []
        item.speed = 0
        wind()
    }

    // MARK: - what can be done with one

    /// Stops it where it is, keeping what WebKit needs to go on from there.
    func pause(_ item: Download) {
        guard item.active, let task = item.task else { return }
        item.stopping = true
        item.state = .paused
        item.speed = 0
        task.cancel { [weak self, weak item] data in
            DispatchQueue.main.async {
                guard let self, let item else { return }
                item.resumeData = data
                item.task = nil
                item.stopping = false
                self.tick()
                self.save()
            }
        }
        tick()
    }

    /// Goes on from where it stopped, or — when the server won't allow that,
    /// or nothing was kept — starts it again.
    func resume(_ item: Download) {
        guard item.stopped, !item.stopping else { return }
        guard let data = item.resumeData, let web = carrier(for: item) else {
            restart(item)
            return
        }
        item.resumeData = nil
        item.again = .resuming
        item.state = .starting
        item.finished = nil
        forgetResumeFile(item)
        web.resumeDownload(fromResumeData: data) { [weak self, weak item] task in
            guard let self, let item else { return }
            self.attach(task, to: item)
            // A resumed download already knows where it goes; WebKit may not
            // ask again, so it counts as under way from here.
            if item.state == .starting { item.state = .running }
            self.tick()
        }
        tick()
        save()
    }

    /// From the beginning, to the same place.
    func restart(_ item: Download) {
        guard let url = item.source, let web = carrier(for: item) else {
            item.state = .failed("Nowhere left to download it from")
            return
        }
        if let task = item.task { task.cancel() }
        item.task = nil
        item.resumeData = nil
        forgetResumeFile(item)
        item.again = .restarting
        item.state = .starting
        item.received = 0
        item.finished = nil
        web.startDownload(using: URLRequest(url: url)) { [weak self, weak item] task in
            guard let self, let item else { return }
            self.attach(task, to: item)
            self.tick()
        }
        tick()
        save()
    }

    /// Stops it for good. What had arrived goes with it.
    func cancel(_ item: Download) {
        guard item.active || item.state == .paused || item.failed else { return }
        let task = item.task
        item.task = nil
        item.stopping = false
        item.state = .cancelled
        item.speed = 0
        item.resumeData = nil
        forgetResumeFile(item)
        let partial = item.file
        task?.cancel { _ in
            DispatchQueue.main.async { Downloads.discard(partial) }
        }
        if task == nil { Downloads.discard(partial) }
        tick()
        save()
        ended.send(item)
        mac.ended(item)
    }

    /// Off the list. The file, if it came, stays where it is.
    func remove(_ item: Download) {
        if item.active || item.state == .paused { cancel(item) }
        items.removeAll { $0.id == item.id }
        erased([item])
        tick()
        save()
    }

    private func erased(_ gone: [Download]) {
        for item in gone {
            told[item.id] = nil
            note("onErased", item.number)
        }
    }

    /// Everything not still coming in, off the list.
    func clear() {
        let going = items.filter { $0.active || $0.state == .paused }
        let ids = Set(going.map(\.id))
        let leaving = items.filter { !ids.contains($0.id) }
        leaving.forEach { forgetResumeFile($0) }
        items = going
        erased(leaving)
        tick()
        save()
    }

    /// The file into the Trash, and off the list.
    func trash(_ item: Download) {
        guard item.state == .done, let file = item.file, item.there else { return }
        NSWorkspace.shared.recycle([file]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.remove(item) }
        }
    }

    func open(_ item: Download) {
        guard let file = item.file, item.there else { return }
        NSWorkspace.shared.open(file)
    }

    func reveal(_ item: Download) {
        guard let file = item.file else { return }
        if item.there {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(file.deletingLastPathComponent())
        }
    }

    /// Something to download through: the page it came from while that is
    /// still here, the tab on screen, any page at all — or a view of its own.
    private func carrier(for item: Download) -> WKWebView? {
        if let web = item.web { return web }
        if let web = browser?.active?.built { return web }
        if let web = browser?.tabs.lazy.compactMap(\.built).first { return web }
        if let spare { return spare }
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        spare = web
        return web
    }

    // MARK: - the clock

    /// WebKit's progress read five times a second while anything is coming
    /// in, rather than every time it changes: a fast download changes it
    /// thousands of times a second, and nobody reads that fast.
    private func wind() {
        guard clock == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        var total: Int64 = 0
        var got: Int64 = 0
        var sized = true
        var going = 0
        for item in items where item.active {
            going += 1
            if let progress = item.task?.progress {
                // Forward only: a resumed download reports nothing for a
                // moment before it counts what it already had. Starting over
                // puts the count back to nothing itself.
                let bytes = progress.completedUnitCount
                if bytes > item.received { item.received = bytes }
                let size = progress.totalUnitCount
                if size > 0, size != item.expected { item.expected = size }
            }
            if item.state == .running { measure(item, now: now) }
            if item.expected > 0 {
                total += item.expected
                got += min(item.received, item.expected)
            } else {
                sized = false
            }
        }
        if count != going { count = going }
        let waiting = items.filter { $0.state == .paused }.count
        if held != waiting { held = waiting }
        let whole: Double? = going > 0 && sized && total > 0 ? Double(got) / Double(total) : nil
        if overall != whole { overall = whole }
        mac.sync(items, count: going)
        report()
        if going == 0 {
            clock?.invalidate()
            clock = nil
        }
    }

    /// The pace over the last three seconds, eased so the number doesn't
    /// jump about with every burst.
    private func measure(_ item: Download, now: TimeInterval) {
        item.samples.append((now, item.received))
        item.samples.removeAll { now - $0.time > 3 }
        guard let first = item.samples.first, now - first.time > 0.35 else { return }
        let pace = Double(item.received - first.bytes) / (now - first.time)
        let eased = item.speed == 0 ? pace : item.speed * 0.7 + pace * 0.3
        if abs(eased - item.speed) > 1 { item.speed = max(0, eased) }
    }

    // MARK: - what extensions hear

    /// Changes worth telling an extension (chrome.downloads' onCreated,
    /// onChanged, onErased), numbered, the last two hundred. Kept only once
    /// an extension has asked: nobody listening, nothing written down.
    private var journal: [(seq: Int, kind: String, body: Any)] = []
    private var seq = 0
    private var heard = false
    /// What each download last looked like to extensions, to say what changed.
    private var told: [UUID: [String: AnyHashable]] = [:]

    /// What happened after `cursor`, and where that leaves it. Asked with
    /// none, the answer is only where things stand: a listener hears what
    /// happens from now on.
    func changes(after cursor: Int?) -> [String: Any] {
        if !heard {
            heard = true
            for item in items { told[item.id] = fields(item) }
        }
        guard let cursor else { return ["cursor": seq, "changes": []] }
        let news = journal.filter { $0.seq > cursor }.map { ["kind": $0.kind, "body": $0.body] as [String: Any] }
        return ["cursor": seq, "changes": news]
    }

    private func note(_ kind: String, _ body: Any) {
        guard heard else { return }
        seq += 1
        journal.append((seq, kind, body))
        if journal.count > 200 { journal.removeFirst(journal.count - 200) }
    }

    /// What has changed about each download since extensions last heard,
    /// as Chrome's delta: each field's previous and current value.
    private func report() {
        guard heard else { return }
        for item in items {
            let now = fields(item)
            guard let was = told[item.id] else {
                told[item.id] = now
                continue
            }
            guard was != now else { continue }
            var delta: [String: Any] = ["id": item.number]
            for (key, value) in now where was[key] != value {
                var change: [String: Any] = ["current": value.base]
                if let old = was[key] { change["previous"] = old.base }
                delta[key] = change
            }
            told[item.id] = now
            note("onChanged", delta)
        }
    }

    /// The fields Chrome says have changed when they do.
    private func fields(_ item: Download) -> [String: AnyHashable] {
        let chrome = Downloads.chrome(item)
        var out: [String: AnyHashable] = [:]
        for key in ["state", "paused", "filename", "totalBytes", "error", "exists", "canResume", "endTime", "mime", "url", "finalUrl"] {
            if let value = chrome[key] as? AnyHashable { out[key] = value }
        }
        return out
    }

    /// A download as chrome.downloads describes one.
    static func chrome(_ item: Download) -> [String: Any] {
        let clock = ISO8601DateFormatter()
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [String: Any] = [
            "id": item.number,
            "url": item.source?.absoluteString ?? "",
            "finalUrl": item.source?.absoluteString ?? "",
            "referrer": item.page?.absoluteString ?? "",
            "filename": item.file?.path ?? "",
            "incognito": false,
            "danger": "safe",
            "mime": item.mime ?? "",
            "startTime": clock.string(from: item.started),
            "bytesReceived": item.received,
            "totalBytes": item.expected > 0 ? item.expected : -1,
            "fileSize": item.state == .done ? item.received : (item.expected > 0 ? item.expected : -1),
            "exists": item.state == .done ? item.there : true,
            "paused": item.state == .paused,
            "canResume": item.state == .paused || item.failed,
        ]
        switch item.state {
        case .starting, .running, .paused: out["state"] = "in_progress"
        case .done: out["state"] = "complete"
        case .failed, .cancelled: out["state"] = "interrupted"
        }
        if case .failed = item.state { out["error"] = "NETWORK_FAILED" }
        if item.state == .cancelled { out["error"] = "USER_CANCELED" }
        if let finished = item.finished { out["endTime"] = clock.string(from: finished) }
        if let left = item.remaining { out["estimatedEndTime"] = clock.string(from: Date().addingTimeInterval(left)) }
        return out
    }

    // MARK: - quitting

    /// Asked before Search quits: anything still coming in is said out loud
    /// first, then stopped where it is and written down, so it comes back
    /// paused next time.
    func shouldQuit() -> NSApplication.TerminateReply {
        let going = running
        guard !going.isEmpty else { return .terminateNow }
        guard mayQuit() else { return .terminateCancel }
        park(going) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    /// Whether to quit with downloads still coming in — asked once, and
    /// yes when there are none. Relaunching for an update asks here before
    /// anything is set in motion, so that no is simply no.
    func mayQuit() -> Bool {
        let going = running
        guard !going.isEmpty, !quitting else { return true }
        let alert = NSAlert()
        alert.messageText = going.count == 1
            ? "Quit with \u{201C}\(going[0].name)\u{201D} still downloading?"
            : "Quit with \(going.count) downloads still going?"
        alert.informativeText = "They stop where they are and can be picked up again the next time Search opens."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        quitting = true
        return true
    }

    /// ⌘Q without the question, for a test run. From the run loop rather
    /// than a queued block, as a menu's ⌘Q would be (see park).
    func quitWithoutAsking() {
        quitting = true
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    /// Stops each one, keeping what it needs to go on, and writes it all
    /// down — then says so. Three seconds at most: quitting doesn't wait on
    /// WebKit forever.
    ///
    /// Nothing here goes through the main queue. While AppKit waits to be
    /// told it may quit, it turns the run loop itself; a quit asked for from
    /// inside a queued block holds the queue for as long as that lasts, and
    /// anything sent to it — the answers, the three seconds — would never
    /// come. WebKit answers on the main thread, and the clock is the run
    /// loop's.
    private func park(_ going: [Download], done: @escaping () -> Void) {
        var waiting = going.count
        var finished = false
        let finish = { [weak self] in
            guard !finished else { return }
            finished = true
            self?.save(now: true)
            done()
        }
        for item in going {
            item.stopping = true
            item.state = .paused
            guard let task = item.task else {
                waiting -= 1
                continue
            }
            task.cancel { [weak self] data in
                let take = {
                    item.resumeData = data
                    item.task = nil
                    item.stopping = false
                    self?.writeResumeFile(item)
                    waiting -= 1
                    if waiting == 0 { finish() }
                }
                if Thread.isMainThread { MainActor.assumeIsolated(take) } else { DispatchQueue.main.async(execute: take) }
            }
        }
        if waiting == 0 { finish() }
        let limit = Timer(timeInterval: 3, repeats: false) { _ in MainActor.assumeIsolated(finish) }
        RunLoop.main.add(limit, forMode: .common)
        RunLoop.main.add(limit, forMode: .modalPanel)
    }

    // MARK: - keeping the list

    private static var file: URL { Store.file("downloads.json") }
    private static var resumeFolder: URL { Store.file("resume") }

    private static func resumeFile(for id: UUID) -> URL {
        resumeFolder.appendingPathComponent(id.uuidString)
    }

    private func writeResumeFile(_ item: Download) {
        guard let data = item.resumeData else { return }
        try? FileManager.default.createDirectory(at: Downloads.resumeFolder, withIntermediateDirectories: true)
        try? data.write(to: Downloads.resumeFile(for: item.id), options: .atomic)
    }

    private func forgetResumeFile(_ item: Download) {
        try? FileManager.default.removeItem(at: Downloads.resumeFile(for: item.id))
    }

    /// Half a file left behind by a download that won't finish.
    private static func discard(_ file: URL?) {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    private func trim() {
        guard items.count > Downloads.kept else { return }
        // Only what has ended goes; nothing still coming in is dropped.
        var extra = items.count - Downloads.kept
        for item in items.reversed() where extra > 0 && !item.active && item.state != .paused {
            forgetResumeFile(item)
            items.removeAll { $0.id == item.id }
            erased([item])
            extra -= 1
        }
    }

    private struct Record: Codable {
        var id: UUID
        var number: Int
        var name: String
        /// The site, as the old list kept it.
        var from: String
        /// Empty when there is no file.
        var path: String
        /// When it started.
        var date: Date
        var source: URL?
        var page: URL?
        var state: String
        var error: String?
        var received: Int64?
        var expected: Int64?
        var finished: Date?
        var mime: String?

        enum CodingKeys: String, CodingKey {
            case id, number, name, from, path, date, source, page, state, error, received, expected, finished, mime
        }

        @MainActor init(_ item: Download) {
            id = item.id
            number = item.number
            name = item.name
            from = item.host
            path = item.file?.path ?? ""
            date = item.started
            source = item.source
            page = item.page
            switch item.state {
            case .done: state = "done"
            case .failed(let why): state = "failed"; error = why
            case .cancelled: state = "cancelled"
            case .starting, .running, .paused: state = "paused"
            }
            received = item.received
            expected = item.expected
            finished = item.finished
            mime = item.mime
        }

        /// The old list's lines have a name, a site, a path and a date, and
        /// were all finished.
        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            name = try box.decode(String.self, forKey: .name)
            from = try box.decodeIfPresent(String.self, forKey: .from) ?? ""
            path = try box.decodeIfPresent(String.self, forKey: .path) ?? ""
            date = try box.decodeIfPresent(Date.self, forKey: .date) ?? Date()
            id = try box.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            number = try box.decodeIfPresent(Int.self, forKey: .number) ?? 0
            source = try box.decodeIfPresent(URL.self, forKey: .source)
            page = try box.decodeIfPresent(URL.self, forKey: .page)
            state = try box.decodeIfPresent(String.self, forKey: .state) ?? "done"
            error = try box.decodeIfPresent(String.self, forKey: .error)
            received = try box.decodeIfPresent(Int64.self, forKey: .received)
            expected = try box.decodeIfPresent(Int64.self, forKey: .expected)
            finished = try box.decodeIfPresent(Date.self, forKey: .finished)
            mime = try box.decodeIfPresent(String.self, forKey: .mime)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Downloads.file) else { return }
        guard let records = try? JSONDecoder().decode([Record].self, from: data) else {
            Store.quarantine(Downloads.file)
            return
        }
        numbered = records.map(\.number).max() ?? 0
        items = records.map { record in
            var number = record.number
            if number == 0 {
                numbered += 1
                number = numbered
            }
            let state: Download.State = switch record.state {
            case "failed": .failed(record.error ?? "Failed")
            case "cancelled": .cancelled
            case "paused": .paused
            default: .done
            }
            let item = Download(
                id: record.id, number: number, name: record.name,
                file: record.path.isEmpty ? nil : URL(fileURLWithPath: record.path),
                state: state, received: record.received ?? 0, expected: record.expected ?? -1,
                source: record.source, page: record.page, started: record.date,
                finished: record.finished ?? (state == .done ? record.date : nil)
            )
            item.mime = record.mime
            if state == .paused || item.failed {
                item.resumeData = try? Data(contentsOf: Downloads.resumeFile(for: record.id))
            }
            return item
        }
    }

    private func save(now: Bool = false) {
        let records = items.map(Record.init)
        let file = Downloads.file
        let write = {
            guard let data = try? JSONEncoder().encode(records) else { return }
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: file, options: .atomic)
        }
        if now { write() } else { DispatchQueue.global(qos: .utility).async(execute: write) }
    }
}

// MARK: - WebKit

extension Downloads: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let item = items.first { $0.task === download } ?? track(download)
        if response.expectedContentLength > 0 { item.expected = response.expectedContentLength }
        item.mime = response.mimeType

        // Taken up again: to where it was going. Resumed, the part that came
        // is what it goes on from; started over, it is thrown away first.
        let again = item.again
        item.again = nil
        if let again, let file = item.file {
            if again == .restarting { Downloads.discard(file) }
            item.state = .running
            completionHandler(file)
            tick()
            save()
            return
        }

        let asked = response.url.flatMap { browser?.namedDownloads.removeValue(forKey: $0) }
            ?? item.source.flatMap { browser?.namedDownloads.removeValue(forKey: $0) }
        let name = asked ?? (suggestedFilename.isEmpty ? "download" : suggestedFilename)
        let folder = browser?.downloadsFolder
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

        if browser?.prefs.asksWhereToSave == true {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.directoryURL = folder
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else {
                // Asked where, and told nowhere: not a download anybody wants
                // to see in a list.
                completionHandler(nil)
                items.removeAll { $0.id == item.id }
                tick()
                return
            }
            // The panel already asked about replacing what is there.
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
            arrive(item, at: url, completionHandler)
            return
        }
        arrive(item, at: free(name, in: folder), completionHandler)
    }

    private func arrive(_ item: Download, at file: URL, _ completionHandler: (URL?) -> Void) {
        item.name = file.lastPathComponent
        item.file = file
        item.state = .running
        completionHandler(file)
        tick()
        save()
        began.send(item)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = items.first(where: { $0.task === download }) else { return }
        item.task = nil
        item.state = .done
        item.finished = Date()
        item.speed = 0
        item.resumeData = nil
        forgetResumeFile(item)
        if let file = download.progress.fileURL ?? item.file {
            item.file = file
            item.name = file.lastPathComponent
            if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                item.received = Int64(size)
                item.expected = Int64(size)
            }
        }
        tick()
        save()
        ended.send(item)
        mac.ended(item)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = items.first(where: { $0.task === download }) else { return }
        // Paused or cancelled here: WebKit reporting the stop it was asked for.
        if item.stopping || item.state == .paused || item.state == .cancelled {
            if item.state == .paused, item.resumeData == nil { item.resumeData = resumeData }
            return
        }
        item.task = nil
        item.speed = 0
        item.resumeData = resumeData
        item.state = .failed(Downloads.reason(error))
        item.finished = Date()
        if resumeData == nil { Downloads.discard(item.file) }
        tick()
        save()
        ended.send(item)
        mac.ended(item)
    }

    /// Said the way a person would, rather than as an error domain.
    private static func reason(_ error: Error) -> String {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return "The connection was lost"
        case NSURLErrorTimedOut: return "The server stopped answering"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "Couldn't reach the server"
        case NSURLErrorBadServerResponse: return "The server sent something unexpected"
        case NSURLErrorCannotCreateFile, NSURLErrorCannotWriteToFile, NSURLErrorCannotOpenFile: return "Couldn't write the file"
        case NSURLErrorNoPermissionsToReadFile, NSURLErrorUserAuthenticationRequired: return "Not allowed"
        default: return error.localizedDescription
        }
    }

    /// WebKit refuses to write over a file that is already there, so the name
    /// gains a number rather than the download quietly failing — and one
    /// already promised to a download still coming in counts as taken.
    private func free(_ name: String, in folder: URL) -> URL {
        let taken = Set(items.filter { $0.active || $0.state == .paused }.compactMap { $0.file?.path })
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) || taken.contains(candidate.path) {
            let next = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }
}
