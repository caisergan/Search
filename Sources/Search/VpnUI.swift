import AppKit
import SwiftUI
import UniformTypeIdentifiers

// What the VPN looks like: a shield beside the downloads once a server is set
// up, the panel it opens — the power button, where the tunnel comes out, how
// much has gone through it — and its page in Settings. The engine is in
// Vpn.swift.

// MARK: - colours

/// The tunnel's own colours, the one place in the app that has them: on is
/// a green going to teal, working a violet, trouble an amber. Everything
/// else is the app's ink and hairlines.
enum VpnTint {
    static let on = LinearGradient(colors: [Color(hex: 0x34D399), Color(hex: 0x06B6D4)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let busy = LinearGradient(colors: [Color(hex: 0x818CF8), Color(hex: 0xA855F7)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let trouble = LinearGradient(colors: [Color(hex: 0xFBBF24), Color(hex: 0xF97316)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let brand = LinearGradient(colors: [Color(hex: 0x6366F1), Color(hex: 0x06B6D4)], startPoint: .topLeading, endPoint: .bottomTrailing)

    static let green = Color(hex: 0x10B981)
    static let violet = Color(hex: 0x8B5CF6)
    static let amber = Color(hex: 0xF59E0B)
    static let down = Color(hex: 0x06B6D4)
    static let up = Color(hex: 0xA855F7)
}

/// The four things the tunnel can look like.
enum VpnLook: Equatable {
    case off, on, busy, trouble

    init(_ phase: Vpn.Phase) {
        switch phase {
        case .off: self = .off
        case .on: self = .on
        case .connecting, .reconnecting: self = .busy
        case .failed: self = .trouble
        }
    }

    var tint: Color {
        switch self {
        case .on: return VpnTint.green
        case .busy: return VpnTint.violet
        case .trouble: return VpnTint.amber
        case .off: return Palette.muted
        }
    }

    var gradient: LinearGradient? {
        switch self {
        case .on: return VpnTint.on
        case .busy: return VpnTint.busy
        case .trouble: return VpnTint.trouble
        case .off: return nil
        }
    }

    var word: String {
        switch self {
        case .on: return "ON"
        case .off: return "OFF"
        case .busy: return "WAIT"
        case .trouble: return "BLOCKED"
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

enum VpnBytes {
    static func text(_ count: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
            .replacingOccurrences(of: "Zero", with: "0")
    }

    static func rate(_ perSecond: Double) -> String {
        perSecond < 1 ? "0 KB/s" : text(perSecond) + "/s"
    }
}

// MARK: - the button

/// The shield beside the downloads, once a server is set up: grey off, green
/// on, turning while it connects, amber when pages are held back. A click
/// opens the panel.
struct VpnButton: View {
    @ObservedObject var vpn: Vpn = .shared
    var edge: Edge = .bottom
    @State private var hovering = false
    @State private var angle: Double = 0
    /// This window's: another window's button doesn't open with it.
    @State private var open = false

    private var look: VpnLook { VpnLook(vpn.phase) }

    private var symbol: String {
        switch look {
        case .on: return "bolt.shield.fill"
        case .off: return "bolt.shield"
        case .busy: return "shield"
        case .trouble: return "exclamationmark.shield.fill"
        }
    }

    var body: some View {
        Button { open.toggle() } label: {
            ZStack {
                if look == .busy {
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(VpnTint.violet, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .rotationEffect(.degrees(angle))
                        .frame(width: 19, height: 19)
                        .onAppear {
                            angle = 0
                            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { angle = 360 }
                        }
                }
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(look == .off ? (hovering || open ? Palette.ink : Palette.muted) : look.tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(open ? Palette.wash : (hovering ? Palette.hover : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(Motion.quick, value: hovering)
        .animation(Motion.settle, value: look)
        .popover(isPresented: $open, arrowEdge: edge) {
            VpnPanel(vpn: vpn, meter: vpn.meter) { open = false }
        }
    }

    private var help: String {
        switch vpn.phase {
        case .off: return "VPN is off"
        case .on: return "VPN is on — Search's pages go through \(vpn.server.host)"
        case .connecting: return "VPN connecting…"
        case .reconnecting: return "VPN reconnecting…"
        case .failed(let why): return "VPN couldn't connect: \(why)"
        }
    }
}

// MARK: - the panel

struct VpnPanel: View {
    @ObservedObject var vpn: Vpn
    @ObservedObject var meter: VpnMeter
    var close: () -> Void = {}

    private var look: VpnLook { VpnLook(vpn.phase) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, 4)

            VpnPower(look: look) { vpn.toggle() }

            status
                .padding(.bottom, 14)

            VStack(spacing: 10) {
                if case .failed(let why) = vpn.phase {
                    VpnNotice(symbol: "exclamationmark.triangle.fill", tint: VpnTint.amber,
                              text: "\(why). Pages aren't loading until it connects or the VPN is turned off — nothing goes around it.",
                              actions: [("Try again", vpn.tryAgain), ("Turn off", vpn.turnOff)])
                }
                if vpn.late, vpn.phase != .off {
                    VpnNotice(symbol: "exclamationmark.circle", tint: VpnTint.amber,
                              text: "Sites opened before the VPN was set up may keep their connections straight out until they close them. Restart Search to be sure.")
                }
                if vpn.phase == .reconnecting {
                    VpnNotice(symbol: "arrow.triangle.2.circlepath", tint: VpnTint.violet,
                              text: "The tunnel dropped. Pages wait for it rather than go around it.")
                }
                if vpn.phase != .off {
                    usage
                    tiles
                    if !meter.sites.isEmpty { sites }
                }
            }
            .padding(.bottom, 12)

            Rectangle().fill(Palette.hairline).frame(height: 1)
                .padding(.bottom, 8)

            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(width: 310)
        .background(Palette.ground)
        .animation(Motion.settle, value: look)
        .animation(Motion.settle, value: meter.sites.map(\.site))
        // Measured while the panel is open; opening it measures at once.
        .task(id: vpn.isOn) {
            while !Task.isCancelled, vpn.isOn {
                await vpn.measure()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(VpnTint.brand)
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Hysteria 2")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(vpn.server.host)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            VpnPill(look: look)
        }
    }

    private var title: String {
        switch vpn.phase {
        case .off: return "Not connected"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .on: return "Connected"
        case .failed: return "Couldn't connect"
        }
    }

    private var status: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .contentTransition(.opacity)
            Group {
                if vpn.phase == .on, let since = vpn.since {
                    Text(since, style: .timer).monospacedDigit()
                } else if vpn.phase == .connecting {
                    Text("Shaking hands with the server")
                } else if vpn.phase == .off {
                    Text("Only Search's pages go through it — not the rest of the Mac")
                } else {
                    Text(" ")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.muted)
            .multilineTextAlignment(.center)
        }
    }

    // MARK: usage

    private var usage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                rate("arrow.down", VpnBytes.rate(meter.rate.down), VpnTint.down)
                rate("arrow.up", VpnBytes.rate(meter.rate.up), VpnTint.up)
                Spacer(minLength: 0)
                Text(meter.connections == 1 ? "1 connection" : "\(meter.connections) connections")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
            }
            VpnGraph(samples: meter.samples)
                .frame(height: 46)
        }
        .padding(10)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func rate(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }

    private var tiles: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                VpnTile(symbol: "network", title: "Exit IP", value: vpn.exit?.ip)
                VpnTile(symbol: "mappin.and.ellipse", title: "Location", value: vpn.exit.map { "\($0.flag) \($0.place)" })
            }
            GridRow {
                VpnTile(symbol: "gauge.with.dots.needle.67percent", title: "Latency",
                        value: vpn.latency.map { "\($0) ms" }, tint: latencyTint)
                VpnTile(symbol: "arrow.up.arrow.down", title: "This session",
                        value: vpn.phase == .off ? nil : VpnBytes.text(Double(meter.down + meter.up)))
            }
            GridRow {
                VpnTile(symbol: "arrow.up.arrow.down.circle", title: "Down · up",
                        value: "\(VpnBytes.text(Double(meter.down))) · \(VpnBytes.text(Double(meter.up)))")
                VpnTile(symbol: "calendar", title: "This month", value: VpnBytes.text(Double(meter.month)))
            }
        }
    }

    private var latencyTint: Color? {
        guard let ms = vpn.latency else { return nil }
        return ms < 200 ? VpnTint.green : ms < 400 ? VpnTint.amber : .red
    }

    private var sites: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sites this session")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.muted)
            let most = Double(meter.sites.first?.bytes ?? 1)
            ForEach(meter.sites, id: \.site) { entry in
                HStack(spacing: 8) {
                    Text(entry.site)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(VpnBytes.text(Double(entry.bytes)))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Palette.muted)
                        .monospacedDigit()
                }
                .background(alignment: .leading) {
                    GeometryReader { box in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(VpnTint.down.opacity(0.12))
                            .frame(width: max(4, box.size.width * Double(entry.bytes) / most))
                            .padding(.vertical, -2)
                            .padding(.leading, -4)
                    }
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("Search only — the Mac stays direct")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.muted)
            Spacer()
            Door(icon: "doc.text.magnifyingglass", help: "Hysteria's log") { vpn.openLog() }
            Door(icon: "gearshape", help: "VPN settings") {
                close()
                Store.settings.set(SettingsPanel.Page.vpn.rawValue, forKey: "settings.page")
                Browser.front?.tuning = true
            }
        }
    }
}

/// The big round button, as in the menu bar's: grey off, glowing on,
/// a ring going round while it connects.
struct VpnPower: View {
    let look: VpnLook
    let act: () -> Void

    private let core: CGFloat = 84
    private let ring: CGFloat = 106

    var body: some View {
        Button(action: act) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: look == .off)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    if let gradient = look.gradient {
                        Circle()
                            .fill(gradient)
                            .frame(width: ring + 8, height: ring + 8)
                            .blur(radius: 24)
                            .opacity(look == .on ? 0.3 + 0.12 * sin(t * 1.8) : 0.26)
                    }
                    Circle()
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                        .frame(width: ring, height: ring)
                    if look == .busy {
                        Circle()
                            .trim(from: 0, to: 0.3)
                            .stroke(AngularGradient(colors: [VpnTint.violet.opacity(0), VpnTint.violet], center: .center,
                                                    startAngle: .zero, endAngle: .degrees(108)),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: ring - 2, height: ring - 2)
                            .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1.1) / 1.1 * 360))
                    } else if look != .off {
                        Circle()
                            .strokeBorder(look.tint.opacity(0.45), lineWidth: 2)
                            .frame(width: ring, height: ring)
                    }
                    face
                }
            }
            .frame(width: 136, height: 136)
            .contentShape(Circle())
        }
        .buttonStyle(VpnPress())
        .help(look == .off ? "Connect" : "Disconnect")
    }

    private var face: some View {
        ZStack {
            if let gradient = look.gradient {
                Circle().fill(gradient)
                Circle().fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
            } else {
                Circle().fill(Palette.wash)
                Circle().strokeBorder(Palette.hairline, lineWidth: 1)
            }
            Image(systemName: "power")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(look == .off ? AnyShapeStyle(Palette.muted) : AnyShapeStyle(.white))
                .shadow(color: .black.opacity(look == .off ? 0 : 0.15), radius: 2, y: 1)
        }
        .frame(width: core, height: core)
        .shadow(color: look.tint.opacity(look == .off ? 0 : 0.42), radius: 12, y: 5)
    }
}

private struct VpnPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct VpnPill: View {
    let look: VpnLook

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(look.tint).frame(width: 6, height: 6)
            Text(look.word).font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(look.tint)
        .background(Capsule().fill(look.tint.opacity(0.13)))
    }
}

private struct VpnTile: View {
    let symbol: String
    let title: String
    let value: String?
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                Text(title)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Palette.muted)
            Group {
                if let value {
                    Text(value).foregroundStyle(tint ?? Palette.ink)
                } else {
                    Text("—").foregroundStyle(Palette.faint)
                }
            }
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The last minute, down as a filled area and up as a line over it, on one
/// scale so that the two compare.
private struct VpnGraph: View {
    let samples: [VpnMeter.Sample]

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            let top = max(samples.map { max($0.down, $0.up) }.max() ?? 0, 16_384)
            let step = size.width / CGFloat(samples.count - 1)
            func point(_ index: Int, _ value: Double) -> CGPoint {
                CGPoint(x: CGFloat(index) * step, y: size.height - 1 - CGFloat(value / top) * (size.height - 3))
            }
            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))
            for (index, sample) in samples.enumerated() { area.addLine(to: point(index, sample.down)) }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [VpnTint.down.opacity(0.45), VpnTint.down.opacity(0.04)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            var downLine = Path()
            var upLine = Path()
            for (index, sample) in samples.enumerated() {
                if index == 0 {
                    downLine.move(to: point(index, sample.down))
                    upLine.move(to: point(index, sample.up))
                } else {
                    downLine.addLine(to: point(index, sample.down))
                    upLine.addLine(to: point(index, sample.up))
                }
            }
            context.stroke(downLine, with: .color(VpnTint.down), lineWidth: 1.4)
            context.stroke(upLine, with: .color(VpnTint.up), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct VpnNotice: View {
    let symbol: String
    let tint: Color
    let text: String
    var actions: [(String, () -> Void)] = []

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !actions.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(actions.indices, id: \.self) { index in
                            Button(actions[index].0, action: actions[index].1)
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(tint)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.22), lineWidth: 1))
    }
}

// MARK: - Settings › VPN

struct VpnSettings: View {
    @ObservedObject private var vpn = Vpn.shared
    @State private var draft = Vpn.shared.server
    @State private var showsSecrets = false

    private var changed: Bool { draft != vpn.server }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("Search's own VPN", statusDetail) {
                    Switch(on: Binding(get: { vpn.phase != .off }, set: { $0 ? vpn.turnOn() : vpn.turnOff() }))
                        .disabled(!vpn.configured)
                        .opacity(vpn.configured ? 1 : 0.45)
                }
                Rule()
                Line("Connect when Search opens", "Before the first page loads, so none of them goes around it") {
                    Switch(on: Binding(get: { vpn.atLaunch }, set: { vpn.atLaunch = $0 }))
                }
            }

            HStack {
                Caption("Hysteria 2 server")
                Spacer()
                Pill("Import client.yaml…") { importConfig() }
                    .help("Fill these in from a Hysteria client config you already have")
            }
            Card {
                field("Server", "host:port", text: $draft.server)
                Rule()
                field("Password", "auth", text: $draft.auth, secret: true)
                Rule()
                field("Certificate name", "SNI — when it isn't the server's host", text: $draft.sni)
                Rule()
                Line("Certificate authority", draft.ca.isEmpty ? "A CA file to trust, for a server with a certificate of its own" : draft.ca) {
                    HStack(spacing: 6) {
                        if !draft.ca.isEmpty { Pill("Clear") { draft.ca = "" } }
                        Pill("Choose…") { chooseCA() }
                    }
                }
                Rule()
                field("Pinned SHA-256", "The server certificate's fingerprint", text: $draft.pin)
                Rule()
                Line("Skip the certificate check", "Only for testing: anyone in between could read the tunnel") {
                    Switch(on: $draft.insecure)
                }
                Rule()
                field("Obfuscation password", "Salamander — leave empty for none", text: $draft.obfs, secret: true)
                Rule()
                Line("Bandwidth", "Mbps up and down for Brutal, a little under the line's real rate. Empty for BBR") {
                    HStack(spacing: 6) {
                        small("up", text: $draft.up)
                        small("down", text: $draft.down)
                    }
                }
            }
            HStack(spacing: 8) {
                if vpn.configured {
                    Pill("Forget this server", tint: .red) {
                        draft = VpnServer()
                        vpn.use(VpnServer())
                    }
                }
                Spacer()
                if changed {
                    Pill("Revert") { draft = vpn.server }
                    Pill(vpn.phase == .off ? "Save" : "Save and reconnect", filled: true) { vpn.use(draft) }
                        .disabled(!draft.configured && !vpn.configured)
                }
            }
            .animation(Motion.quick, value: changed)

            Caption("Hysteria")
            Card {
                Line("The client program", Vpn.program ?? "Not found — brew install hysteria") {
                    HStack(spacing: 6) {
                        if Store.settings.string(forKey: "vpn.program") != nil { Pill("Default") { vpn.pickProgram(nil) } }
                        Pill("Choose…") { chooseProgram() }
                    }
                }
                Rule()
                Line("How it works", "Search starts its own Hysteria client and sends only its pages through it, by a proxy on loopback. Other apps, and the rest of the Mac, keep their own connection. While it's on, a page that can't reach the tunnel fails rather than going around it") {
                    Pill("Log") { vpn.openLog() }
                }
            }
        }
        .onChange(of: vpn.server) { _, saved in draft = saved }
    }

    private var statusDetail: String {
        guard vpn.configured else { return "Set up a server below first" }
        switch vpn.phase {
        case .off: return "Off — pages go straight out"
        case .connecting: return "Connecting to \(vpn.server.host)…"
        case .reconnecting: return "Reconnecting to \(vpn.server.host)…"
        case .on: return "On — pages go through \(vpn.server.host)" + (vpn.exit.map { $0.ip == vpn.server.host ? "" : ", out at \($0.ip)" } ?? "")
        case .failed(let why): return why
        }
    }

    private func field(_ title: String, _ hint: String, text: Binding<String>, secret: Bool = false) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13)).foregroundStyle(Palette.ink)
                Text(hint).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Group {
                    if secret, !showsSecrets {
                        SecureField("", text: text)
                    } else {
                        TextField("", text: text)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                if secret {
                    Button { showsSecrets.toggle() } label: {
                        Image(systemName: showsSecrets ? "eye.slash" : "eye")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                    }
                    .buttonStyle(.plain)
                    .help(showsSecrets ? "Hide" : "Show")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 250)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func small(_ hint: String, text: Binding<String>) -> some View {
        ZStack(alignment: .leading) {
            if text.wrappedValue.isEmpty {
                Text(hint).foregroundStyle(Palette.muted.opacity(0.8))
            }
            TextField("", text: text)
                .textFieldStyle(.plain)
                .foregroundStyle(Palette.ink)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(width: 64)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.title = "A Hysteria client config"
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml"), UTType(filenameExtension: "yml"), .plainText].compactMap { $0 }
        let usual = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("hysteria")
        if FileManager.default.fileExists(atPath: usual.path) { panel.directoryURL = usual }
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let found = VpnServer.reading(yaml: text)
        guard found.configured else {
            Browser.front?.announce("No server in that file")
            return
        }
        draft = found
    }

    private func chooseCA() {
        let panel = NSOpenPanel()
        panel.title = "The server's certificate authority"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.ca = url.path
    }

    private func chooseProgram() {
        let panel = NSOpenPanel()
        panel.title = "The hysteria program"
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vpn.pickProgram(url.path)
    }
}
