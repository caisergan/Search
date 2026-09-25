import SwiftUI

/// Everything there is to set. Pages down the left, one page at a time on
/// the right, each a short list of lines with a hairline between them —
/// nothing to scroll through, nothing to hunt for. The same white and
/// hairline as the rest of the app; the same pill for the page you are on
/// as for the tab you are on.
struct SettingsPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var shield = Shield.shared
    @State private var isDefault = Links.isDefault
    @State private var page: Page = Page(rawValue: Store.settings.string(forKey: "settings.page") ?? "") ?? .general

    enum Page: String, CaseIterable, Identifiable {
        case general, customization, tabs, shortcuts, extensions, passwords, downloads, privacy, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .customization: return "Customization"
            case .tabs: return "Tabs"
            case .shortcuts: return "Shortcuts"
            case .extensions: return "Extensions"
            case .passwords: return "Passwords"
            case .downloads: return "Downloads"
            case .privacy: return "Privacy"
            case .about: return "About"
            }
        }
        var icon: String {
            switch self {
            case .general: return "macwindow"
            case .customization: return "paintbrush"
            case .tabs: return "rectangle.split.3x1"
            case .shortcuts: return "keyboard"
            case .extensions: return "puzzlepiece.extension"
            case .passwords: return "key"
            case .downloads: return "arrow.down.circle"
            case .privacy: return "hand.raised"
            case .about: return "info.circle"
            }
        }
    }

    private static let rail: CGFloat = 188
    private static let width: CGFloat = 840
    private static let height: CGFloat = 640
    /// Room kept around the panel when the window is smaller than it.
    private static let margin: CGFloat = 32

    var body: some View {
        HStack(spacing: 0) {
            pages
            Rectangle().fill(Palette.hairline).frame(width: 1)
            content
        }
        // As big as it likes, short of a small window's edges.
        .frame(maxWidth: SettingsPanel.width, maxHeight: SettingsPanel.height)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 34, y: 12)
        .padding(SettingsPanel.margin)
        .onChange(of: page) { _, page in Store.settings.set(page.rawValue, forKey: "settings.page") }
    }

    // MARK: - the rail

    private var pages: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 12)
            ForEach(Page.allCases) { item in
                PageRow(page: item, on: page == item) { page = item }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: SettingsPanel.rail, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.wash.opacity(0.45), in: Rectangle())
    }

    private struct PageRow: View {
        let page: Page
        let on: Bool
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                HStack(spacing: 9) {
                    Image(systemName: page.icon)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                    Text(page.title)
                        .font(.system(size: 13, weight: on ? .medium : .regular))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(on ? Palette.ink : (hovering ? Palette.ink.opacity(0.75) : Palette.muted))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? Palette.ground : (hovering ? Palette.hover : .clear))
                        .shadow(color: .black.opacity(on ? 0.06 : 0), radius: 3, y: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }

    // MARK: - the page

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(page.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Door(icon: "xmark", help: "Done   esc") { browser.tuning = false }
            }
            .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    switch page {
                    case .general: general
                    case .customization: customization
                    case .tabs: tabs
                    case .shortcuts: ShortcutsPage(browser: browser)
                    case .extensions: ExtensionsPage(browser: browser)
                    case .passwords: passwords
                    case .downloads: downloads
                    case .privacy: privacy
                    case .about: about
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - general

    private var general: some View {
        Card {
            Line(
                "Open links from other apps",
                isDefault ? "Search is the default browser on this Mac" : "Mail, Slack and the rest still send links elsewhere"
            ) {
                if isDefault {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 24)
                } else {
                    Pill("Make default", filled: true) {
                        Links.becomeDefault { worked in
                            isDefault = Links.isDefault
                            browser.announce(worked && isDefault ? "Links now open here" : "macOS didn't change it")
                        }
                    }
                }
            }
            Rule()
            Line("Search with", searchDetail) {
                Picker("", selection: $prefs.engine) {
                    ForEach(Engine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            if prefs.engine == .custom {
                ZStack(alignment: .leading) {
                    if prefs.customEngine.isEmpty {
                        Text("https://example.com/search?q=%s")
                            .foregroundStyle(Palette.muted.opacity(0.8))
                    }
                    TextField("", text: $prefs.customEngine)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Palette.ink)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.bottom, 11)
            }
            Rule()
            Line("Correct spelling as you type", "macOS's autocorrect inside pages — the one that capitalises for you") {
                Switch(on: $prefs.autocorrect)
            }
            Rule()
            Line("Peek at a link with a shift-click", "Its page opens in a panel over the one you're reading. Escape puts it away; the other button keeps it as a tab") {
                Switch(on: $prefs.peeksLinks)
            }
            Rule()
            Line("Open links from other apps in a small window", "To read and close, or keep with Open in Search (⌘O)") {
                Switch(on: $prefs.littleLinks)
            }
            Rule()
            Line("Show where links go", "Point at a link and its address shows at the bottom of the page") {
                Switch(on: $prefs.showsLinks)
            }
            Rule()
            Line("Scroll with the middle button", "Click the wheel on a page, then move the mouse up or down to scroll, as on Windows. Click again to stop") {
                Switch(on: $prefs.autoScroll)
            }
            Rule()
            Line("Pages at 120 Hz", "Animations and scrolling in pages at up to 120 frames a second on a screen that can, instead of 60 as in Safari. Uses more battery. Open tabs follow when reloaded") {
                Switch(on: $prefs.fastPages)
            }
            Rule()
            Line("Flick the floating video to a corner", "Two fingers on it send it to the corner or edge they point at, instead of pushing it along. Dragging still puts it anywhere") {
                Switch(on: $prefs.floatFlicks)
            }
            Rule()
            Line("Float the video when you switch tabs", "A video playing on YouTube and the like comes out into its floating window when you go to another tab, and back when you return. ⇧⌘P still floats one by hand") {
                Switch(on: $prefs.floatsOnLeave)
            }
            Rule()
            Line("Float the video when you switch apps", "A video playing on the site you're on comes out into its floating window as another app comes to the front, and goes back into its tab when you return") {
                Switch(on: $prefs.floatsAway)
            }
            Rule()
            Line("Let a script drive Search", "A local socket for testing. Its tabs open beside yours with a flask on them and never take over — see ./bench") {
                Switch(on: $prefs.bench)
            }
        }
    }

    private var searchDetail: String {
        guard prefs.engine == .custom else { return "Where words that aren't an address go" }
        guard Engine.accepts(prefs.customEngine) else {
            return "An http or https address with %s where the words go. Until then, Google"
        }
        return "Words go to \(prefs.engine.name(custom: prefs.customEngine))"
    }

    // MARK: - customization

    /// How Search looks, as opposed to what it does. Everything here but the
    /// appearance is off until someone picks it.
    private var customization: some View {
        Card {
            Line("Appearance", "Light, dark, or whatever the Mac is doing — pages follow it too") {
                Segmented(options: Look.allCases.map { ($0, $0.title) }, selection: $prefs.look)
            }
            Rule()
            Line("Theme", themeDetail) { EmptyView() }
                .padding(.bottom, -4)
            ThemePicker(selection: $prefs.theme)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            Rule()
            Line("Tab size", "Large makes titles easier to read, in the sidebar and across the top") {
                Segmented(
                    options: TabSize.allCases.map { ($0, $0.title) },
                    selection: Binding(
                        get: { prefs.tabSize },
                        set: { size in withAnimation(Motion.glide) { prefs.tabSize = size } }
                    )
                )
            }
            Rule()
            Line("Show zoom at", "Where the page's size shows while ⌘+, ⌘− or a pinch changes it") {
                Picker("", selection: $prefs.zoomSpot) {
                    ForEach(ZoomSpot.allCases) { spot in
                        Text(spot.title).tag(spot)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            if prefs.sidebar {
                Rule()
                Line("New tab at the foot of the sidebar", "A + in the bottom right corner, instead of the row under the last tab") {
                    Switch(on: Binding(
                        get: { prefs.newTabInFoot },
                        set: { on in withAnimation(Motion.glide) { prefs.newTabInFoot = on } }
                    ))
                }
            }
        }
    }

    private var themeDetail: String {
        switch prefs.theme.family {
        case .basic where prefs.theme == .plain: return "The window around the page in one solid colour"
        case .basic: return "The desktop shows through the tabs, blurred, and the page sits on it as a card"
        case .hue: return "The desktop shows through the tabs, blurred and tinted \(prefs.theme.title.lowercased()), the page a card on it"
        case .gradient: return "The desktop shows through the tabs, blurred under a gradient, the page a card on it"
        case .glow: return "Soft glows of colour over the blurred desktop, the page a card on them"
        case .dark: return "Nearly black, lit at its edges by a glow or two, the page a card on it"
        }
    }

    // MARK: - tabs

    private var tabs: some View {
        Card {
            Line("Tabs in a sidebar", "Down the left instead of across the top. Pull its edge to make it wider; double-click the edge to reset.") {
                Switch(on: Binding(
                    get: { prefs.sidebar },
                    set: { on in withAnimation(Motion.glide) { prefs.sidebar = on } }
                ))
            }
            if prefs.sidebar {
                Rule()
                Line("Hide the sidebar until the pointer reaches the edge", "The page takes the whole window; push against its left edge for the tabs. ⌘S keeps them out.") {
                    Switch(on: $prefs.sideHides)
                }
                Rule()
                Line("Show the address in the sidebar", "Over the tabs, under the lights. A click, or ⌘L, opens the field from there.") {
                    Switch(on: $prefs.sideAddress)
                }
                if prefs.sideHides {
                    Rule()
                    Line("Show the sidebar", "How long the pointer rests on the left edge to show the sidebar") {
                        Segmented(options: Reveal.allCases.map { ($0, $0.title) }, selection: $prefs.sideReveal, icon: { $0.icon })
                    }
                }
            }
            Rule()
            Line("Tabs show", "Beside the title, and on a pinned square") {
                Segmented(options: Glyph.allCases.map { ($0, $0.title) }, selection: $prefs.glyph)
            }
            Rule()
            Line("Open new tabs over the page", "⌘T brings the address field up over the page you're on. The tab opens when you go somewhere; esc leaves you where you were.") {
                Switch(on: $prefs.newTabOver)
            }
            Rule()
            Line("Show the bookmarks bar", "Your bookmarks in a row above the page, folders opening as menus. It folds away with the tabs") {
                Switch(on: $prefs.bookmarksBar)
            }
            Rule()
            Line("Show how far you've read", "The tab you're on fills with grey as you scroll down the page") {
                Switch(on: $prefs.showsReading)
            }
            Rule()
            Line("Sleep tabs you aren't using", "After half an hour away they come back where you left them. Pinned tabs, sound, calls and anything typed stay awake.") {
                Switch(on: $prefs.sleepsTabs)
            }
            Rule()
            Line("Load with Search", "The tabs that load when Search opens, after the tab you were on, instead of waiting for a click. Pinned takes in the Essentials.") {
                Segmented(options: StartLoad.allCases.map { ($0, $0.title) }, selection: $prefs.startLoad)
            }
            Rule()
            Line("Glance", "Hold \(prefs.glanceTrigger.key) and click a link to look at it over the page instead of opening a tab. esc or a click beside it puts it away; the arrow keeps it as a tab.") {
                Switch(on: $prefs.glances)
            }
            if prefs.glances {
                Rule()
                Line("Glance with", "The key held while clicking. ⌘⇧-click and the middle button still open a tab") {
                    Segmented(options: GlanceTrigger.allCases.map { ($0, $0.title) }, selection: $prefs.glanceTrigger)
                }
            }
            Rule()
            Line("Spaces", "Separate sets of tabs, signed in where the others are or starting afresh, switched with ⌃1–⌃9, two fingers sideways over the column, or the space's icon. Mission Control's own ⌃1–⌃9, if you turned them on, take those keys first.") {
                Switch(on: $prefs.usesSpaces)
            }
        }
    }

    // MARK: - passwords

    /// Says so when a password manager extension has taken the saving over.
    private var savingDetail: String {
        if #available(macOS 15.4, *), let name = Extensions.shared.passwordSavingTakenBy {
            return "\(name) does the saving — it asked Search not to offer"
        }
        return "Asked once per site, never again for a site you refuse"
    }

    private var passwords: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("Your passwords", "In the macOS keychain, shown with Touch ID") {
                    Pill("Open…") {
                        browser.tuning = false
                        browser.managing = true
                    }
                }
                Rule()
                Line("Offer to save passwords", savingDetail) {
                    Switch(on: $prefs.savesPasswords)
                }
                Rule()
                Line("Fill in sign-ins", "Click a sign-in box and the accounts kept for the site hang from it") {
                    Switch(on: $prefs.fillsPasswords)
                }
                Rule()
                Line(
                    "Offer passkeys",
                    !prefs.passkeysPossible
                        ? "Needs an Apple entitlement this build doesn't have — off keeps sites to the password"
                        : Passkeys.access == .denied
                        ? "macOS was told no — System Settings › Privacy & Security › Passkeys Access for Web Browsers"
                        : "Touch ID or an iCloud passkey, on sites that offer one"
                ) {
                    Switch(on: $prefs.passkeys)
                }
                if !Vault.never.isEmpty {
                    Rule()
                    Line("Sites never asked", "\(Vault.never.count) sites told to stop offering") {
                        Pill("Forget") {
                            Vault.never = []
                            browser.announce("Every site can ask again")
                        }
                    }
                }
            }
            Card {
                Line("Bring yours in", "From Dia, Chrome, Arc, Brave or Edge on this Mac — nothing leaves it") {
                    Pill("Import…") {
                        browser.tuning = false
                        browser.managing = true
                    }
                }
            }
        }
    }

    // MARK: - downloads

    private var downloads: some View {
        Card {
            Line("Save to", prefs.downloads.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                Pill("Change…") { chooseFolder() }
            }
            Rule()
            Line("Ask where to save each file") {
                Switch(on: $prefs.asksWhereToSave)
            }
        }
    }

    // MARK: - privacy

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("Block ads and trackers", shield.trouble ?? "Third parties whose only job is to watch") {
                    Switch(on: $prefs.shielded)
                }
                if let trouble = shield.trouble {
                    Rule()
                    Line(trouble, "Nothing is being blocked until this clears — try again, or restart Search") {
                        Pill("Try again") { shield.compile() }
                    }
                }
                if let host = browser.hereHost, prefs.shielded, shield.trouble == nil {
                    Rule()
                    Line("Block on \(host)", "Turn off here if the site breaks — the page reloads") {
                        Switch(on: Binding(
                            get: { !Shield.shared.isPaused(on: host) },
                            set: { on in
                                Shield.shared.pause(host, !on)
                                browser.reload()
                            }
                        ))
                    }
                }
                Rule()
                Line("Camera and microphone", "What each site was allowed or refused") {
                    Pill("Forget choices") { browser.forgetCaptureChoices() }
                }
            }
            Card {
                Line("History", "Every address you have been to") {
                    Pill("Clear") { browser.clearHistory() }
                }
                Rule()
                Line("Cookies and sign-ins", "Signs you out of every site") {
                    Pill("Sign out of everything") { browser.clearSites() }
                }
                Rule()
                Line("Cache", "Only what was fetched to draw pages") {
                    Pill("Clear") { browser.clearCache() }
                }
            }
        }
    }

    // MARK: - about

    private var about: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Logomark()
                    .fill(Palette.ink, style: FillStyle(eoFill: true))
                    .aspectRatio(Logomark.canvas.width / Logomark.canvas.height, contentMode: .fit)
                    .frame(height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Search")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("by Office Commun · version \(Updater.version)")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.bottom, 2)

            Card {
                Line(versionTitle, versionDetail) { versionControl }
                Rule()
                Line("Install updates on its own", "Off, Search still looks once a day and tells you, and installs only when you press Install") {
                    Switch(on: $prefs.installsUpdates)
                }
                Rule()
                Line("Found something wrong?", "Opens a draft with the version already in it") {
                    Pill("Send Feedback") { Links.writeFeedback() }
                }
            }

            Card {
                Line("Keyboard shortcuts", "Every key Search answers to, and yours to change") {
                    Pill("Show") { page = .shortcuts }
                }
            }
        }
    }

    /// The version line follows the newer build from found to fetched to
    /// in place; with none, it is simply this one.
    private var versionTitle: String {
        switch updater.stage {
        case .none: return "Updates"
        case .fetching(let next): return "Search \(next.version) is downloading…"
        case .ready(let next): return "Search \(next.version) is ready"
        case .offered(let next), .waiting(let next): return "Search \(next.version) is out"
        }
    }

    private var versionDetail: String {
        switch updater.stage {
        case .none:
            return updater.lastChecked.map { "Checked \($0.formatted(.relative(presentation: .named))) — once a day on its own" }
                ?? "Checked once a day on its own"
        case .fetching(let next):
            return next.notes ?? "Quietly, in the background — nothing you have set is touched"
        case .ready(let next):
            return next.notes ?? "It's there the next time you open Search"
        case .offered(let next):
            return next.notes ?? "Open the disk image, the same as the first time"
        case .waiting(let next):
            return next.notes ?? "Checked and put in place when you press Install"
        }
    }

    @ViewBuilder
    private var versionControl: some View {
        switch updater.stage {
        case .none:
            Pill(updater.checking ? "Checking…" : "Check now") {
                updater.check { found in
                    if found == nil { browser.announce("This is the latest one") }
                }
            }
            .disabled(updater.checking)
        case .fetching:
            Ring(size: 12)
        case .ready:
            Pill("Relaunch now", filled: true) { updater.relaunch() }
        case .offered(let next):
            Pill("Download", filled: true) {
                browser.tuning = false
                browser.open(next.dmg, foreground: true)
            }
        case .waiting:
            Pill("Install", filled: true) { updater.install() }
        }
    }

    // MARK: - doing

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.downloads
        panel.prompt = "Use this folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.downloads = url
    }

}

/// A row of choices in a grey track, one of them lifted out in white. The
/// white slides to the one you pick rather than appearing there.
struct Segmented<Option: Hashable>: View {
    let options: [(Option, String)]
    @Binding var selection: Option
    /// True when the control has the whole width to itself, so the choices
    /// share it evenly instead of each taking only what its word needs.
    var wide = false
    /// A symbol before a choice's word, for the choices that have one.
    var icon: (Option) -> String? = { _ in nil }

    @Namespace private var slide

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option, title in
                HStack(spacing: 4) {
                    if let symbol = icon(option) {
                        Image(systemName: symbol)
                            .font(.system(size: 10))
                    }
                    Text(title)
                }
                    .font(.system(size: 11.5, weight: option == selection ? .medium : .regular))
                    .foregroundStyle(option == selection ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .fixedSize(horizontal: !wide, vertical: false)
                    .frame(maxWidth: wide ? .infinity : nil)
                    .padding(.horizontal, wide ? 4 : 10)
                    .padding(.vertical, 5)
                    .background {
                        if option == selection {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Palette.ground)
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "chosen", in: slide)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .onTapGesture {
                        withAnimation(Motion.settle) { selection = option }
                    }
            }
        }
        .padding(2)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(Motion.settle, value: selection)
    }
}

/// Every theme as a small window of its own — the column, and the page as it
/// sits beside it — its name under it, and a ring round the one in use.
///
/// More of them than the card is wide, so they run on sideways in one row,
/// each kind under its own word: two fingers slide it, and the arrows at
/// either end step it along for a mouse, whose wheel only goes up and down.
/// Over the row, a card for each kind narrows it to that kind alone.
struct ThemePicker: View {
    @Binding var selection: Theme

    /// The kind the row is narrowed to. Every theme, when nil.
    @State private var kind: Theme.Family?
    /// The first theme in view, kept by the row as it slides.
    @State private var first: Theme?
    @State private var width: CGFloat = 0

    private static let swatch: CGFloat = 58
    private static let gap: CGFloat = 8
    /// The extra air before the first theme of each kind.
    private static let kindGap: CGFloat = 12

    private var all: [Theme] { kind?.themes ?? Theme.allCases }

    /// How many fit side by side, and how far an arrow goes: all but one,
    /// so the one at the edge stays in view as a landmark.
    private var fits: Int { max(1, Int(width / (Self.swatch + Self.gap))) }
    private var at: Int { first.flatMap { all.firstIndex(of: $0) } ?? 0 }
    private var more: Bool { at + fits < all.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            kinds
            row
        }
    }

    // MARK: kinds

    /// All, then one card per kind, sharing the width evenly.
    private var kinds: some View {
        HStack(spacing: 6) {
            KindCard(title: "All", count: Theme.allCases.count, on: kind == nil) {
                AngularGradient(
                    colors: [.pink, .orange, .yellow, .green, .teal, .blue, .purple, .pink],
                    center: .center
                )
                .blur(radius: 6)
            } pick: { narrow(to: nil) }
            ForEach(Theme.Family.allCases, id: \.self) { family in
                KindCard(title: family.title, count: family.themes.count, on: kind == family) {
                    KindFace(family: family)
                } pick: { narrow(to: family) }
            }
        }
    }

    private func narrow(to family: Theme.Family?) {
        withAnimation(Motion.settle) { kind = family }
    }

    /// A kind, drawn as a sample of itself, its name and how many it holds
    /// laid over the sample.
    private struct KindCard<Face: View>: View {
        let title: String
        let count: Int
        let on: Bool
        @ViewBuilder let face: () -> Face
        let pick: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: pick) {
                ZStack(alignment: .bottomLeading) {
                    face()
                    // Something for the words to stand on, whatever the
                    // sample does underneath.
                    LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                        Spacer(minLength: 0)
                        Text("\(count)")
                            .font(.system(size: 9.5, weight: .medium))
                            .opacity(0.75)
                    }
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.bottom, 5)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                )
                .padding(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(on ? Palette.ink : (hovering ? Palette.faint : .clear), lineWidth: 1.5)
                )
                .scaleEffect(hovering && !on ? 1.02 : 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: on)
        }
    }

    /// What each kind looks like at a glance.
    private struct KindFace: View {
        let family: Theme.Family

        var body: some View {
            switch family {
            case .basic:
                LinearGradient(colors: [Color(white: 0.62), Color(white: 0.34)], startPoint: .topLeading, endPoint: .bottomTrailing)
            case .hue:
                HStack(spacing: 0) {
                    ForEach([Theme.rose, .amber, .lime, .teal, .sky, .violet], id: \.self) { ThemePaint(theme: $0) }
                }
            case .gradient:
                ThemePaint(theme: .sunset)
            case .glow:
                ThemePaint(theme: .nova)
            case .dark:
                ThemePaint(theme: .eclipse)
            }
        }
    }

    // MARK: the row

    private var row: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(all) { theme in
                        // The kinds' words only while every kind is in
                        // the row; narrowed, its card above says it.
                        let opens = kind == nil && theme.family.themes.first == theme
                        VStack(alignment: .leading, spacing: 6) {
                            // The kind's word over its first theme, and
                            // room for it over the rest.
                            Text(opens ? theme.family.title : " ")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                                .fixedSize()
                                .frame(width: Self.swatch, alignment: .leading)
                            Swatch(theme: theme, on: theme == selection)
                                .frame(width: Self.swatch)
                                .onTapGesture { withAnimation(Motion.settle) { selection = theme } }
                        }
                        .padding(.leading, opens && theme != all.first ? Self.kindGap : 0)
                        .id(theme)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $first, anchor: .leading)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { width = geo.size.width }
                        .onChange(of: geo.size.width) { _, new in width = new }
                }
            }
            // The row fades out under an arrow, so it reads as going on.
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: at > 0 ? 28 : 0)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: more ? 28 : 0)
                }
            }
            .overlay(alignment: .leading) {
                if at > 0 {
                    arrow("chevron.left") { step(-1, reader) }
                }
            }
            .overlay(alignment: .trailing) {
                if more {
                    arrow("chevron.right") { step(1, reader) }
                }
            }
            .animation(Motion.quick, value: at)
            .animation(Motion.quick, value: more)
            // The one in use, in view, whichever it is.
            .onAppear { reader.scrollTo(selection, anchor: .center) }
            // Narrowed or widened: from the start, or from the one in use
            // when it is among them.
            .onChange(of: kind) { _, _ in
                if all.contains(selection) {
                    reader.scrollTo(selection, anchor: .center)
                } else if let start = all.first {
                    reader.scrollTo(start, anchor: .leading)
                }
            }
        }
    }

    private func step(_ direction: Int, _ reader: ScrollViewProxy) {
        let stride = max(1, fits - 1)
        let to = min(max(0, at + direction * stride), all.count - 1)
        withAnimation(Motion.glide) { reader.scrollTo(all[to], anchor: .leading) }
    }

    /// Level with the swatches, under the kinds' words.
    private func arrow(_ icon: String, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 22, height: 22)
                .background(Palette.ground, in: Circle())
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .transition(.opacity)
    }

    private struct Swatch: View {
        let theme: Theme
        let on: Bool
        @State private var hovering = false

        var body: some View {
            VStack(spacing: 5) {
                window
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Palette.hairline, lineWidth: 1)
                    )
                    .padding(2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(on ? Palette.ink : (hovering ? Palette.faint : .clear), lineWidth: 1.5)
                    )
                Text(theme.title)
                    .font(.system(size: 11, weight: on ? .medium : .regular))
                    .foregroundStyle(on ? Palette.ink : Palette.muted)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .help(theme.title)
        }

        /// A column with a live line in it, and the page beside it: flat for
        /// plain, a card on glass for the rest.
        private var window: some View {
            ZStack {
                if theme.isGlass {
                    // What frost looks like, without a desktop to frost.
                    LinearGradient(colors: [Palette.faint.opacity(0.9), Palette.wash], startPoint: .topLeading, endPoint: .bottomTrailing)
                    ThemePaint(theme: theme)
                        .opacity(min(1, theme.strength + 0.3))
                } else {
                    Palette.ground
                }
                HStack(spacing: theme.isGlass ? 3 : 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(Palette.ink.opacity(0.18)).frame(height: 4)
                        Capsule().fill(Palette.ink.opacity(0.10)).frame(width: 9, height: 4)
                        Capsule().fill(Palette.ink.opacity(0.10)).frame(width: 11, height: 4)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
                    .frame(width: 22)
                    .overlay(alignment: .trailing) {
                        if !theme.isGlass { Rectangle().fill(Palette.hairline).frame(width: 1) }
                    }
                    RoundedRectangle(cornerRadius: theme.isGlass ? 3 : 0, style: .continuous)
                        .fill(Palette.ground)
                        .shadow(color: .black.opacity(theme.isGlass ? 0.15 : 0), radius: 1.5, y: 0.5)
                        .padding(.vertical, theme.isGlass ? 3 : 0)
                        .padding(.trailing, theme.isGlass ? 3 : 0)
                }
            }
        }
    }
}

/// On or off, in ink rather than in blue.
struct Switch: View {
    @Binding var on: Bool

    var body: some View {
        Capsule()
            .fill(on ? Palette.ink : Palette.faint)
            .frame(width: 30, height: 18)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(Palette.ground)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    .padding(2)
            }
            .contentShape(Capsule())
            .onTapGesture { withAnimation(Motion.settle) { on.toggle() } }
            .animation(Motion.settle, value: on)
    }
}

/// A small capsule that does one thing. Outlined by default; filled in ink
/// when it is the thing you came here to press.
struct Pill: View {
    let title: String
    var filled = false
    var tint: Color = Palette.ink
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, filled: Bool = false, tint: Color = Palette.ink, action: @escaping () -> Void) {
        self.title = title
        self.filled = filled
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(filled ? Palette.ground : tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(filled ? Palette.ink : (hovering ? Palette.hover : Palette.ground), in: Capsule())
                .overlay(Capsule().strokeBorder(filled ? .clear : Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}
