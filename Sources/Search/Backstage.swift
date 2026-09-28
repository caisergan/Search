import AppKit

// Where a page waits while its tab isn't the one on screen.
//
// WebKit lays out a page only when its view has a size and a window. The
// stage holds just the tab you are looking at, so every other page used to be
// taken out of every window: a zero-sized page, left half-built. A tab opened
// in the background — a link with ⌘, or an extension's tabs.create — never
// drew at all, and an extension working in one found nothing to work on until
// the tab was picked. Chrome keeps its background tabs laid out at the
// window's size; here they wait in one window far off every screen, at the
// stage's size, until the stage takes them back.
//
// Off screen counts as covered, so a page here is hidden to itself and WebKit
// throttles it as it does any covered window. Sleep and close still end it:
// throwing a view away takes it out of this window too (see Tab.discard).
@MainActor
enum Backstage {
    private static var room: NSWindow?
    /// The stage's size, last it was laid out.
    private static var size = NSSize(width: 1280, height: 800)
    /// The same, for a room of Claude's that was given no size of its own.
    static var stageSize: NSSize { size }

    /// The window, made the first time a page needs it.
    static var window: NSWindow {
        if let room { return room }
        let window = makeRoom(size: size)
        room = window
        return window
    }

    /// Every window made here, this one and the bench's rooms.
    private static let rooms = NSHashTable<NSWindow>.weakObjects()

    /// A window far off every screen, for pages: this one, and the rooms the
    /// bench gives tabs Claude sized (see Bench.house).
    static func makeRoom(size: NSSize) -> Room {
        // Never key or main: it exists so that a web view has a window, and
        // for nothing else — unless Claude is working in it (see Room).
        let window = Room(
            contentRect: NSRect(origin: Room.away, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        // In every Space at once and moved by none, as the desktop is. It was
        // transient — which floats a window along with the app from Space to
        // Space — and stationary as well, of which AppKit takes one: full
        // screen took the rooms into the window's own Space and set them down
        // across the top of the screen, and there they stayed once it was
        // over, a strip of page along the top of the desktop. Never a tile
        // either, nor full screen itself.
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone, .fullScreenDisallowsTiling]
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.hasShadow = false
        window.orderBack(nil)
        rooms.add(window)
        return window
    }

    /// A page with nowhere else to be, laid out at the stage's size. A page
    /// that is already in a window — the stage, the float, a little window —
    /// is left where it is.
    static func park(_ page: NSView) {
        guard page.window == nil else { return }
        let content = window.contentView
        page.frame = content?.bounds ?? NSRect(origin: .zero, size: size)
        page.autoresizingMask = [.width, .height]
        content?.addSubview(page)
    }

    /// Waiting here, rather than on screen somewhere.
    static func holds(_ page: NSView) -> Bool {
        guard let room else { return false }
        return page.window === room
    }

    /// In a window off every screen: this one or one of the bench's rooms.
    static func offstage(_ page: NSView) -> Bool {
        guard let window = page.window else { return false }
        return rooms.contains(window)
    }

    /// Keeps waiting pages the size the stage would show them at, so the one
    /// picked next doesn't reflow as it comes back.
    static func match(_ stage: NSSize) {
        guard stage.width > 0, stage.height > 0, stage != size else { return }
        size = stage
        room?.setContentSize(stage)
    }
}

/// A window off every screen that can say it is the key window: WebKit takes
/// a page in a window that isn't key for one nobody is using — it has no
/// focus, and a pointer moving over it sets no hover, so a menu that opens
/// under the pointer never opens. While Claude works in a page, its room says
/// it is key, and the page behaves as the one in front of you does (see
/// Agent.engage). Only what asks the window itself hears it: AppKit's key
/// window, where your keys go, is still yours.
///
/// It stays off every screen whatever moves it. Nothing here does; AppKit and
/// macOS have, and a room on a screen is a strip of some page across the top
/// of the desktop that takes clicks meant for what is under it.
final class Room: NSWindow {
    /// Where every room is: far off every screen.
    static let away = NSPoint(x: -20000, y: -20000)

    var claimsKey = false
    override var isKeyWindow: Bool { claimsKey || super.isKeyWindow }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSWindow.didMoveNotification, object: self)
    }

    /// Straight back off the screen it was put on — by AppKit, or by macOS
    /// making room for it in a Space.
    @objc private func moved() {
        guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return }
        setFrameOrigin(Room.away)
    }

    /// AppKit keeps a window on a screen when it can; a room belongs on none.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
