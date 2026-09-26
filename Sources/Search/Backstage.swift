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
    static func makeRoom(size: NSSize) -> NSWindow {
        // Never key or main: it exists so that a web view has a window, and
        // for nothing else.
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
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
