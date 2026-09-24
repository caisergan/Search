import SwiftUI

// Glance, as in Zen: a link clicked with a key held opens over the page it
// came from, in a card, instead of in a tab. A look at where it goes, and
// back — esc, a click beside the card, or its cross puts it away, and the
// page underneath never moved. The arrow keeps it, as a tab under the one it
// was taken from.
//
// The card holds a real tab that simply isn't in the row yet, so keeping it
// is putting it there: no reload, nothing lost.

/// The key held with the click. ⌥ as in Zen; ⇧ for a hand that finds it
/// easier; ⌘ for anyone who would rather glance than open in the background
/// (⌘⇧ and the middle button still open a tab).
enum GlanceTrigger: String, CaseIterable, Identifiable {
    case option, shift, command

    var id: String { rawValue }

    var key: String {
        switch self {
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }

    var title: String { "\(key) Click" }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .option: return .option
        case .shift: return .shift
        case .command: return .command
        }
    }
}

/// The page being glanced at, and the tab it was taken from.
struct Glance: Equatable {
    let tab: Tab
    let from: Tab.ID

    static func == (a: Glance, b: Glance) -> Bool { a.tab.id == b.tab.id }
}

/// Over the page: the page dimmed, the card, and its buttons beside it.
struct GlanceLayer: View {
    @ObservedObject var browser: Browser
    let glance: Glance

    private static let corner: CGFloat = 12

    var body: some View {
        ZStack {
            // The page it came from, still there underneath. A click on it
            // is a click back to it.
            Color.black.opacity(0.32)
                .contentShape(Rectangle())
                .onTapGesture { browser.closeGlance() }
                .transition(.opacity)

            Page(tab: glance.tab, corner: GlanceLayer.corner)
                .clipShape(RoundedRectangle(cornerRadius: GlanceLayer.corner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: GlanceLayer.corner, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .background(
                    RoundedRectangle(cornerRadius: GlanceLayer.corner, style: .continuous)
                        .fill(Palette.ground)
                        .shadow(color: .black.opacity(0.28), radius: 30, y: 10)
                )
                .padding(.vertical, 22)
                .padding(.horizontal, 58)
                .transition(.opacity)
        }
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 8) {
                Knob(icon: "xmark", help: "Close   esc") { browser.closeGlance() }
                Knob(icon: "arrow.up.left.and.arrow.down.right", help: "Open in a tab") { browser.expandGlance() }
                Knob(icon: "link", help: "Copy address") { copy() }
            }
            .padding(.top, 22)
            .padding(.trailing, 13)
            .transition(.opacity)
        }
        .onAppear {
            // The keyboard to the glance, so it scrolls and types at once.
            DispatchQueue.main.async {
                let web = glance.tab.web
                web.window?.makeFirstResponder(web)
            }
        }
    }

    private func copy() {
        guard let url = glance.tab.address else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        browser.announce("Copied")
    }

    /// A round button beside the card, standing on the dimmed page.
    private struct Knob: View {
        let icon: String
        let help: String
        let act: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink.opacity(hovering ? 1 : 0.75))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Palette.ground))
                    .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                    .scaleEffect(hovering ? 1.06 : 1)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
            .animation(Motion.quick, value: hovering)
        }
    }
}
