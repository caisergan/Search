import SwiftUI

// Glance, as in Zen: a link clicked with a key held opens over the page it
// came from, in a card, instead of in a tab. A look at where it goes, and
// back — esc, a click beside the card, or its cross puts it away, and the
// page underneath never moved. The arrow keeps it, as a tab under the one it
// was taken from.
//
// The card holds a real tab that simply isn't in the row yet, so keeping it
// is putting it there: no reload, nothing lost.

/// The keys held with the click: any of ⌥, ⇧ and ⌘ together, set in
/// Settings › Tabs › Glance with. ⇧⌘ unless changed — ⌘ alone opens a tab,
/// ⇧ alone may peek, ⌥ alone is Safari's download. ⌃ can't be one: with
/// it, a click is a right-click. The middle button always opens a tab.
struct GlanceTrigger: Equatable {
    /// Some of ⌥, ⇧ and ⌘, never none.
    let flags: NSEvent.ModifierFlags

    static let usable: NSEvent.ModifierFlags = [.option, .shift, .command]
    static let standard = GlanceTrigger(checked: [.shift, .command])

    private init(checked flags: NSEvent.ModifierFlags) { self.flags = flags }

    /// Nil for no keys at all, or only ⌃.
    init?(flags: NSEvent.ModifierFlags) {
        let kept = flags.intersection(GlanceTrigger.usable)
        guard !kept.isEmpty else { return nil }
        self.flags = kept
    }

    /// "command+shift". The old single names — option, shift, command —
    /// read as they always did.
    init?(rawValue: String) {
        var flags: NSEvent.ModifierFlags = []
        for name in rawValue.split(separator: "+") {
            switch name {
            case "option": flags.insert(.option)
            case "shift": flags.insert(.shift)
            case "command": flags.insert(.command)
            default: return nil
            }
        }
        self.init(flags: flags)
    }

    var rawValue: String {
        [(NSEvent.ModifierFlags.option, "option"), (.shift, "shift"), (.command, "command")]
            .filter { flags.contains($0.0) }.map(\.1).joined(separator: "+")
    }

    /// In the order macOS writes them: ⌥⇧⌘.
    var key: String { GlanceTrigger.symbols(flags) }

    var title: String { "\(key) Click" }

    static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text
    }
}

/// The glance's keys, in a well: clicked, it listens; clicked again with
/// the keys held, it keeps them. What is held shows as it is pressed, esc
/// keeps the keys it had, and a click that can't be a glance says why.
struct GlanceKeysWell: View {
    @Binding var trigger: GlanceTrigger
    /// ⌘ alone is the tab's while ⌘-click goes to it.
    let commandTaken: Bool
    let say: (String) -> Void

    @State private var listening = false
    @State private var held: NSEvent.ModifierFlags = []
    @State private var monitor: Any?
    @State private var hovering = false

    private static let watched: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    var body: some View {
        Button(action: pressed) {
            Text(label)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Palette.ink)
                .frame(minWidth: 96)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(listening ? Palette.ground : (hovering ? Palette.faint.opacity(0.6) : Palette.wash))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(listening ? Palette.ink : .clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(listening ? "Hold the keys and click here   esc keeps \(trigger.title)" : "Click, then hold the keys and click again")
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: listening)
        .onDisappear { stop() }
    }

    private var label: String {
        guard listening else { return trigger.title }
        let keys = GlanceTrigger.symbols(held)
        return keys.isEmpty ? "Hold keys, click" : "\(keys) Click"
    }

    private func pressed() {
        guard listening else {
            start()
            return
        }
        let flags = (NSApp.currentEvent?.modifierFlags ?? []).intersection(GlanceKeysWell.watched)
        if flags.contains(.control) {
            say("⌃-click is a right-click — hold ⌥, ⇧ or ⌘")
            return
        }
        guard let chosen = GlanceTrigger(flags: flags) else {
            say("Hold ⌥, ⇧ or ⌘ as you click — esc keeps \(trigger.title)")
            return
        }
        if commandTaken, chosen.flags == .command {
            say("⌘-click goes to the tab — hold another key with it")
            return
        }
        trigger = chosen
        stop()
    }

    private func start() {
        listening = true
        held = NSEvent.modifierFlags.intersection(GlanceKeysWell.watched)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if event.type == .keyDown, event.keyCode == 53 {
                stop()
                return nil
            }
            if event.type == .flagsChanged { held = event.modifierFlags.intersection(GlanceKeysWell.watched) }
            return event
        }
    }

    private func stop() {
        listening = false
        held = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
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
