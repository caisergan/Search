import AppKit
import SwiftUI

/// Beside back, forward and reload: the tabs you closed, newest first, to
/// bring one back — the same ones as History › Recently Closed. A door like
/// its neighbours, so it is their size and lit the way they are, with its
/// dots stood on end; greyed while there is nothing to bring back, as back
/// is with nowhere to go. The list hangs from it, as the downloads' does.
struct GhostDoor: View {
    @ObservedObject var browser: Browser
    @State private var open = false

    var body: some View {
        let any = !browser.ghosts.isEmpty
        Door(icon: "ellipsis", on: open, turned: true, help: "Recently Closed") { open.toggle() }
            .disabled(!any)
            .opacity(any ? 1 : 0.3)
            .animation(Motion.quick, value: any)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                GhostList(browser: browser) { open = false }
            }
    }
}

/// The closed tabs as lines: the site's icon, the title, where it was and
/// when it went. A click on one brings it back where it was in the row.
struct GhostList: View {
    @ObservedObject var browser: Browser
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recently Closed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                if browser.ghosts.count > 1 {
                    Pill("Reopen all") {
                        done()
                        browser.reopenAll()
                    }
                    .help("Every tab here, back where it was")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 2)

            if browser.ghosts.isEmpty {
                Text("No tabs closed yet.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            } else {
                VStack(spacing: 1) {
                    ForEach(browser.ghosts.reversed()) { ghost in
                        GhostRow(ghost: ghost, first: ghost == browser.ghosts.last) {
                            done()
                            browser.reopen(ghost)
                        }
                    }
                }
                .padding(6)
            }

            Divider().overlay(Palette.hairline)
            Foot(symbol: "clock.arrow.circlepath", title: "Show All History", keys: Shortcuts.shared.keys(.history)?.label ?? "") {
                done()
                browser.recalling = true
            }
            .padding(6)
        }
        .frame(width: 320)
        .background(Palette.ground)
    }

    private struct Foot: View {
        let symbol: String
        let title: String
        var keys = ""
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 14)
                Text(title).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                if !keys.isEmpty {
                    Text(keys).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
        }
    }
}

/// One closed tab. Under the pointer the time gives way to the arrow that
/// says what a click does; the newest carries the key that brings it (⇧⌘T,
/// unless Settings › Shortcuts says otherwise).
private struct GhostRow: View {
    let ghost: Browser.Ghost
    let first: Bool
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(ghost.label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Address.pretty(ghost.url))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            ZStack(alignment: .trailing) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Palette.ink.opacity(0.7))
                    .opacity(hovering ? 1 : 0)
                Text(aside)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Palette.muted)
                    .opacity(hovering ? 0 : 1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.wash : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: act)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help(ghost.url.absoluteString)
    }

    /// The shortcut on the newest; how long ago on the rest, when it is
    /// known — a tab left behind at launch has no time of its own.
    private var aside: String {
        if first, let keys = Shortcuts.shared.keys(.reopenTab) { return keys.label }
        guard let closed = ghost.closed else { return "" }
        let seconds = Date().timeIntervalSince(closed)
        if seconds < 60 { return "now" }
        return Self.ago.localizedString(for: closed, relativeTo: Date())
    }

    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    @ViewBuilder private var icon: some View {
        if let host = ghost.url.host()?.lowercased(), let cached = Favicons.shared.cached(host) {
            Image(nsImage: cached)
                .resizable()
                .interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
        }
    }
}

/// The list drawn off screen, for a test run's picture of it.
@MainActor func ghostListPicture(_ browser: Browser) -> NSBitmapImageRep? {
    let host = NSHostingView(rootView: GhostList(browser: browser) {})
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSApp.effectiveAppearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: picture)
    return picture
}
