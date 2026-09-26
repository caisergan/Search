import AppKit
import SwiftUI
import WebKit

// The browser's own keys, and the ones a person gave it instead.
//
// Every command a key can reach is listed once here, with the key it had
// from the start. What someone changes in Settings › Shortcuts is kept as
// the difference: a command they never touched follows its default, so a
// better default in a later version reaches them too. The key monitor (see
// ContentView.take) and the menus both read from here, so a key changed in
// one place is the key everywhere.

/// A key and the modifiers held with it. The key is what it types with
/// shift let go of, so ⇧⌘] is "]" with shift rather than "}", or a name for the keys that
/// type nothing: arrows, Tab, Return, Delete, Space, F1–F12. The top row of
/// digits is by place, as ⌘1–⌘9 always were.
struct Keys: Hashable, Codable {
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false

    init(_ key: String, command: Bool = true, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// The keystroke an event is, or nothing for one that is only a modifier.
    init?(_ event: NSEvent) {
        guard event.type == .keyDown, let key = Keys.name(of: event) else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        self.init(key, command: flags.contains(.command), shift: flags.contains(.shift),
                  option: flags.contains(.option), control: flags.contains(.control))
    }

    /// Keys that type nothing, by where they are.
    private static let named: [UInt16: String] = [
        123: "←", 124: "→", 125: "↓", 126: "↑", 48: "⇥", 36: "↩", 76: "↩", 51: "⌫", 117: "⌦",
        49: "space", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    private static func name(of event: NSEvent) -> String? {
        if let name = named[event.keyCode] { return name }
        if let digit = ContentView.digits[event.keyCode] { return String(digit) }
        // What the key types with shift let go of — but with ⌘ still held
        // when it is, since a Cyrillic or Greek layout types Latin letters
        // under ⌘, and ⌘T should be ⌘T there too. ⌥ and ⌃ would only turn
        // the key into another character, so they are left out.
        let flags = event.modifierFlags.intersection(.command)
        let bare = event.characters(byApplyingModifiers: flags)?.lowercased()
            ?? event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Control characters, and the private-use ones AppKit gives keys like
        // Help and Clear, are keys with no name worth keeping.
        guard let first = bare.first,
              first.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) })
        else { return nil }
        // ⌘+ is ⌘= on a keyboard where + needs shift, and its own key where
        // it doesn't; both mean the same thing.
        return bare == "+" ? "=" : String(first)
    }

    /// A key everyone can type into a page without it being taken: a
    /// letter or a digit with nothing held, or with only shift. A shortcut
    /// needs ⌘, ⌥ or ⌃ with it, unless it is a function key.
    var usable: Bool {
        command || option || control || key.hasPrefix("f") && key.count > 1
    }

    /// As the Mac writes it: ⌃⌥⇧⌘ and then the key.
    var label: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        switch key {
        case "space": return text + "Space"
        case "home": return text + "↖"
        case "end": return text + "↘"
        case "pageup": return text + "⇞"
        case "pagedown": return text + "⇟"
        case let key where key.hasPrefix("f") && key.count > 1: return text + key.uppercased()
        default: return text + key.uppercased()
        }
    }

    /// For the menu, which draws the same keys beside a command.
    var menu: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        switch key {
        case "←": equivalent = .leftArrow
        case "→": equivalent = .rightArrow
        case "↑": equivalent = .upArrow
        case "↓": equivalent = .downArrow
        case "⇥": equivalent = .tab
        case "↩": equivalent = .return
        case "⌫": equivalent = .delete
        case "⌦": equivalent = .deleteForward
        case "space": equivalent = .space
        case "home": equivalent = .home
        case "end": equivalent = .end
        case "pageup": equivalent = .pageUp
        case "pagedown": equivalent = .pageDown
        case let key where key.count == 1: equivalent = KeyEquivalent(Character(key))
        // Function keys have no KeyEquivalent of their own; the key still
        // works, the menu just doesn't show it.
        default: return nil
        }
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }
}

/// Everything a key can do in Search, with the key it has out of the box.
enum Command: String, CaseIterable, Identifiable {
    case newTab, newPrivateTab, reopenTab, openAddress, closeTab, duplicateTab
    case back, forward, nextTab, previousTab, searchTabs
    case reload, hardReload, readingMode, floatVideo, stopSound, print, savePage
    case find, findNext, findPrevious
    case copyAddress, pasteAndGo, addBookmark
    case sidebar, foldSidebar
    case zoomIn, zoomOut, actualSize
    case hideElements, undoHide, hiddenOnSite
    case history, downloads, passwords, settings
    case webInspector, javaScriptConsole, inspectElement

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case tabs, page, find, window, panels, developer
        var id: String { rawValue }
        var title: String {
            switch self {
            case .tabs: return "Tabs"
            case .page: return "Page"
            case .find: return "Find and hide"
            case .window: return "Window and zoom"
            case .panels: return "Panels"
            case .developer: return "Developer"
            }
        }
    }

    var group: Group {
        switch self {
        case .newTab, .newPrivateTab, .reopenTab, .openAddress, .closeTab, .duplicateTab,
             .nextTab, .previousTab, .searchTabs:
            return .tabs
        case .back, .forward, .reload, .hardReload, .readingMode, .floatVideo, .stopSound, .print, .savePage,
             .copyAddress, .pasteAndGo, .addBookmark:
            return .page
        case .find, .findNext, .findPrevious, .hideElements, .undoHide, .hiddenOnSite:
            return .find
        case .sidebar, .foldSidebar, .zoomIn, .zoomOut, .actualSize:
            return .window
        case .history, .downloads, .passwords, .settings:
            return .panels
        case .webInspector, .javaScriptConsole, .inspectElement:
            return .developer
        }
    }

    var title: String {
        switch self {
        case .newTab: return "New tab"
        case .newPrivateTab: return "New private tab"
        case .reopenTab: return "Reopen closed tab"
        case .openAddress: return "Open address"
        case .closeTab: return "Close tab"
        case .duplicateTab: return "Duplicate tab"
        case .back: return "Back"
        case .forward: return "Forward"
        case .nextTab: return "Next tab"
        case .previousTab: return "Previous tab"
        case .searchTabs: return "Search tabs"
        case .reload: return "Reload page"
        case .hardReload: return "Empty cache and reload"
        case .readingMode: return "Reading mode"
        case .floatVideo: return "Float video"
        case .stopSound: return "Stop sound in tab"
        case .print: return "Print"
        case .savePage: return "Download this page"
        case .find: return "Find on page"
        case .findNext: return "Find next"
        case .findPrevious: return "Find previous"
        case .copyAddress: return "Copy address"
        case .pasteAndGo: return "Paste and go"
        case .addBookmark: return "Bookmark this page"
        case .sidebar: return "Tabs in a sidebar"
        case .foldSidebar: return "Fold the tabs away"
        case .zoomIn: return "Zoom in"
        case .zoomOut: return "Zoom out"
        case .actualSize: return "Actual size"
        case .hideElements: return "Hide something on this site"
        case .undoHide: return "Undo the last hide, while hiding"
        case .hiddenOnSite: return "Hidden on this site"
        case .history: return "History"
        case .downloads: return "Downloads"
        case .passwords: return "Passwords"
        case .settings: return "Settings"
        case .webInspector: return "Web Inspector"
        case .javaScriptConsole: return "JavaScript console"
        case .inspectElement: return "Inspect element"
        }
    }

    var standard: Keys {
        switch self {
        case .newTab: return Keys("t")
        case .newPrivateTab: return Keys("n", shift: true)
        case .reopenTab: return Keys("t", shift: true)
        case .openAddress: return Keys("l")
        case .closeTab: return Keys("w")
        case .duplicateTab: return Keys("d")
        case .back: return Keys("[")
        case .forward: return Keys("]")
        case .nextTab: return Keys("]", shift: true)
        case .previousTab: return Keys("[", shift: true)
        case .searchTabs: return Keys("k")
        case .reload: return Keys("r")
        case .hardReload: return Keys("r", shift: true)
        // ⇧⌘R until the hard reload took it, as Chrome has it.
        case .readingMode: return Keys("r", option: true)
        case .floatVideo: return Keys("p", shift: true)
        case .stopSound: return Keys("m", shift: true)
        case .print: return Keys("p")
        // ⌘S folds the tabs away here, and ⇧⌘S puts them in a sidebar.
        case .savePage: return Keys("s", option: true)
        case .find: return Keys("f")
        case .findNext: return Keys("g")
        case .findPrevious: return Keys("g", shift: true)
        case .copyAddress: return Keys("c", shift: true)
        case .pasteAndGo: return Keys("v", shift: true)
        case .addBookmark: return Keys("b", shift: true)
        case .sidebar: return Keys("s", shift: true)
        case .foldSidebar: return Keys("s")
        case .zoomIn: return Keys("=")
        case .zoomOut: return Keys("-")
        case .actualSize: return Keys("0")
        case .hideElements: return Keys("h", shift: true)
        case .undoHide: return Keys("z")
        case .hiddenOnSite: return Keys("u", shift: true)
        case .history: return Keys("y")
        case .downloads: return Keys("j", shift: true)
        case .passwords: return Keys("l", option: true)
        case .settings: return Keys(",")
        case .webInspector: return Keys("i", option: true)
        case .javaScriptConsole: return Keys("j", option: true)
        case .inspectElement: return Keys("c", option: true)
        }
    }

    /// The keys that make and close tabs and move between them stay
    /// Search's first, as Chrome keeps them its own; every other key goes to
    /// the page first (see ContentView.pageFirst).
    var reserved: Bool {
        switch self {
        case .newTab, .reopenTab, .closeTab, .newPrivateTab, .nextTab, .previousTab: return true
        default: return false
        }
    }
}

/// Keys that do one thing and can't be given to another: they are a range,
/// or they belong to what is in front rather than to a command.
struct FixedKeys: Identifiable {
    let keys: String
    let does: String
    var id: String { keys }

    static let all: [FixedKeys] = [
        FixedKeys(keys: "⌘1–⌘8", does: "The tab in that place"),
        FixedKeys(keys: "⌘9", does: "The last tab"),
        FixedKeys(keys: "⌃1–⌃9", does: "The space in that place, with spaces on"),
        FixedKeys(keys: "⌃⇥  ⌃⇧⇥", does: "Next and previous tab, round the row"),
        FixedKeys(keys: "⌘←  ⌘→", does: "Back and forward, when not typing"),
        FixedKeys(keys: "⌘K held", does: "Walk the tabs, let go of ⌘ to open one"),
        FixedKeys(keys: "⇥  ⇧⇥", does: "Move through the list under the address field"),
        FixedKeys(keys: "esc", does: "Close whatever is in front, or put the page back"),
    ]

    /// Whether a keystroke is one of these, and so can't be recorded.
    static func owns(_ keys: Keys) -> String? {
        let digit = Int(keys.key).map { (1...9).contains($0) } ?? false
        if digit, keys.command, !keys.shift, !keys.option, !keys.control { return "a tab by its place" }
        if digit, keys.control, !keys.shift, !keys.option, !keys.command { return "a space by its place" }
        if keys.key == "⇥", keys.control, !keys.command, !keys.option { return "the next and previous tab" }
        if keys.key == "←" || keys.key == "→", keys.command, !keys.shift, !keys.option, !keys.control { return "back and forward" }
        return nil
    }
}

@MainActor
final class Shortcuts: ObservableObject {
    static let shared = Shortcuts()

    private let store = Store.settings
    private static let key = "shortcuts"
    private static let extensionKey = "shortcuts.extensions"

    /// Settings › Shortcuts, listening for the next key: while it is set,
    /// every keystroke goes to it and none does anything else.
    var recorder: ((NSEvent) -> Bool)?

    /// What a person changed, by command. A command with nil has no key at all.
    @Published private(set) var changed: [String: Keys?] = [:]

    private init() {
        if let data = store.data(forKey: Shortcuts.key),
           let saved = try? JSONDecoder().decode([String: Keys?].self, from: data) {
            // A command a later version dropped is dropped with it.
            changed = saved.filter { Command(rawValue: $0.key) != nil }
        }
        rebuild()
    }

    /// The key a command has now.
    func keys(_ command: Command) -> Keys? {
        if let mine = changed[command.rawValue] { return mine }
        return command.standard
    }

    func isChanged(_ command: Command) -> Bool { changed[command.rawValue] != nil }

    var anyChanged: Bool { !changed.isEmpty }

    /// For the menu's line: the key if there is one.
    func menu(_ command: Command) -> KeyboardShortcut? { keys(command)?.menu }

    /// The command a keystroke is, if any.
    func command(for event: NSEvent) -> Command? {
        guard let keys = Keys(event) else { return nil }
        return lookup[keys]
    }

    /// Gives a command a key, or none. A key another command had is taken
    /// from it, and that command is returned so it can be said.
    @discardableResult
    func set(_ command: Command, to keys: Keys?) -> Command? {
        var taken: Command?
        if let keys, let other = lookup[keys], other != command {
            taken = other
            put(other, nil)
        }
        put(command, keys)
        save()
        return taken
    }

    func reset(_ command: Command) {
        // The default may have gone to another command meanwhile.
        if let other = lookup[command.standard], other != command { put(other, nil) }
        changed[command.rawValue] = nil
        rebuild()
        save()
    }

    func resetAll() {
        changed = [:]
        rebuild()
        save()
    }

    /// The command a key belongs to now.
    func owner(of keys: Keys) -> Command? { lookup[keys] }

    // MARK: - kept

    private var lookup: [Keys: Command] = [:]

    private func put(_ command: Command, _ keys: Keys?) {
        changed[command.rawValue] = keys == command.standard ? nil : .some(keys)
        rebuild()
    }

    private func rebuild() {
        var lookup: [Keys: Command] = [:]
        for command in Command.allCases {
            if let keys = keys(command), lookup[keys] == nil { lookup[keys] = command }
        }
        self.lookup = lookup
    }

    private func save() {
        guard !changed.isEmpty, let data = try? JSONEncoder().encode(changed) else {
            store.removeObject(forKey: Shortcuts.key)
            return
        }
        store.set(data, forKey: Shortcuts.key)
    }

    // MARK: - an extension's

    /// The keys a person gave an extension's commands, by extension and
    /// command. WebKit forgets them when the extension loads again, so they
    /// are put back each time (see Extensions.load).
    private var extensionKeys: [String: [String: Keys?]] {
        get {
            guard let data = store.data(forKey: Shortcuts.extensionKey) else { return [:] }
            return (try? JSONDecoder().decode([String: [String: Keys?]].self, from: data)) ?? [:]
        }
        set {
            guard !newValue.isEmpty, let data = try? JSONEncoder().encode(newValue) else {
                store.removeObject(forKey: Shortcuts.extensionKey)
                return
            }
            store.set(data, forKey: Shortcuts.extensionKey)
        }
    }

    @available(macOS 15.4, *)
    func apply(to context: WKWebExtensionContext, id: String) {
        guard let mine = extensionKeys[id] else { return }
        for command in context.commands {
            guard let keys = mine[command.id] else { continue }
            Shortcuts.write(keys, into: command)
        }
    }

    @available(macOS 15.4, *)
    func set(_ keys: Keys?, for command: WKWebExtension.Command, of id: String) {
        var all = extensionKeys
        all[id, default: [:]][command.id] = .some(keys)
        extensionKeys = all
        Shortcuts.write(keys, into: command)
        objectWillChange.send()
    }

    @available(macOS 15.4, *)
    private static func write(_ keys: Keys?, into command: WKWebExtension.Command) {
        guard let keys else {
            command.activationKey = nil
            command.modifierFlags = []
            return
        }
        var flags: NSEvent.ModifierFlags = []
        if keys.command { flags.insert(.command) }
        if keys.shift { flags.insert(.shift) }
        if keys.option { flags.insert(.option) }
        if keys.control { flags.insert(.control) }
        command.activationKey = keys.key
        command.modifierFlags = flags
    }

    @available(macOS 15.4, *)
    static func keys(of command: WKWebExtension.Command) -> Keys? {
        guard let key = command.activationKey, !key.isEmpty else { return nil }
        let flags = command.modifierFlags
        return Keys(key.lowercased(), command: flags.contains(.command), shift: flags.contains(.shift),
                    option: flags.contains(.option), control: flags.contains(.control))
    }
}
