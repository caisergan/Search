import SwiftUI
import WebKit

/// Settings › Shortcuts: every key Search answers to, and a way to change
/// each. A click on a key listens for the next one; esc lets it be, ⌫ leaves
/// the command with none. A key another command had moves here, and the
/// page says which.
struct ShortcutsPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var shortcuts = Shortcuts.shared

    @State private var hunt = ""
    @FocusState private var hunting: Bool
    /// What is listening for a key, if anything.
    @State private var listening: Target?

    enum Target: Hashable {
        case ours(Command)
        /// An extension's command, by the extension and the command's id.
        case theirs(String, String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Hunt(text: $hunt, prompt: "Search shortcuts", focus: $hunting)
                if shortcuts.anyChanged {
                    Pill("Put all back") {
                        listening = nil
                        shortcuts.resetAll()
                    }
                }
            }

            ForEach(Command.Group.allCases) { group in
                let commands = Command.allCases.filter { $0.group == group && matches($0.title, shortcuts.keys($0)?.label) }
                if !commands.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Caption(group.title)
                        Card {
                            ForEach(Array(commands.enumerated()), id: \.element) { index, command in
                                if index > 0 { Rule() }
                                row(command)
                            }
                        }
                    }
                }
            }

            if #available(macOS 15.4, *) {
                ExtensionCommands(extensions: .shared, hunt: hunt, listening: $listening, listen: listen)
            }

            let fixed = FixedKeys.all.filter { matches($0.does, $0.keys) }
            if !fixed.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Caption("Always")
                    Card {
                        ForEach(Array(fixed.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Rule() }
                            Line(item.does) {
                                Text(item.keys)
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundStyle(Palette.muted)
                            }
                        }
                    }
                }
            }
        }
        .onDisappear { stop() }
        .onChange(of: listening) { _, target in
            if target == nil { stop() }
        }
    }

    private func matches(_ title: String, _ keys: String?) -> Bool {
        let hunt = hunt.trimmingCharacters(in: .whitespaces)
        guard !hunt.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(hunt) || (keys?.localizedCaseInsensitiveContains(hunt) ?? false)
    }

    private func row(_ command: Command) -> some View {
        let changed = shortcuts.isChanged(command)
        return Line(command.title, changed ? "Out of the box: \(command.standard.label)" : nil) {
            HStack(spacing: 6) {
                if changed {
                    Quick("Reset") {
                        listening = nil
                        shortcuts.reset(command)
                    }
                }
                Recorder(keys: shortcuts.keys(command), listening: listening == .ours(command)) {
                    listen(.ours(command))
                }
            }
        }
    }

    // MARK: - listening

    /// Starts listening for a target's key, or stops if it already was.
    private func listen(_ target: Target) {
        guard listening != target else {
            listening = nil
            return
        }
        hunting = false
        listening = target
        Shortcuts.shared.recorder = { event in
            take(event, for: target)
            return true
        }
    }

    private func stop() {
        Shortcuts.shared.recorder = nil
        if listening != nil { listening = nil }
    }

    private func take(_ event: NSEvent, for target: Target) {
        guard let keys = Keys(event) else { return }
        let bare = !keys.command && !keys.option && !keys.control && !keys.shift
        // esc lets it be; Delete leaves it with none.
        if event.keyCode == 53, bare {
            listening = nil
            return
        }
        if keys.key == "⌫" || keys.key == "⌦", bare {
            assign(nil, to: target)
            listening = nil
            return
        }
        guard keys.usable else {
            browser.announce("Hold ⌘, ⌥ or ⌃ with it")
            return
        }
        if let use = FixedKeys.owns(keys) {
            browser.announce("\(keys.label) is for \(use)")
            return
        }
        assign(keys, to: target)
        listening = nil
    }

    private func assign(_ keys: Keys?, to target: Target) {
        switch target {
        case .ours(let command):
            if let taken = shortcuts.set(command, to: keys), let keys {
                browser.announce("\(keys.label) was \(taken.title); it has none now")
            }
        case .theirs(let id, let name):
            guard #available(macOS 15.4, *),
                  let command = Extensions.shared.contexts[id]?.commands.first(where: { $0.id == name })
            else { return }
            if let keys, let owner = shortcuts.owner(of: keys) {
                // Search's own keys come first (see ContentView.take).
                browser.announce("\(keys.label) is \(owner.title) — change that first")
                return
            }
            shortcuts.set(keys, for: command, of: id)
        }
    }
}

/// A command's keys, in a well you click to change them.
private struct Recorder: View {
    let keys: Keys?
    let listening: Bool
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Text(listening ? "Type the keys" : (keys?.label ?? "None"))
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(listening || keys != nil ? Palette.ink : Palette.muted)
                .frame(minWidth: 64)
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
        .help(listening ? "esc to keep it, ⌫ for none" : "Click, then type the new keys")
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: listening)
    }
}

/// The commands the installed extensions declare, each with its keys.
@available(macOS 15.4, *)
private struct ExtensionCommands: View {
    @ObservedObject var extensions: Extensions
    @ObservedObject private var shortcuts = Shortcuts.shared
    let hunt: String
    @Binding var listening: ShortcutsPage.Target?
    let listen: (ShortcutsPage.Target) -> Void

    var body: some View {
        ForEach(declaring, id: \.0) { id, name, commands in
            VStack(alignment: .leading, spacing: 8) {
                Caption(name)
                Card {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        if index > 0 { Rule() }
                        Line(command.title.isEmpty ? command.id : command.title) {
                            Recorder(keys: Shortcuts.keys(of: command),
                                     listening: listening == .theirs(id, command.id)) {
                                listen(.theirs(id, command.id))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Each extension with commands, by name, and those of its commands the
    /// search leaves. The action's own command opens its popup and is named
    /// for that.
    private var declaring: [(String, String, [WKWebExtension.Command])] {
        let hunt = hunt.trimmingCharacters(in: .whitespaces)
        return extensions.contexts
            .compactMap { id, context -> (String, String, [WKWebExtension.Command])? in
                let name = context.webExtension.displayName ?? id
                let commands = context.commands.filter { command in
                    hunt.isEmpty || name.localizedCaseInsensitiveContains(hunt)
                        || command.title.localizedCaseInsensitiveContains(hunt)
                        || (Shortcuts.keys(of: command)?.label.localizedCaseInsensitiveContains(hunt) ?? false)
                }
                return commands.isEmpty ? nil : (id, name, commands)
            }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
}
