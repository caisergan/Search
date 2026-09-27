import Combine
import SwiftUI
import UniformTypeIdentifiers

// What the window shows of Downloads.swift.
//
// A button beside the extensions, there from the first download on: a ring
// round its arrow fills as everything coming in comes in, a count sits on it
// while more than one does, and it turns to a tick when the last one lands —
// or shakes, red, when one fails. The file's icon flies to it from where you
// clicked, so a download is seen starting and seen going somewhere. Pressed,
// it lists the last few, each with its bar, its pace and its time left, to
// pause, cancel, open, drag out or find. ⇧⌘J is the page of all of them.

// MARK: - words and numbers

enum Bytes {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        // "0 bytes", not "Zero KB".
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func text(_ count: Int64) -> String {
        formatter.string(fromByteCount: max(0, count))
    }

    /// "18 s left", "3 min left", "1 h 5 min left".
    static func left(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        if s < 60 { return "\(max(1, s)) s left" }
        if s < 3600 { return "\(Int((Double(s) / 60).rounded())) min left" }
        return "\(s / 3600) h \((s % 3600) / 60) min left"
    }

    /// "12.4 of 80 MB" — "900 KB of 80 MB" when the two aren't counted in
    /// the same unit — or just what has come while the size isn't known.
    @MainActor static func progress(_ item: Download) -> String {
        guard item.expected > 0 else { return text(item.received) }
        let got = text(item.received)
        let whole = text(item.expected)
        let (number, unit) = split(got)
        return unit == split(whole).unit ? "\(number) of \(whole)" : "\(got) of \(whole)"
    }

    private static func split(_ text: String) -> (number: String, unit: String) {
        guard let space = text.lastIndex(of: " ") else { return (text, "") }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }

    /// The line under a download's name.
    @MainActor static func status(_ item: Download, when: Bool = false) -> String {
        switch item.state {
        case .starting:
            return item.received > 0 ? "Resuming…" : "Starting…"
        case .running:
            var parts = [progress(item)]
            if item.speed > 1 { parts.append("\(text(Int64(item.speed)))/s") }
            if let left = item.remaining { parts.append(Bytes.left(left)) }
            return parts.joined(separator: " · ")
        case .paused:
            let over = item.resumeData == nil && item.received > 0 ? " · starts over" : ""
            return "Paused · \(progress(item))\(over)"
        case .done:
            guard item.there else { return "Moved or deleted" }
            var parts = [text(item.received)]
            if !item.host.isEmpty { parts.append(item.host) }
            if when, let finished = item.finished { parts.append(When.clock(finished)) }
            return parts.joined(separator: " · ")
        case .failed(let why):
            return "Failed · \(why)"
        case .cancelled:
            return "Cancelled"
        }
    }
}

// MARK: - where the button is, and what flies to it

@MainActor
final class Arrivals: ObservableObject {
    static let shared = Arrivals()

    /// The list hanging from the button.
    @Published var listOpen = false
    /// Something was downloaded since Search opened: the button stays.
    @Published private(set) var seen = false
    /// Icons on their way to the button.
    @Published private(set) var trips: [Trip] = []
    /// Counts up as each lands, for the button to take it.
    @Published private(set) var landings = 0
    /// The last to end, when it was the last one coming in or it failed.
    @Published private(set) var finale: Finale?

    struct Trip: Identifiable {
        let id = UUID()
        /// The download it stands for.
        let item: UUID
        let icon: NSImage
        let from: CGPoint
        let to: CGPoint
    }

    struct Finale: Equatable {
        let id = UUID()
        let ok: Bool
    }

    /// The button, in the window's own points from its top left corner —
    /// where the pointer is measured from too — while one is on screen.
    var target: CGRect?

    private var bag = Set<AnyCancellable>()

    private init() {
        seen = Downloads.shared.count > 0 || Downloads.shared.held > 0
        Downloads.shared.began.sink { [weak self] in self?.launch($0) }.store(in: &bag)
        Downloads.shared.ended.sink { [weak self] in self?.end($0) }.store(in: &bag)
    }

    /// The button's place, when it is somewhere in the window a flight can
    /// reach: not folded away with the column, not yet to be measured.
    private var landing: CGRect? {
        guard let target, target.width > 0, let content = Links.window?.contentView else { return nil }
        return content.bounds.intersects(target) ? target : nil
    }

    private var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// From where the pointer is, if it is over the window — the link just
    /// clicked, most of the time — or from the middle of it.
    private var takeoff: CGPoint? {
        guard let window = Links.window, let content = window.contentView else { return nil }
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let size = content.bounds.size
        guard content.bounds.contains(point) else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        return CGPoint(x: point.x, y: size.height - point.y)
    }

    private func launch(_ item: Download) {
        let first = !seen
        seen = true
        let icon = FileIcon.byType(item.name)
        let id = item.id
        leaving.insert(id)
        // The button may only now be coming in: its place is known a
        // moment after.
        DispatchQueue.main.asyncAfter(deadline: .now() + (first ? 0.08 : 0)) { [self] in
            leaving.remove(id)
            guard let to = landing else {
                Downloads.shared.browser?.announce("Downloading \(item.name)")
                release(id)
                return
            }
            let end = CGPoint(x: to.midX, y: to.midY)
            guard !still, let from = takeoff, hypot(from.x - end.x, from.y - end.y) > 60 else {
                landings += 1
                release(id)
                return
            }
            trips.append(Trip(item: id, icon: icon, from: from, to: end))
        }
    }

    /// Downloads about to take off, for the moment before their flight
    /// begins.
    private var leaving: Set<UUID> = []

    /// A finale held for a flight that never went.
    private func release(_ id: UUID) {
        if let finale = waiting.removeValue(forKey: id) { self.finale = finale }
    }

    /// A finale for a download whose icon is still on its way: shown when
    /// it lands, not while it is in the air.
    private var waiting: [UUID: Finale] = [:]

    func land(_ trip: Trip) {
        trips.removeAll { $0.id == trip.id }
        landings += 1
        if let finale = waiting.removeValue(forKey: trip.item) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [self] in self.finale = finale }
        }
    }

    private func conclude(_ item: Download, ok: Bool) {
        if leaving.contains(item.id) || trips.contains(where: { $0.item == item.id }) {
            waiting[item.id] = Finale(ok: ok)
        } else {
            finale = Finale(ok: ok)
        }
    }

    private func end(_ item: Download) {
        switch item.state {
        case .done:
            if Downloads.shared.count == 0 { conclude(item, ok: true) }
            if landing == nil { Downloads.shared.browser?.announce("Saved \(item.name)") }
        case .failed:
            conclude(item, ok: false)
            if landing == nil { Downloads.shared.browser?.announce("\(item.name) couldn't be downloaded") }
        default:
            break
        }
    }
}

/// The icons in flight, over everything but the panels.
struct Flights: View {
    @ObservedObject var arrivals: Arrivals = .shared

    var body: some View {
        GeometryReader { proxy in
            let here = proxy.frame(in: .global).origin
            ForEach(arrivals.trips) { trip in
                Flight(trip: trip, here: here) { arrivals.land(trip) }
            }
        }
        .allowsHitTesting(false)
    }

    private struct Flight: View {
        let trip: Arrivals.Trip
        let here: CGPoint
        let landed: () -> Void
        @State private var t: CGFloat = 0

        var body: some View {
            Image(nsImage: trip.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.2), radius: 7, y: 3)
                .modifier(Arc(
                    t: t,
                    from: CGPoint(x: trip.from.x - here.x, y: trip.from.y - here.y),
                    to: CGPoint(x: trip.to.x - here.x, y: trip.to.y - here.y)
                ))
                .onAppear {
                    // Quick off the page, slowing as it comes in to land.
                    withAnimation(.timingCurve(0.45, 0, 0.25, 1, duration: 0.72)) { t = 1 } completion: { landed() }
                }
        }
    }

    /// Up out of the page, then over and into the button: a thrown thing's
    /// curve. It swells as it leaves and shrinks to the button's size as it
    /// arrives, fading in at the start and out on landing.
    private struct Arc: ViewModifier, Animatable {
        var t: CGFloat
        let from: CGPoint
        let to: CGPoint

        var animatableData: CGFloat {
            get { t }
            set { t = newValue }
        }

        func body(content: Content) -> some View {
            let lift = CGPoint(x: from.x + (to.x - from.x) * 0.2, y: max(8, min(from.y, to.y) - 90))
            let u = 1 - t
            let x = u * u * from.x + 2 * u * t * lift.x + t * t * to.x
            let y = u * u * from.y + 2 * u * t * lift.y + t * t * to.y
            let scale = t < 0.18 ? 0.6 + t / 0.18 * 0.5 : 1.1 - (t - 0.18) / 0.82 * 0.72
            let opacity = t < 0.08 ? t / 0.08 : (t > 0.9 ? max(0, (1 - t) / 0.1) : 1)
            content
                .scaleEffect(scale)
                .opacity(opacity)
                .position(x: x, y: y)
        }
    }
}

// MARK: - the button

struct DownloadsButton: View {
    @ObservedObject var downloads: Downloads = .shared
    @ObservedObject var arrivals: Arrivals = .shared
    var edge: Edge = .bottom

    @State private var hovering = false
    @State private var pulse = false
    @State private var ending: Arrivals.Finale?
    @State private var shake: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var still

    /// From the first download on, and while anything waits to be picked
    /// up again.
    static func shown(_ downloads: Downloads, _ arrivals: Arrivals) -> Bool {
        arrivals.seen || downloads.count > 0 || downloads.held > 0 || arrivals.listOpen
    }

    var body: some View {
        let shown = DownloadsButton.shown(downloads, arrivals)
        ZStack {
            if shown {
                button
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .animation(Motion.settle, value: shown)
    }

    private var ringed: Bool { downloads.count > 0 || ending != nil }

    private var symbol: String {
        switch ending?.ok {
        case true: return "checkmark"
        case false: return "exclamationmark"
        default: return "arrow.down"
        }
    }

    private var tint: Color {
        switch ending?.ok {
        case true: return Palette.safe
        case false: return Color.red.opacity(0.85)
        default: return ringed || hovering || arrivals.listOpen ? Palette.ink : Palette.muted
        }
    }

    private var button: some View {
        Button { arrivals.listOpen.toggle() } label: {
            ZStack {
                if downloads.count > 0, ending == nil {
                    Circle().stroke(Palette.faint, lineWidth: 1.6)
                    if let whole = downloads.overall {
                        Circle()
                            .trim(from: 0, to: max(0.03, whole))
                            .stroke(Palette.ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.25), value: whole)
                    } else {
                        Sweep()
                    }
                }
                if let ending {
                    Circle()
                        .stroke(ending.ok ? Palette.safe : Color.red.opacity(0.85), lineWidth: 1.6)
                        .transition(.opacity)
                }
                Image(systemName: symbol)
                    .font(.system(size: ringed ? 8 : 11, weight: ringed ? .bold : .medium))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 17, height: 17)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(arrivals.listOpen ? Palette.wash : (hovering ? Palette.hover : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomTrailing) {
            if downloads.count > 1 {
                Text("\(downloads.count)")
                    .font(.system(size: 8, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 12, minHeight: 11)
                    .background(Palette.ink, in: Capsule())
                    .fixedSize()
                    .offset(x: 3, y: 2)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .scaleEffect(pulse ? 1.22 : 1)
        .modifier(Shake(travel: shake))
        .onHover { hovering = $0 }
        .help("Downloads   ⇧⌘J for all of them")
        .animation(Motion.quick, value: hovering)
        .animation(Motion.settle, value: downloads.count)
        .animation(Motion.settle, value: ending)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            arrivals.target = $0
        }
        .onDisappear { arrivals.target = nil }
        .onChange(of: arrivals.landings) { _, _ in bump() }
        .onChange(of: arrivals.finale) { _, finale in finish(finale) }
        .popover(isPresented: $arrivals.listOpen, arrowEdge: edge) {
            DownloadsList(downloads: downloads, arrivals: arrivals)
        }
    }

    /// Something landed: the button takes it with a small jump.
    private func bump() {
        guard !still else { return }
        withAnimation(.spring(response: 0.16, dampingFraction: 0.5)) { pulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { pulse = false }
        }
    }

    /// The tick, or the shake, for a moment — then the arrow again.
    private func finish(_ finale: Arrivals.Finale?) {
        guard let finale else { return }
        ending = finale
        if finale.ok {
            bump()
        } else if !still {
            var now = Transaction()
            now.disablesAnimations = true
            withTransaction(now) { shake = 0 }
            withAnimation(.linear(duration: 0.45)) { shake = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if ending == finale { ending = nil }
        }
    }

    /// A download that hasn't said how big it is: a short arc going round.
    private struct Sweep: View {
        @State private var angle: Double = 0

        var body: some View {
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(Palette.ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(angle))
                .onAppear {
                    withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { angle = 360 }
                }
        }
    }
}

/// The downloads button beside the extensions, the extensions given the
/// room it leaves them.
struct DownloadsAndExtensions: View {
    var edge: Edge = .bottom
    var always = false
    var room = Int.max
    @ObservedObject var downloads: Downloads = .shared
    @ObservedObject var arrivals: Arrivals = .shared

    var body: some View {
        HStack(spacing: 2) {
            DownloadsButton(edge: edge)
            let taken = DownloadsButton.shown(downloads, arrivals) && room != .max ? 1 : 0
            ExtensionSlot(edge: edge, always: always, room: max(0, room - taken))
        }
    }
}

// MARK: - the list from the button

struct DownloadsList: View {
    @ObservedObject var downloads: Downloads
    @ObservedObject var arrivals: Arrivals

    /// The last few; the rest are on the page.
    private var recent: [Download] { Array(downloads.items.prefix(6)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Downloads")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                if downloads.count > 0 {
                    Text(downloads.count == 1 ? "1 in progress" : "\(downloads.count) in progress")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 4)

            if recent.isEmpty {
                Text("Nothing downloaded yet.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            } else {
                VStack(spacing: 1) {
                    ForEach(recent) { item in
                        DownloadRow(item: item)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(6)
                .animation(Motion.settle, value: recent.map(\.id))
            }

            Divider().overlay(Palette.hairline)
            VStack(spacing: 1) {
                Foot("list.bullet", "Show All Downloads", keys: "⇧⌘J") {
                    arrivals.listOpen = false
                    downloads.browser?.hoarding = true
                }
                Foot("folder", "Open Downloads Folder") {
                    arrivals.listOpen = false
                    if let folder = downloads.browser?.downloadsFolder { NSWorkspace.shared.open(folder) }
                }
            }
            .padding(6)
        }
        .frame(width: 350)
        .background(Palette.ground)
        .animation(Motion.settle, value: downloads.count)
    }

    private struct Foot: View {
        let symbol: String
        let title: String
        var keys = ""
        let act: () -> Void
        @State private var hovering = false

        init(_ symbol: String, _ title: String, keys: String = "", act: @escaping () -> Void) {
            self.symbol = symbol
            self.title = title
            self.keys = keys
            self.act = act
        }

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

/// The list from the button, drawn off screen, for a test run's picture of it.
@MainActor func downloadsListPicture() -> NSBitmapImageRep? {
    let host = NSHostingView(rootView: DownloadsList(downloads: .shared, arrivals: .shared))
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSApp.effectiveAppearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: picture)
    return picture
}

// MARK: - one download

/// A download as a line: its icon, its name, its bar while it comes in, and
/// what can be done with it. The same in the list and on the page.
struct DownloadRow: View {
    @ObservedObject var item: Download
    var downloads: Downloads = .shared
    /// On the page: roomier, and with the time it came.
    var roomy = false

    @State private var hovering = false
    @State private var flash = false

    var body: some View {
        HStack(spacing: 11) {
            FileIcon(item: item, size: roomy ? 32 : 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 13))
                    .foregroundStyle(faded ? Palette.muted : Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.active || item.state == .paused {
                    Bar(fraction: item.state == .starting ? nil : item.fraction, paused: item.state == .paused)
                        .padding(.vertical, 2)
                        .transition(.opacity)
                }
                Text(Bytes.status(item, when: roomy))
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(item.failed ? Color.red.opacity(0.8) : Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            tools
        }
        .padding(.leading, roomy ? 14 : 8)
        .padding(.trailing, roomy ? 12 : 6)
        .padding(.vertical, roomy ? 9 : 7)
        .background(
            RoundedRectangle(cornerRadius: roomy ? 0 : 8, style: .continuous)
                .fill(flash ? Palette.safe.opacity(0.13) : (hovering ? (roomy ? Palette.hover : Palette.wash) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { if item.state == .done { downloads.open(item) } }
        .modifier(FileDrag(file: item.state == .done && item.there ? item.file : nil))
        .onHover { hovering = $0 }
        .contextMenu { DownloadActions(item: item, downloads: downloads) }
        .help(item.state == .done && item.there ? "Click to open, or drag it where it should go" : item.name)
        .animation(Motion.quick, value: hovering)
        .animation(Motion.settle, value: item.state)
        .onChange(of: item.state) { _, state in
            // Landed: the line lights up, then settles.
            guard state == .done else { return }
            withAnimation(.easeOut(duration: 0.15)) { flash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                withAnimation(.easeOut(duration: 0.6)) { flash = false }
            }
        }
    }

    private var faded: Bool {
        item.state == .cancelled || item.failed || (item.state == .done && !item.there)
    }

    @ViewBuilder
    private var tools: some View {
        HStack(spacing: 2) {
            switch item.state {
            case .starting:
                Tool(symbol: "xmark", help: "Cancel") { downloads.cancel(item) }
            case .running:
                Tool(symbol: "pause.fill", help: "Pause") { downloads.pause(item) }
                Tool(symbol: "xmark", help: "Cancel") { downloads.cancel(item) }
            case .paused:
                Tool(symbol: item.resumeData == nil ? "arrow.clockwise" : "play.fill",
                     help: item.resumeData == nil ? "Start again" : "Resume") { downloads.resume(item) }
                Tool(symbol: "xmark", help: "Cancel") { downloads.cancel(item) }
            case .failed, .cancelled:
                Tool(symbol: "arrow.clockwise", help: "Try again") { downloads.resume(item) }
                if hovering { Tool(symbol: "minus", help: "Remove from list") { downloads.remove(item) } }
            case .done:
                if hovering {
                    if item.there {
                        Tool(symbol: "magnifyingglass", help: "Show in Finder") { downloads.reveal(item) }
                    } else {
                        Tool(symbol: "minus", help: "Remove from list") { downloads.remove(item) }
                    }
                }
            }
        }
    }

    private struct Tool: View {
        let symbol: String
        let help: String
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(hovering ? Palette.wash : Palette.hover))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }
}

/// A finished file dragged out of the list, as the Finder would let it be.
private struct FileDrag: ViewModifier {
    let file: URL?

    func body(content: Content) -> some View {
        if let file {
            content.onDrag { NSItemProvider(contentsOf: file) ?? NSItemProvider() }
        } else {
            content
        }
    }
}

/// A right-click on a download.
struct DownloadActions: View {
    @ObservedObject var item: Download
    let downloads: Downloads

    var body: some View {
        if item.state == .done, item.there {
            Button("Open") { downloads.open(item) }
            Button("Show in Finder") { downloads.reveal(item) }
            Divider()
        }
        switch item.state {
        case .starting, .running:
            Button("Pause") { downloads.pause(item) }
            Button("Cancel") { downloads.cancel(item) }
            Divider()
        case .paused:
            Button(item.resumeData == nil ? "Start Again" : "Resume") { downloads.resume(item) }
            Button("Cancel") { downloads.cancel(item) }
            Divider()
        case .failed, .cancelled:
            Button("Try Again") { downloads.resume(item) }
            Divider()
        case .done:
            EmptyView()
        }
        if let source = item.source, !["blob", "data"].contains(source.scheme ?? "") {
            Button("Copy Download Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source.absoluteString, forType: .string)
            }
        }
        if let page = item.page, ["http", "https"].contains(page.scheme ?? "") {
            Button("Go to Page It Came From") {
                Arrivals.shared.listOpen = false
                downloads.browser?.hoarding = false
                downloads.browser?.open(page, foreground: true)
            }
        }
        Divider()
        Button("Remove from List") { downloads.remove(item) }
        if item.state == .done, item.there {
            Button("Move to Trash") { downloads.trash(item) }
        }
    }
}

/// The file's own icon once it is there; until then, its kind's.
struct FileIcon: View {
    @ObservedObject var item: Download
    var size: CGFloat = 30

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .opacity(dim ? 0.45 : 1)
            .saturation(dim ? 0 : 1)
    }

    private var dim: Bool {
        item.state == .cancelled || item.failed || (item.state == .done && !item.there)
    }

    private var image: NSImage {
        if item.state == .done, let file = item.file, item.there {
            return FileIcon.cached(file.path) { NSWorkspace.shared.icon(forFile: file.path) }
        }
        return FileIcon.byType(item.name)
    }

    private static var cache: [String: NSImage] = [:]

    private static func cached(_ key: String, _ make: () -> NSImage) -> NSImage {
        if let image = cache[key] { return image }
        let image = make()
        cache[key] = image
        return image
    }

    /// The icon macOS gives a file of this kind.
    static func byType(_ name: String) -> NSImage {
        let ext = (name as NSString).pathExtension.lowercased()
        return cached("." + ext) { NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data) }
    }
}

/// How far along, as a thin bar. Without a size, a short piece going to and
/// fro; paused, grey.
struct Bar: View {
    let fraction: Double?
    var paused = false
    @State private var sweep: CGFloat = 0

    var body: some View {
        GeometryReader { box in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.wash)
                if let fraction {
                    Capsule()
                        .fill(paused ? Palette.muted.opacity(0.55) : Palette.ink)
                        .frame(width: max(3, box.size.width * fraction))
                        .animation(.linear(duration: 0.25), value: fraction)
                } else {
                    Capsule()
                        .fill(Palette.ink.opacity(0.65))
                        .frame(width: box.size.width * 0.28)
                        .offset(x: box.size.width * 0.72 * sweep)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { sweep = 1 }
                        }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 3)
        .animation(Motion.quick, value: paused)
    }
}

// MARK: - the page

struct DownloadsPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var downloads: Downloads

    var body: some View {
        Plate("Downloads", width: 560, close: { browser.hoarding = false }) {
            if downloads.items.isEmpty {
                Card { Nothing("Nothing downloaded yet.") }
            } else {
                ScrollView(showsIndicators: false) {
                    Card {
                        ForEach(Array(downloads.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Rule() }
                            DownloadRow(item: item, roomy: true)
                        }
                    }
                    .padding(.bottom, 2)
                }
                .frame(maxHeight: 420)
            }
        } foot: {
            HStack {
                Text(downloads.items.isEmpty ? "Files land in \(browser.downloadsFolder.lastPathComponent)"
                     : "Clearing the list leaves the files where they are")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                Spacer()
                if !downloads.items.isEmpty {
                    Pill("Clear list") { downloads.clear() }
                }
            }
        }
    }
}
