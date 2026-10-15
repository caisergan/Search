import AppKit
import WebKit

// Tabs you aren't using, put to sleep.
//
// A page open in a tab keeps its whole content process — a hundred to three
// hundred megabytes, running its timers, holding its sockets — for as long as
// the tab exists. Twenty tabs is two or three gigabytes spent on the nineteen
// nobody is looking at. So a tab left alone for a while — half an hour to
// four hours, by how much memory the Mac has — gives its page
// back, and keeps what it takes to come back exactly where it was: its
// history, its scroll position, and a picture to show while the page is
// rebuilt underneath (see Tab.sleep).
//
// Some tabs never sleep, because waking them couldn't give back what they
// were doing: the one on screen, pinned tabs (those are put down by hand,
// with ⌘W), a tab playing sound, on a call, sending a download, holding its
// video out in the little window, or holding something typed and not sent.
//
// When macOS says memory is short, the wait shrinks: to five minutes on a
// warning, to nothing when it is critical.
//
// A page grown past WebKit's own strict line — 1.5 GB — sleeps after five
// minutes away, pinned or not. WebKit is taking such a page apart every 30
// seconds anyway, throwing away its decoded pictures and compiled scripts,
// and the rest of it sits in swap. On a 16 GB MacBook Pro on 15 Oct 2026,
// one tab of 37 videos had grown to 2.4 GB in three days and three more
// past 1 GB, 4 GB was swapped out, and macOS said memory was short every
// few minutes. Each time, WebKit emptied every tab the same way, the one
// being scrolled included, and scrolling it stuttered until the page had
// rebuilt what was thrown away.

extension Browser {
    /// How long a tab has to go without being looked at, or `sleep.after`
    /// in seconds — for the bench and the measurements. Half an hour with
    /// 8 GB, two hours with 16, four with more: a tab put to sleep is loaded
    /// and drawn again from nothing when you come back to it, and a Mac with
    /// room to spare has no reason to make you wait for that. When memory
    /// does run short, macOS says so, and the wait shrinks as before.
    static var sleepAfter: TimeInterval {
        let set = Store.settings.double(forKey: "sleep.after")
        if set > 0 { return set }
        let gigabytes = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return gigabytes > 24 ? 4 * 3600 : gigabytes > 12 ? 2 * 3600 : 30 * 60
    }

    /// WebKit's strict line: half of the lesser of 3 GB and the Mac's
    /// memory (WTF's MemoryPressureHandler). A page past it has everything
    /// it can rebuild thrown away every 30 seconds. Or `sleep.heavy`, in
    /// megabytes — for the bench.
    static var heavyLine: UInt64 {
        let set = Store.settings.double(forKey: "sleep.heavy")
        if set > 0 { return UInt64(set * 1_048_576) }
        return min(3 << 30, ProcessInfo.processInfo.physicalMemory) / 2
    }

    /// How long a page past that line goes without being looked at before
    /// it sleeps: five minutes, as on macOS's warning. Or `sleep.heavy.after`
    /// in seconds.
    static var heavyAfter: TimeInterval {
        let set = Store.settings.double(forKey: "sleep.heavy.after")
        return set > 0 ? set : 5 * 60
    }

    /// What the tab's page costs this Mac, in bytes: its content process's
    /// footprint, the figure WebKit itself goes by and Activity Monitor calls
    /// memory — swapped out and compressed included, which resident size
    /// leaves out. Nil without a page. A process can hold more than one tab
    /// (one opened by another shares its process); each is given the whole.
    func footprint(of tab: Tab) -> UInt64? {
        guard let web = tab.built else { return nil }
        let get = NSSelectorFromString("_webProcessIdentifier")
        guard web.responds(to: get) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
        let pid = unsafeBitCast(web.method(for: get), to: Getter.self)(web, get)
        guard pid > 0 else { return nil }
        var info = rusage_info_v4()
        let read = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return read == 0 ? info.ri_phys_footprint : nil
    }

    /// Started once, at launch.
    func watchForSleep() {
        let every = min(60, max(5, Browser.sleepAfter / 4))
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleepIdle() }
        }
        timer.tolerance = every / 4
        RunLoop.main.add(timer, forMode: .common)
        dozing = timer

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.pressure?.data else { return }
                self.sleepIdle(within: event.contains(.critical) ? 0 : 5 * 60)
            }
        }
        source.resume()
        pressure = source
    }

    /// Every tab that has gone long enough without being looked at, the one
    /// left longest first.
    func sleepIdle(within given: TimeInterval? = nil) {
        guard prefs.sleepsTabs else { return }
        let wait = given ?? Browser.sleepAfter
        let heavyWait = min(wait, Browser.heavyAfter)
        let now = Date()
        // The rows of the other spaces too: parked is not the same as used.
        let all = tabs + parkedTabs
        let idle = all.filter { now.timeIntervalSince($0.touched) >= wait && awake(because: $0) == nil }
        let asleep = Set(idle.map(\.id))
        let heavy = all.filter {
            !asleep.contains($0.id) && now.timeIntervalSince($0.touched) >= heavyWait
                && awake(because: $0, heavy: true) == nil
                && (footprint(of: $0) ?? 0) >= Browser.heavyLine
        }
        let heavyIDs = Set(heavy.map(\.id))
        for tab in (idle + heavy).sorted(by: { $0.touched < $1.touched }) {
            self.sleep(tab, heavy: heavyIDs.contains(tab.id))
        }
    }

    /// Why a tab has to stay awake — nil when nothing keeps it. The clock is
    /// the caller's business; this is everything else. A heavy one — past
    /// `heavyLine` — isn't kept for being pinned.
    func awake(because tab: Tab, heavy: Bool = false) -> String? {
        if tab.id == activeID { return "on screen" }
        // Essentials and pinned lines alike: pale is how a pinned line says
        // it was put down, and it isn't one you put down. Unless WebKit is
        // already taking it apart every half minute (see heavyLine).
        if tab.place != .loose, !heavy { return "pinned" }
        if tab.bench { return "a bench tab" }
        if tab.isBlank { return "blank" }
        if tab.asleep { return "already asleep" }
        guard let web = tab.built else { return "no page" }
        if tab.loading { return "still loading" }
        if tab.noisy { return "playing sound" }
        if tab.floating || floating == tab.id { return "its video is out" }
        if web.cameraCaptureState != .none || web.microphoneCaptureState != .none { return "on a call" }
        if Downloads.shared.running.contains(where: { $0.task?.webView === web }) { return "downloading" }
        // A sign-in window hands its answer back to the page that opened it.
        if active?.opener == tab.id { return "the page on screen came from it" }
        return nil
    }

    /// Asks the page whether it holds anything typed, pictures it, then lets
    /// it go — looking again at each step, since each takes a moment and you
    /// may have gone back to the tab in the meantime.
    func sleep(_ tab: Tab, heavy: Bool = false, done: ((String) -> Void)? = nil) {
        if let reason = awake(because: tab, heavy: heavy) {
            done?(reason)
            return
        }
        tab.unsaved { [weak self, weak tab] typed in
            guard let self, let tab else { return }
            if typed {
                done?("holding something typed")
                return
            }
            if let reason = self.awake(because: tab, heavy: heavy) {
                done?(reason)
                return
            }
            tab.snapshot { [weak self, weak tab] picture in
                guard let self, let tab else { return }
                if let reason = self.awake(because: tab, heavy: heavy) {
                    done?(reason)
                    return
                }
                tab.sleep(picture: picture)
                done?("asleep")
            }
        }
    }
}
