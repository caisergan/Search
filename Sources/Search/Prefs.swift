import Security
import SwiftUI

// Everything there is to set, in one observable place.
//
// Each of these is a line in the settings file and nothing more; the object
// exists so that a panel can bind to them and the rest of the window can
// redraw when one changes. Defaults are chosen so that a browser nobody has
// configured behaves the way it always did.

/// What a tab wears beside its title, and what a pinned one is reduced to: a
/// letter, or the site's own icon.
enum Glyph: String, CaseIterable, Identifiable {
    case letters, icons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .letters: return "Letters"
        case .icons: return "Site icons"
        }
    }
}

/// How long the pointer rests on the left edge before a column that hides
/// comes out: at once for a hand that knows where it is going, longer for
/// one that keeps crossing the edge on its way to the Dock.
enum Reveal: String, CaseIterable, Identifiable {
    case cheetah, human, turtle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cheetah: return "Cheetah"
        case .human: return "Human"
        case .turtle: return "Turtle"
        }
    }

    /// There is no cheetah among the system's symbols; the hare stands in.
    var icon: String {
        switch self {
        case .cheetah: return "hare"
        case .human: return "figure.walk"
        case .turtle: return "tortoise"
        }
    }

    var wait: TimeInterval {
        switch self {
        case .cheetah: return 0
        case .human: return 0.15
        case .turtle: return 0.4
        }
    }
}

/// Which tabs brought back from the last session load when Search opens,
/// after the one on screen, rather than waiting for a click. Each takes in
/// the ones before it: pinned is the Essentials and the pinned lines, all is
/// every tab in the row.
enum StartLoad: String, CaseIterable, Identifiable {
    case none, essentials, pinned, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .essentials: return "Essentials"
        case .pinned: return "Pinned"
        case .all: return "All"
        }
    }

    /// Whether a tab in this place is one of those loaded.
    func loads(_ place: Browser.Place) -> Bool {
        switch self {
        case .none: return false
        case .essentials: return place == .essential
        case .pinned: return place != .loose
        case .all: return true
        }
    }
}

/// How big a tab is drawn, in the column and in the row across the top.
/// Regular is the size tabs have always been; large is a step up for anyone
/// who finds that hard to read, with everything on the line grown to match.
enum TabSize: String, CaseIterable, Identifiable {
    case regular, large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .regular: return "Regular"
        case .large: return "Large"
        }
    }

    /// The title.
    var text: CGFloat { self == .large ? 14 : 12.5 }
    /// The site's mark beside it.
    var mark: CGFloat { self == .large ? 17 : 15 }
    /// A line in the column.
    var row: CGFloat { self == .large ? 34 : 28 }
    /// A pinned square in the column, at its tallest.
    var square: CGFloat { self == .large ? 40 : 34 }
    /// The cross that closes a tab, and the ring and the speaker that take
    /// its place at the end of the line.
    var cross: CGFloat { self == .large ? 18 : 15 }
    /// The cross's glyph inside that circle, and the speaker's.
    var glyph: CGFloat { cross * 8 / 15 }
    /// The ring that turns there while a page loads.
    var ring: CGFloat { cross * 10 / 15 }
    /// The address typed into a tab, the title's size, and the height of its
    /// line.
    var field: CGFloat { text + 3.5 }
    /// The air above and below a title in the row across the top.
    var inset: CGFloat { self == .large ? 8 : 6 }
    /// A tab in the row across the top, before too many make it give way,
    /// and a pinned square there. Wider with the title, so large doesn't
    /// just mean less of it.
    var width: CGFloat { self == .large ? 208 : Metrics.tabWidth }
    var pinWidth: CGFloat { self == .large ? 34 : Metrics.pinWidth }
}

/// Where the zoom level shows while it changes: at the bottom with everything
/// else that says one thing, unless asked for somewhere nearer where the eye
/// goes. Most browsers put it at the top right.
enum ZoomSpot: String, CaseIterable, Identifiable {
    case bottom, top, topLeft, topRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottom: return "Bottom middle"
        case .top: return "Top middle"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        }
    }

    /// Its corner of the page.
    var alignment: Alignment {
        switch self {
        case .bottom: return .bottom
        case .top: return .top
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    private let store = Store.settings

    /// A local socket a script can drive the browser through, in tabs of its
    /// own. Off unless asked for.
    @Published var bench: Bool {
        didSet { store.set(bench, forKey: "bench") }
    }
    /// Light, dark, or the Mac's own.
    @Published var look: Look {
        didSet {
            store.set(look.rawValue, forKey: "look")
            look.apply()
        }
    }
    /// What the window is made of around the page. Plain unless changed.
    @Published var theme: Theme {
        didSet { store.set(theme.rawValue, forKey: "theme") }
    }
    /// Titles down the left instead of across the top.
    @Published var sidebar: Bool {
        didSet { store.set(sidebar, forKey: "sidebar") }
    }
    /// The column folded away whenever the pointer isn't at the left edge,
    /// rather than only after ⌘S (see Fold.swift). Off unless asked for.
    @Published var sideHides: Bool {
        didSet { store.set(sideHides, forKey: "sidebar.hides") }
    }
    /// The tabs loaded when Search opens, rather than waiting for a click.
    /// Pinned unless changed.
    @Published var startLoad: StartLoad {
        didSet { store.set(startLoad.rawValue, forKey: "start.load") }
    }
    /// The tabs pinned as lines in the column, folded away under their
    /// heading.
    @Published var pinnedFolded: Bool {
        didSet { store.set(pinnedFolded, forKey: "sidebar.pinned.folded") }
    }
    /// How long the pointer rests on the edge before that column comes out.
    /// Human, as it always was, unless changed.
    @Published var sideReveal: Reveal {
        didSet { store.set(sideReveal.rawValue, forKey: "sidebar.reveal") }
    }
    /// New tab as a button at the foot of the column, in a place that stays
    /// put, rather than as the row under the last tab. Off unless asked for.
    @Published var newTabInFoot: Bool {
        didSet { store.set(newTabInFoot, forKey: "sidebar.newtab.foot") }
    }
    /// ⌘T raises the field over the page you're on instead of opening an
    /// empty tab; the tab is made when you go somewhere. Off unless asked for.
    @Published var newTabOver: Bool {
        didSet { store.set(newTabOver, forKey: "newtab.over") }
    }
    /// How wide the column is. Pulled by its edge, and remembered.
    @Published var sideWidth: CGFloat {
        didSet { store.set(Double(sideWidth), forKey: "sidebar.width") }
    }
    @Published var glyph: Glyph {
        didSet { store.set(glyph.rawValue, forKey: "glyph") }
    }
    /// Regular unless asked for bigger.
    @Published var tabSize: TabSize {
        didSet { store.set(tabSize.rawValue, forKey: "tabs.size") }
    }
    /// The bottom unless asked otherwise. Not under "zoom.", where each
    /// site's own zoom is kept by its host.
    @Published var zoomSpot: ZoomSpot {
        didSet { store.set(zoomSpot.rawValue, forKey: "zoomspot") }
    }
    @Published var engine: Engine {
        didSet { store.set(engine.rawValue, forKey: "search.engine") }
    }
    @Published var customEngine: String {
        didSet { store.set(customEngine, forKey: "search.custom") }
    }
    /// Tabs nobody has looked at for half an hour give their page back and
    /// keep where they were. On unless turned off.
    @Published var sleepsTabs: Bool {
        didSet { store.set(sleepsTabs, forKey: "tabs.sleep") }
    }
    @Published var showsReading: Bool {
        didSet { store.set(showsReading, forKey: "tabs.reading") }
    }
    /// The ad blocker. On unless turned off; there is nothing else to it.
    @Published var shielded: Bool {
        didSet { store.set(shielded, forKey: "shield") }
    }
    /// A private tab gets extensions too, not just every other page. Off
    /// unless asked for - a private tab keeps nothing by default, extensions
    /// included, and some watch what a page does.
    @Published var extensionsInPrivate: Bool {
        didSet { store.set(extensionsInPrivate, forKey: "extensions.private") }
    }
    /// Whether sites may ask for a passkey here. Off sends them to the
    /// password instead — the only thing that works in a build without
    /// Apple's browser entitlement.
    @Published var passkeys: Bool {
        didSet { store.set(passkeys, forKey: "passkeys") }
    }
    /// Whether this build can actually do them: signed with the entitlement,
    /// its profile embedded. Fixed for the life of the process.
    let passkeysPossible: Bool

    /// Asked of the running process's own signature, which is the only thing
    /// that decides it — a profile file in the bundle proves nothing on its
    /// own, and an ad-hoc build has neither.
    static var entitledToPasskeys: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil
        )
        return (value as? Bool) == true
    }
    @Published var downloads: URL {
        didSet { store.set(downloads.path, forKey: "downloads") }
    }
    @Published var asksWhereToSave: Bool {
        didSet { store.set(asksWhereToSave, forKey: "downloads.ask") }
    }
    /// Offer to keep a password the first time a site sees it.
    @Published var savesPasswords: Bool {
        didSet { store.set(savesPasswords, forKey: "passwords.save") }
    }
    /// Put a kept name and password into a sign-in as soon as one appears.
    @Published var fillsPasswords: Bool {
        didSet { store.set(fillsPasswords, forKey: "passwords.fill") }
    }
    /// The first launch has been walked through. Until then the welcome
    /// stands over the window.
    @Published var welcomed: Bool {
        didSet { store.set(welcomed, forKey: "welcomed") }
    }
    /// macOS's own autocorrect, inside web pages: the little "Not ×" that
    /// capitalises what you meant to leave lower-case. Off unless asked for.
    @Published var autocorrect: Bool {
        didSet {
            store.set(autocorrect, forKey: "autocorrect")
            Preferences.tellWebKit(autocorrect: autocorrect)
        }
    }

    /// A click of the wheel scrolls the page as on Windows (see AutoScroll.swift).
    /// Off unless asked for.
    @Published var autoScroll: Bool {
        didSet {
            store.set(autoScroll, forKey: "autoscroll")
            AutoScroll.on = autoScroll
        }
    }
    /// Two fingers flick the floating video to a corner (see Float.swift).
    /// Off unless asked for.
    @Published var floatFlicks: Bool {
        didSet {
            store.set(floatFlicks, forKey: "float.flicks")
            Float.flicks = floatFlicks
        }
    }
    /// A video playing floats out when another app comes to the front, and
    /// back when Search does (see Browser.appLeft). Off unless asked for.
    @Published var floatsAway: Bool {
        didSet { store.set(floatsAway, forKey: "float.away") }
    }
    /// A link clicked with a key held opens over the page rather than in a
    /// tab (see Glance.swift). Off unless asked for.
    @Published var glances: Bool {
        didSet { store.set(glances, forKey: "glance") }
    }
    /// Which key that is. ⌥ unless changed, as in Zen.
    @Published var glanceTrigger: GlanceTrigger {
        didSet { store.set(glanceTrigger.rawValue, forKey: "glance.trigger") }
    }
    /// Separate sets of tabs, each with its own sign-ins (see Spaces.swift).
    /// Off unless asked for.
    @Published var usesSpaces: Bool {
        didSet { store.set(usesSpaces, forKey: "spaces") }
    }

    init() {
        // Carried over from when there were four ways of holding the browser
        // and this was one of them.
        // The Mac's own unless asked otherwise — a Mac in dark mode expects
        // a dark browser, pages included.
        bench = store.bool(forKey: "bench")
        let chosen = store.string(forKey: "look").flatMap(Look.init) ?? .system
        look = chosen
        // Before the first window, and not deferred: the window that is about
        // to be made should be made in the right appearance. Through `shared`
        // rather than `NSApp`: on macOS 14 SwiftUI builds this before it has
        // made the application, and `NSApp` is still nil here.
        NSApplication.shared.appearance = chosen.appearance
        theme = store.string(forKey: "theme").flatMap(Theme.init) ?? .plain
        sidebar = store.object(forKey: "sidebar") as? Bool
            ?? (store.string(forKey: "manner") == "side")
        sideHides = store.bool(forKey: "sidebar.hides")
        pinnedFolded = store.bool(forKey: "sidebar.pinned.folded")
        // The switch this replaced: on was the Essentials and pinned lines.
        startLoad = store.string(forKey: "start.load").flatMap(StartLoad.init)
            ?? ((store.object(forKey: "pinned.load") as? Bool ?? true) ? .pinned : .none)
        sideReveal = store.string(forKey: "sidebar.reveal").flatMap(Reveal.init) ?? .human
        newTabInFoot = store.bool(forKey: "sidebar.newtab.foot")
        newTabOver = store.bool(forKey: "newtab.over")
        let width = store.object(forKey: "sidebar.width") as? Double ?? Double(Metrics.side)
        sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, CGFloat(width)))
        glyph = store.string(forKey: "glyph").flatMap(Glyph.init) ?? .letters
        tabSize = store.string(forKey: "tabs.size").flatMap(TabSize.init) ?? .regular
        zoomSpot = store.string(forKey: "zoomspot").flatMap(ZoomSpot.init) ?? .bottom
        engine = store.string(forKey: "search.engine").flatMap(Engine.init) ?? .standard
        customEngine = store.string(forKey: "search.custom") ?? ""
        sleepsTabs = store.object(forKey: "tabs.sleep") as? Bool ?? true
        showsReading = store.object(forKey: "tabs.reading") as? Bool ?? true
        shielded = store.object(forKey: "shield") as? Bool ?? true
        extensionsInPrivate = store.bool(forKey: "extensions.private")
        // Offered by default only in a build that can actually do them —
        // one with Apple's browser entitlement and its profile embedded. A
        // choice made while they couldn't work is not a choice about them:
        // the first run of a build that can offers them, whatever was set
        // before; from then on the switch is the person's.
        let entitled = Preferences.entitledToPasskeys
        passkeysPossible = entitled
        if entitled, !store.bool(forKey: "passkeys.entitled") {
            passkeys = true
            store.set(true, forKey: "passkeys")
        } else {
            passkeys = store.object(forKey: "passkeys") as? Bool ?? entitled
        }
        store.set(entitled, forKey: "passkeys.entitled")
        // A test run downloads into its own folder: ~/Downloads would have
        // macOS stop it to ask for access, with a dialog on the screen of
        // whoever is working beside it.
        let testDownloads = Store.folder.appendingPathComponent("Downloads", isDirectory: true)
        if Store.testing { try? FileManager.default.createDirectory(at: testDownloads, withIntermediateDirectories: true) }
        downloads = Store.testing
            ? testDownloads
            : (store.string(forKey: "downloads")).map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        asksWhereToSave = store.bool(forKey: "downloads.ask")
        savesPasswords = store.object(forKey: "passwords.save") as? Bool ?? true
        fillsPasswords = store.object(forKey: "passwords.fill") as? Bool ?? true
        // Anyone who already has a session was here before the welcome
        // existed; they are not asked to sit through it.
        welcomed = store.bool(forKey: "welcomed") || store.object(forKey: "glyph") != nil
        usesSpaces = store.bool(forKey: "spaces")
        glances = store.bool(forKey: "glance")
        glanceTrigger = store.string(forKey: "glance.trigger").flatMap(GlanceTrigger.init) ?? .option
        let flicks = store.bool(forKey: "float.flicks")
        floatFlicks = flicks
        Float.flicks = flicks
        floatsAway = store.bool(forKey: "float.away")
        let scrolls = store.bool(forKey: "autoscroll")
        autoScroll = scrolls
        AutoScroll.on = scrolls
        // Left behind by the Web Inspector's switch, from before it was
        // always there.
        store.removeObject(forKey: "inspector")
        let corrects = store.bool(forKey: "autocorrect")
        autocorrect = corrects
        // Before the first web view exists: WebKit reads these once.
        Preferences.tellWebKit(autocorrect: corrects)
        // Left behind by an assistant this browser no longer has.
        for key in ["mind.model", "mind.effort", "mind.acting", "mind.width", "mind.open"] {
            store.removeObject(forKey: key)
        }
    }

    /// WebKit's text checker takes its orders from the app's standard
    /// defaults — the real ones, not the test suite, because it is WebKit
    /// reading them and not us. Smart quotes and dashes go off outright: in a
    /// browser they are wrong in every code field and wanted in almost none.
    static func tellWebKit(autocorrect: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(autocorrect, forKey: "WebAutomaticSpellingCorrectionEnabled")
        defaults.set(false, forKey: "WebAutomaticQuoteSubstitutionEnabled")
        defaults.set(false, forKey: "WebAutomaticDashSubstitutionEnabled")
    }
}
