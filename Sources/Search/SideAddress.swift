import SwiftUI

// The address at the head of the column, as in Zen: the page's site, quiet,
// under the lights, and the field unfurling from it when it is clicked or
// ⌘L is pressed. The field is the one the middle of the page has — the same
// list, the same keys, the same Return — only it opens where the address
// already was, so what you are changing stays where you were looking at it.
//
// A new tab's field, and ⌘K's switcher, still stand in the middle: neither
// is this page's address.

/// The page's address, in the column, under the lights.
struct SideAddress: View {
    @ObservedObject var browser: Browser

    static let height: CGFloat = 34
    /// The space the pill is measured in and the field placed in: the whole
    /// window, the column folded out over the page as much as the one beside it.
    static let space = "window"
    /// Where the pill is, for the field to unfurl from. Kept in a box rather
    /// than in state: it moves with every frame of the column sliding out,
    /// and nothing needs redrawing for that.
    @MainActor static var spot = CGRect(x: 10, y: Metrics.strip, width: Metrics.side - 20, height: height)

    var body: some View {
        Group {
            if let tab = browser.active {
                Watch(browser: browser, tab: tab)
            } else {
                Face(browser: browser, address: nil)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SideAddress.space)) } action: {
            SideAddress.spot = $0
        }
    }

    /// Its address changes as the page goes elsewhere, so the tab is
    /// watched, not just read.
    private struct Watch: View {
        let browser: Browser
        @ObservedObject var tab: Tab

        var body: some View {
            Face(browser: browser, address: tab.isBlank ? nil : tab.address)
        }
    }

    private struct Face: View {
        @ObservedObject var browser: Browser
        /// Nil for a tab with nowhere to be yet.
        let address: URL?

        @State private var hovering = false

        private var blank: Bool { address == nil }

        var body: some View {
            HStack(spacing: 4) {
                Text(blank ? "Enter a web address" : SideAddress.short(address))
                    .font(.system(size: 13))
                    .foregroundStyle(blank ? Palette.faint : (hovering ? Palette.ink : Palette.ink.opacity(0.75)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                // Quiet until the pointer is on it, as a tab's cross is.
                if hovering, !blank {
                    Door(icon: "link", help: "Copy Address   ⌘⇧C") { browser.copyAddress() }
                        .transition(.opacity)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: SideAddress.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? Palette.wash : Palette.hover)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture { open() }
            .onHover { hovering = $0 }
            .help(blank ? "" : address?.absoluteString ?? "")
            // The field has taken its place, and grows out from where it was.
            .opacity(browser.fieldInColumn ? 0 : 1)
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: browser.fieldInColumn)
        }

        /// A blank tab's field is already up in the middle of the page, with
        /// the cursor in it: the click only puts the cursor back.
        private func open() {
            if blank { browser.askFocus() } else { browser.edit() }
        }
    }

    /// The site, as the eye reads it: the host without its www, or the whole
    /// address where there is no host to speak of — a file, an about: page.
    static func short(_ url: URL?) -> String {
        guard let url else { return "" }
        guard let host = url.host(), !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// The address field, unfurled from the address in the column: its text
/// lands where the address's was, and the card grows out from the pill,
/// over the page, to the field's own width.
struct ColumnField: View {
    @ObservedObject var browser: Browser

    @State private var open = false
    @State private var shake: CGFloat = 0
    @State private var refused = false

    var body: some View {
        GeometryReader { proxy in
            let spot = SideAddress.spot
            let here = proxy.frame(in: .named(SideAddress.space)).origin
            // Four to the left and eight above the pill, so with the field's
            // own air the text sits exactly where the address did.
            let x = spot.minX - 4
            let y = spot.minY - 8
            let width = max(spot.width + 8, min(Metrics.fieldWidth, proxy.size.width + here.x - x - 16))
            card(width: width, from: CGSize(width: spot.width + 8, height: spot.height + 16))
                .offset(x: x - here.x, y: y - here.y)
        }
        .onAppear { withAnimation(Motion.settle) { open = true } }
    }

    private func card(width: CGFloat, from pill: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AddressField(browser: browser)
                .frame(height: 22)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            if !browser.offers.isEmpty {
                Rectangle()
                    .fill(Palette.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, 12)
                list
                    .transition(.opacity)
            }
        }
        .frame(width: width, alignment: .topLeading)
        // Closed, the card is the pill's size and shows only what fits in
        // it; opening, it grows to the right and down to hold the rest.
        .frame(width: open ? width : pill.width, height: open ? nil : pill.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(refused ? Color.red.opacity(0.35) : Palette.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
        .modifier(Shake(travel: shake))
        .onChange(of: browser.refusals) { _, _ in
            shake = 0
            refused = true
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        .onChange(of: browser.typed) { _, _ in
            withAnimation(Motion.quick) { refused = false }
        }
        .animation(Motion.settle, value: browser.offers)
        .animation(Motion.settle, value: refused)
    }

    /// The same rows as the field in the middle of the page, under a line
    /// rather than in a card of their own.
    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(browser.offers.enumerated()), id: \.element.id) { index, offer in
                Omnibox.Row(offer: offer, picked: browser.picked == index, rich: browser.prefs.newTabOver)
                    .contentShape(Rectangle())
                    .onTapGesture { browser.take(offer) }
            }
        }
        .padding(6)
    }
}
