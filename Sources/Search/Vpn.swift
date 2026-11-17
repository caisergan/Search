import AppKit
import Foundation
import Network
import WebKit

// The VPN: Search's pages, and only Search's pages, through a Hysteria 2
// tunnel. Not a VPN in the macOS sense — no interface, no routes, nothing the
// rest of the Mac notices. Search starts a `hysteria client` of its own with
// a SOCKS5 listener on loopback, and every WebKit store the browser uses is
// told to go through it (WKWebsiteDataStore.proxyConfigurations, macOS 14).
//
// Between WebKit and Hysteria sits a small SOCKS5 relay of ours, also on
// loopback, and once a server is set up the stores point at it whether the
// VPN is on or off. It decides where each connection goes — straight out,
// or through Hysteria — and that is what makes switching clean: WebKit keeps
// connections open between pages, and one opened straight out would carry
// on going straight out after the VPN came on. The relay ends those as it
// switches, and WebKit's next connection comes back through it the new way.
// It also keeps the tunnel shut when it should be: while the VPN is on and
// Hysteria isn't up, connections wait for it or are refused — a page fails
// rather than going around the tunnel. And it counts what goes through: how
// much, how fast, to which sites. Addresses on this Mac and its local
// network always go straight out: the server has no way to reach them.
//
// Calls are the exception a proxy can't carry: WebRTC — Discord's voice and
// video, Meet, any call in a page — sends UDP of its own, straight from
// WebKit, past any proxy. So while the VPN is on, every page's
// RTCPeerConnection is made relay-only, its relay a TURN server on the VPN
// server reached through the tunnel itself (Hysteria forwards a loopback UDP
// port to it). Calls come out where the pages do, and nothing of them goes
// around the tunnel: with no relay set up, they don't connect at all.

/// The server, as Hysteria's client config has it. Kept in a file of its own
/// readable only by this user (vpn.json), never in the settings that iCloud
/// carries to other Macs: the password is in it.
struct VpnServer: Codable, Equatable {
    /// host:port
    var server = ""
    var auth = ""
    /// The name the server's certificate is for, when it isn't the host.
    var sni = ""
    /// A certificate authority file to trust for the server.
    var ca = ""
    /// The server certificate's SHA-256, pinned.
    var pin = ""
    var insecure = false
    /// Salamander obfuscation's password; empty for none.
    var obfs = ""
    /// Brutal's rates in Mbps; both empty leaves Hysteria on BBR.
    var up = ""
    var down = ""
    /// The TURN relay for calls, as the server sees it: on the server's own
    /// loopback, reached through the tunnel. Empty: calls are blocked while
    /// the VPN is on.
    var turn = "127.0.0.1:3478"

    init() {}

    /// Any field missing from an older vpn.json takes its default, rather
    /// than the whole server failing to load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let blank = VpnServer()
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? blank.server
        auth = try c.decodeIfPresent(String.self, forKey: .auth) ?? blank.auth
        sni = try c.decodeIfPresent(String.self, forKey: .sni) ?? blank.sni
        ca = try c.decodeIfPresent(String.self, forKey: .ca) ?? blank.ca
        pin = try c.decodeIfPresent(String.self, forKey: .pin) ?? blank.pin
        insecure = try c.decodeIfPresent(Bool.self, forKey: .insecure) ?? blank.insecure
        obfs = try c.decodeIfPresent(String.self, forKey: .obfs) ?? blank.obfs
        up = try c.decodeIfPresent(String.self, forKey: .up) ?? blank.up
        down = try c.decodeIfPresent(String.self, forKey: .down) ?? blank.down
        turn = try c.decodeIfPresent(String.self, forKey: .turn) ?? blank.turn
    }

    var relaysCalls: Bool { !turn.trimmingCharacters(in: .whitespaces).isEmpty }

    var configured: Bool { !server.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The host alone, for headings.
    var host: String {
        let text = server.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("["), let end = text.firstIndex(of: "]") { return String(text[text.index(after: text.startIndex)..<end]) }
        if text.filter({ $0 == ":" }).count == 1, let colon = text.lastIndex(of: ":") { return String(text[..<colon]) }
        return text
    }

    // MARK: - the file

    static var file: URL { Store.file("vpn.json") }

    static func load() -> VpnServer {
        guard let data = try? Data(contentsOf: file) else { return VpnServer() }
        return (try? JSONDecoder().decode(VpnServer.self, from: data)) ?? VpnServer()
    }

    func save() {
        let file = VpnServer.file
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard configured else { try? FileManager.default.removeItem(at: file); return }
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: - Hysteria's config

    /// The client config Hysteria is started with: this server, and a SOCKS5
    /// listener on loopback at `port` for the relay to reach.
    func yaml(port: UInt16, turnPort: UInt16) -> String {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var lines = ["# Written by Search for its VPN. Changes here are overwritten on the next connect.",
                     "server: \(quoted(trimmed(server)))"]
        if !auth.isEmpty { lines.append("auth: \(quoted(auth))") }
        var tls: [String] = []
        if !trimmed(sni).isEmpty { tls.append("  sni: \(quoted(trimmed(sni)))") }
        if !trimmed(ca).isEmpty { tls.append("  ca: \(quoted((trimmed(ca) as NSString).expandingTildeInPath))") }
        if !trimmed(pin).isEmpty { tls.append("  pinSHA256: \(quoted(trimmed(pin)))") }
        if insecure { tls.append("  insecure: true") }
        if !tls.isEmpty { lines.append("tls:"); lines += tls }
        if !obfs.isEmpty {
            lines += ["obfs:", "  type: salamander", "  salamander:", "    password: \(quoted(obfs))"]
        }
        let rates = [("up", trimmed(up)), ("down", trimmed(down))].filter { !$0.1.isEmpty }
        if !rates.isEmpty {
            lines.append("bandwidth:")
            for (key, value) in rates {
                lines.append("  \(key): \(quoted(value.allSatisfy { $0.isNumber || $0 == "." } ? "\(value) mbps" : value))")
            }
        }
        lines += ["socks5:", "  listen: 127.0.0.1:\(port)", "  disableUDP: true"]
        if relaysCalls, turnPort != 0 {
            lines += ["udpForwarding:", "  - listen: 127.0.0.1:\(turnPort)",
                      "    remote: \(quoted(trimmed(turn)))", "    timeout: 300s"]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The fields this knows, read from a Hysteria client config someone
    /// already has — the one on this Mac, say. Not a YAML parser: two levels
    /// of `key: value`, which is all a client config's fields here need.
    static func reading(yaml text: String) -> VpnServer {
        var found = VpnServer()
        var section: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.components(separatedBy: " #").first ?? raw
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let depth = line.prefix(while: { $0 == " " }).count / 2
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            section = Array(section.prefix(depth))
            let path = (section + [key]).joined(separator: ".")
            if value.isEmpty { section.append(key); continue }
            switch path {
            case "server": found.server = value
            case "auth": found.auth = value
            case "tls.sni": found.sni = value
            case "tls.ca": found.ca = value
            case "tls.pinSHA256": found.pin = value
            case "tls.insecure": found.insecure = value == "true"
            case "obfs.salamander.password": found.obfs = value
            case "bandwidth.up": found.up = value.replacingOccurrences(of: " mbps", with: "")
            case "bandwidth.down": found.down = value.replacingOccurrences(of: " mbps", with: "")
            default: break
            }
        }
        return found
    }
}

/// Hysteria's output as it comes, cut into whole lines; the reader calls in
/// one at a time.
private final class Pending: @unchecked Sendable {
    private var text = ""

    func lines(adding data: Data) -> [String] {
        text += String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        text = lines.removeLast()
        return lines
    }
}

/// Where traffic leaves the tunnel, from ipinfo.io.
struct VpnExit: Decodable, Equatable {
    var ip: String
    var city: String?
    var country: String?

    var flag: String {
        guard let country, country.count == 2 else { return "🌐" }
        return String(String.UnicodeScalarView(country.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(127_397 + $0.value)
        }))
    }

    var place: String { [city, country].compactMap { $0 }.joined(separator: ", ") }
}

@MainActor
final class Vpn: ObservableObject {
    static let shared = Vpn()

    enum Phase: Equatable {
        case off
        case connecting
        case on
        /// Hysteria stopped while the VPN was on; started again shortly.
        /// Pages wait, or fail, meanwhile — never go around the tunnel.
        case reconnecting
        /// It gave up. The VPN is still on, so nothing loads until it is
        /// tried again or turned off.
        case failed(String)
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var server = VpnServer.load()
    /// When the tunnel last came up.
    @Published private(set) var since: Date?
    @Published private(set) var exit: VpnExit?
    @Published private(set) var latency: Int?
    /// The relay came up after pages had already opened connections
    /// straight out, which WebKit keeps and the relay can't end: those
    /// sites go around it until they close their connections, or Search
    /// restarts.
    @Published private(set) var late = false

    /// Whether the person wants the VPN on: what the proxy follows, whatever
    /// Hysteria is doing.
    private(set) var wanted = false
    var configured: Bool { server.configured }
    var isOn: Bool { phase == .on }

    let meter = VpnMeter()
    private let relay = Relay()
    private var process: Process?
    private var stopping = false
    private var retries = 0
    private var retry: DispatchWorkItem?
    private var lastError: String?
    private var stores = NSHashTable<WKWebsiteDataStore>.weakObjects()
    private var relayFailures = 0
    private var controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var shimmed = NSHashTable<WKUserContentController>.weakObjects()
    /// The loopback UDP port pages are given as their TURN relay: the
    /// relay's, which counts what goes by and passes it to Hysteria's.
    private(set) var turnPort: UInt16 = 0
    /// Hysteria's UDP port forwarded to the server's TURN relay, new each
    /// time Hysteria starts.
    private var hysteriaTurnPort: UInt16 = 0

    private init() {
        // A Hysteria of ours a crash left running holds a port and a
        // connection to the server; nobody else would end it.
        Vpn.endStrays()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Vpn.shared.endHysteria() }
        }
        relay.onFailure = { [weak self] in self?.relayFailed() }
        wire()
        if configured, atLaunch { turnOn() }
    }

    // MARK: - the stores

    /// Every WebKit store the browser hands a page goes through here, so
    /// that none is left going around the tunnel.
    func cover(_ store: WKWebsiteDataStore) {
        if !stores.contains(store) { stores.add(store) }
        store.proxyConfigurations = Vpn.proxies
    }

    private func coverAll() {
        for store in stores.allObjects { store.proxyConfigurations = Vpn.proxies }
    }

    /// What a store or a session is told once a server is set up: the
    /// relay, as a SOCKS5 proxy, on or off. Read off the main thread too, by downloads of the
    /// app's own (favicons, extensions).
    nonisolated static var proxies: [ProxyConfiguration] {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    nonisolated(unsafe) private static var current: [ProxyConfiguration] = []
    nonisolated private static let lock = NSLock()

    /// A session for the app's own fetches on behalf of pages — a site's
    /// icon, an image saved from a page, an extension from the store —
    /// through the relay, and so the tunnel while it is on, like the pages.
    nonisolated static var session: URLSession {
        let proxies = Vpn.proxies
        guard !proxies.isEmpty else { return .shared }
        lock.lock(); defer { lock.unlock() }
        if let tunneled { return tunneled }
        let config = URLSessionConfiguration.default
        config.proxyConfigurations = proxies
        let made = URLSession(configuration: config)
        tunneled = made
        return made
    }
    nonisolated(unsafe) private static var tunneled: URLSession?

    /// The relay listening and the stores pointed at it once there is a
    /// server; neither when there isn't. A relay that can't listen leaves
    /// pages straight out with the VPN off — and, with it on, pointed at it
    /// anyway: failing, rather than going around the tunnel.
    private func wire() {
        guard configured else {
            point(false)
            relay.stop()
            return
        }
        for controller in controllers.allObjects { shim(controller) }
        let listening = relay.start()
        point(listening || wanted)
    }

    /// The relay's port went away under it: another, and the stores told.
    private func relayFailed() {
        relayFailures += 1
        guard configured, relayFailures <= 5 else { point(wanted); return }
        relay.renew()
        wire()
    }

    private func point(_ on: Bool) {
        if on, Vpn.proxies.isEmpty, !stores.allObjects.isEmpty { late = true }
        // Port 1 when there is none: nothing listens there, so pages fail.
        let port = NWEndpoint.Port(rawValue: relay.port == 0 ? 1 : relay.port)!
        let proxies = on ? [ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: port))] : []
        Vpn.lock.lock()
        Vpn.current = proxies
        Vpn.tunneled?.invalidateAndCancel()
        Vpn.tunneled = nil
        Vpn.lock.unlock()
        coverAll()
    }

    // MARK: - on and off

    func toggle() { wanted ? turnOff() : turnOn() }

    func turnOn() {
        // On already — connecting, or given up and waiting for Try again.
        guard configured, !wanted else { return }
        wanted = true
        openCalls()
        updateCalls()
        Store.settings.set(true, forKey: "vpn.on")
        // What is open straight out ends here; what comes next waits for
        // the tunnel.
        relay.route(.hold)
        wire()
        retries = 0
        meter.begin(relay)
        launch()
    }

    func turnOff() {
        wanted = false
        Store.settings.set(false, forKey: "vpn.on")
        retry?.cancel()
        endHysteria()
        relay.route(.direct)
        wire()
        relay.stopCalls()
        updateCalls()
        meter.end()
        phase = .off
        since = nil
        exit = nil
        latency = nil
    }

    /// After the server's settings change: the next connect uses them, and
    /// one that is up now starts over with them.
    func use(_ server: VpnServer) {
        server.save()
        self.server = server
        if !server.configured {
            turnOff()
            // Hysteria's config has the password in it.
            try? FileManager.default.removeItem(at: Vpn.folder)
        }
        wire()
        if wanted {
            if server.relaysCalls { openCalls() } else { relay.stopCalls() }
        }
        updateCalls()
        if server.configured, wanted {
            retries = 0
            since = nil
            endHysteria()
            launch()
        }
    }

    func tryAgain() {
        guard wanted else { turnOn(); return }
        retries = 0
        retry?.cancel()
        endHysteria()
        launch()
    }

    // MARK: - Hysteria

    static var folder: URL { Store.file("vpn") }
    static var log: URL { folder.appendingPathComponent("client.log") }
    private static var config: URL { folder.appendingPathComponent("client.yaml") }

    /// Where Hysteria is: the one picked in Settings, or the usual places a
    /// package manager puts it.
    static var program: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let picked = Store.settings.string(forKey: "vpn.program").map { [$0] } ?? []
        let usual = ["/opt/homebrew/bin/hysteria", "/usr/local/bin/hysteria", "\(home)/.local/bin/hysteria", "\(home)/go/bin/hysteria"]
        return (picked + usual).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func launch() {
        // Never two: one still running is ended first.
        endHysteria()
        retry?.cancel()
        lastError = nil
        phase = wanted && since != nil && retries > 0 ? .reconnecting : .connecting
        exit = nil
        latency = nil
        relay.route(.hold)
        guard let program = Vpn.program else {
            phase = .failed("Hysteria isn't installed — brew install hysteria, or pick it in Settings › VPN")
            relay.route(.refuse)
            return
        }
        guard let port = Relay.freePort() else {
            phase = .failed("Couldn't find a free port on this Mac for Hysteria")
            relay.route(.refuse)
            return
        }
        let files = FileManager.default
        try? files.createDirectory(at: Vpn.folder, withIntermediateDirectories: true)
        try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Vpn.folder.path)
        do {
            if server.relaysCalls { openCalls() }
            hysteriaTurnPort = server.relaysCalls ? Relay.freePort(udp: true) ?? 0 : 0
            try server.yaml(port: port, turnPort: hysteriaTurnPort).write(to: Vpn.config, atomically: true, encoding: .utf8)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Vpn.config.path)
        } catch {
            phase = .failed("Couldn't write Hysteria's config: \(error.localizedDescription)")
            relay.route(.refuse)
            return
        }
        // A log of this connection only, so that what is in it is about now.
        files.createFile(atPath: Vpn.log.path, contents: nil)
        let log = try? FileHandle(forWritingTo: Vpn.log)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = ["client", "-c", Vpn.config.path, "--disable-update-check"]
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let pending = Pending()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; try? log?.close(); return }
            let lines = pending.lines(adding: data)
            // Without the colours it puts in for a terminal.
            let plain = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            log?.write(Data(plain.utf8))
            DispatchQueue.main.async {
                for line in lines { self?.heard(line, from: process, port: port) }
            }
        }
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { self?.ended(ended) }
        }
        do {
            try process.run()
        } catch {
            phase = .failed("Couldn't start Hysteria: \(error.localizedDescription)")
            relay.route(.refuse)
            return
        }
        self.process = process
        stopping = false
    }

    /// One line of Hysteria's log: the one that says it is up, or what went
    /// wrong.
    private func heard(_ line: String, from process: Process, port: UInt16) {
        guard process === self.process else { return }
        let text = line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let fields = text.components(separatedBy: "\t")
        let level = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces).uppercased() : ""
        if text.contains("UDP forwarding listening"), hysteriaTurnPort != 0 {
            relay.calls(to: hysteriaTurnPort)
        }
        if text.contains("SOCKS5 server listening") {
            relay.route(.tunnel(port))
            retries = 0
            if since == nil || phase != .reconnecting { since = Date() }
            phase = .on
            Task { await measure() }
        } else if level == "FATAL" || level == "ERROR" {
            lastError = Vpn.plain(fields)
        }
    }

    private func ended(_ process: Process) {
        guard process === self.process else { return }
        self.process = nil
        guard wanted, !stopping else { return }
        relay.route(.hold)
        let reason = lastError ?? "Hysteria stopped (exit \(process.terminationStatus))"
        // Wrong password or a certificate it won't trust: trying again gets
        // the same answer.
        let hopeless = ["auth", "certificate", "x509", "config", "invalid"].contains { reason.lowercased().contains($0) }
        retries += 1
        guard !hopeless, retries <= 5 else {
            phase = .failed(reason)
            // Still on, so still nothing around the tunnel — but pages are
            // told at once rather than kept waiting for a Hysteria that isn't
            // coming.
            relay.route(.refuse)
            return
        }
        phase = since == nil ? .connecting : .reconnecting
        let work = DispatchWorkItem { [weak self] in self?.launch() }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(30, pow(2, Double(retries - 1))), execute: work)
    }

    func endHysteria() {
        stopping = true
        relay.calls(to: nil)
        guard let process else { return }
        self.process = nil
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
    }

    /// Any `hysteria client` started with our config by an earlier run.
    private static func endStrays() {
        guard FileManager.default.fileExists(atPath: config.path) else { return }
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        // pkill reads a pattern; the world's folder name has brackets in it.
        killer.arguments = ["-f", NSRegularExpression.escapedPattern(for: "hysteria client -c \(config.path)")]
        try? killer.run()
        killer.waitUntilExit()
    }

    /// "failed to initialize client {"error": "…"}" → "Failed to initialize client: …"
    private static func plain(_ fields: [String]) -> String {
        let message = fields.count > 2 ? fields[2] : fields.joined(separator: " ")
        var detail = ""
        if fields.count > 3, let data = fields[3].data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? String {
            detail = ": " + error
        }
        let text = (message + detail).trimmingCharacters(in: .whitespaces)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: - calls

    /// Every tab's scripts come through here each time they are set up
    /// afresh (Tab.arm), so that a call in any of its pages goes the way the
    /// page does.
    func rearm(_ controller: WKUserContentController) {
        if !controllers.contains(controller) { controllers.add(controller) }
        shimmed.remove(controller)
        shim(controller)
    }

    /// The calls' relay listening, at the port pages were told if it can,
    /// at another (and pages told) if not.
    private func openCalls() {
        guard server.relaysCalls else { return }
        if turnPort != 0, relay.startCalls(turnPort) { return }
        let before = turnPort
        turnPort = Relay.freePort(udp: true) ?? 0
        if turnPort == 0 || !relay.startCalls(turnPort) { turnPort = 0 }
        if turnPort != before { updateCalls() }
    }

    /// What calls do now: relay-only while the VPN is on — through the
    /// tunnel's TURN port, or nowhere — and untouched while it's off.
    var callsRelay: String? {
        guard wanted, server.relaysCalls, turnPort != 0 else { return nil }
        return "turn:127.0.0.1:\(turnPort)?transport=udp"
    }

    private var callsState: String {
        let url = callsRelay.map { "\"\($0)\"" } ?? "null"
        return "window[\"\(Vpn.key)\"] && window[\"\(Vpn.key)\"]({ relay: \(wanted), url: \(url) });"
    }

    private func shim(_ controller: WKUserContentController) {
        guard configured, !shimmed.contains(controller) else { return }
        shimmed.add(controller)
        controller.addUserScript(WKUserScript(source: Vpn.shimSource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.addUserScript(WKUserScript(source: callsState, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    }

    /// The VPN went on or off, or its relay changed: pages loaded from now
    /// on start with it — a script added after the others runs after them —
    /// and pages already open are told at once.
    private func updateCalls() {
        let state = callsState
        for controller in controllers.allObjects {
            if shimmed.contains(controller) {
                controller.addUserScript(WKUserScript(source: state, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
            } else {
                shim(controller)
            }
        }
        for page in Web.pages.allObjects {
            page.evaluateJavaScript(state, in: nil, in: .page) { _ in }
        }
    }

    /// Where the page's state setter lives: a name of this run's own.
    private static let key = "__searchVpn" + UUID().uuidString.replacingOccurrences(of: "-", with: "")

    /// RTCPeerConnection, as pages see it, with the VPN's say in its ICE
    /// servers: while relaying, the page's own are replaced by the tunnel's
    /// relay alone and only relayed candidates are used — a page's own TURN
    /// server, or a direct candidate, would carry the call around the
    /// tunnel. The prototype and its constructor are the real ones, so
    /// pages that check, or subclass, see what they expect.
    private static let shimSource = """
    (() => {
      const w = window, Native = w.RTCPeerConnection, KEY = "\(key)";
      if (!Native || Object.prototype.hasOwnProperty.call(w, KEY)) return;
      let mode = { relay: false, url: null };
      const sign = (m) => m.relay ? "relay " + m.url : "direct";
      // Connections made so far, and the way each was made: one made the
      // other way is closed when the VPN switches — the page (Discord, say)
      // makes it again, the new way, rather than a call carrying on around
      // the tunnel.
      const made = new Set();
      const fix = (config) => {
        if (!mode.relay) return config;
        const c = Object.assign({}, config || {});
        c.iceServers = mode.url ? [{ urls: [mode.url], username: "search", credential: "search" }] : [];
        c.iceTransportPolicy = "relay";
        return c;
      };
      function RTCPeerConnection(config, ...rest) {
        if (!new.target) throw new TypeError("Failed to construct 'RTCPeerConnection': Please use the 'new' operator");
        const pc = Reflect.construct(Native, [fix(config), ...rest], new.target);
        made.add({ ref: new WeakRef(pc), way: sign(mode) });
        return pc;
      }
      RTCPeerConnection.prototype = Native.prototype;
      if (Native.generateCertificate) {
        Object.defineProperty(RTCPeerConnection, "generateCertificate", {
          value: function generateCertificate(...a) { return Native.generateCertificate(...a); }, writable: true, configurable: true });
      }
      Object.defineProperty(Native.prototype, "constructor", { value: RTCPeerConnection, writable: true, configurable: true });
      const set = Native.prototype.setConfiguration;
      if (set) {
        Object.defineProperty(Native.prototype, "setConfiguration", {
          value: function setConfiguration(c) { return set.call(this, fix(c)); }, writable: true, configurable: true });
      }
      Object.defineProperty(w, "RTCPeerConnection", { value: RTCPeerConnection, writable: true, configurable: true });
      if (w.webkitRTCPeerConnection) w.webkitRTCPeerConnection = RTCPeerConnection;
      const update = (m) => {
        mode = m;
        const way = sign(m);
        for (const entry of made) {
          const pc = entry.ref.deref();
          if (!pc || pc.connectionState === "closed") { made.delete(entry); continue; }
          if (entry.way !== way) { made.delete(entry); try { pc.close(); } catch (e) {} }
        }
        // Frames of the same site are told too; the page only reaches them.
        for (let i = 0; i < w.frames.length; i++) {
          try { const f = w.frames[i]; if (Object.prototype.hasOwnProperty.call(f, KEY)) f[KEY](m); } catch (e) {}
        }
      };
      Object.defineProperty(w, KEY, { value: update });
    })();
    """

    // MARK: - measuring

    /// Where the tunnel comes out, once per connection, and how long a small
    /// request takes through it, every time.
    func measure() async {
        guard isOn else { return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.proxyConfigurations = Vpn.proxies
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        if exit == nil, let (data, _) = try? await session.data(from: URL(string: "https://ipinfo.io/json")!) {
            exit = try? JSONDecoder().decode(VpnExit.self, from: data)
        }
        var request = URLRequest(url: URL(string: "https://www.gstatic.com/generate_204")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // The first warms the connection up; the best of the rest counts.
        guard (try? await session.data(for: request)) != nil else { latency = nil; return }
        var best: Duration?
        for _ in 0..<3 {
            let clock = ContinuousClock()
            let start = clock.now
            guard (try? await session.data(for: request)) != nil else { continue }
            best = min(best ?? (clock.now - start), clock.now - start)
        }
        if isOn { latency = best.map { Int($0 / .milliseconds(1)) } }
    }

    // MARK: - settings

    var atLaunch: Bool {
        get { Store.settings.bool(forKey: "vpn.atLaunch") }
        set { Store.settings.set(newValue, forKey: "vpn.atLaunch"); objectWillChange.send() }
    }

    func pickProgram(_ path: String?) {
        Store.settings.set(path, forKey: "vpn.program")
        objectWillChange.send()
    }

    func openLog() {
        NSWorkspace.shared.open(Vpn.log)
    }
}

/// How much went through, sampled once a second: kept apart from Vpn so the
/// sidebar's button, which only cares whether the tunnel is up, isn't drawn
/// again every second with it.
@MainActor
final class VpnMeter: ObservableObject {
    struct Sample: Equatable { var down: Double; var up: Double }

    /// Bytes a second, the last minute of them.
    @Published private(set) var samples: [Sample] = []
    @Published private(set) var down: UInt64 = 0
    @Published private(set) var up: UInt64 = 0
    @Published private(set) var connections = 0
    /// Bytes each site took this connection, most first.
    @Published private(set) var sites: [(site: String, bytes: UInt64)] = []
    @Published private(set) var month: UInt64 = Store.settings.object(forKey: "vpn.month.bytes") as? UInt64 ?? 0

    var rate: Sample { samples.last ?? Sample(down: 0, up: 0) }

    private weak var relay: Relay?
    private var timer: Timer?
    private var last: (down: UInt64, up: UInt64) = (0, 0)
    private var unsaved: UInt64 = 0

    func begin(_ relay: Relay) {
        self.relay = relay
        relay.reset()
        last = (0, 0)
        down = 0
        up = 0
        sites = []
        samples = Array(repeating: Sample(down: 0, up: 0), count: 60)
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // On while a menu is open or the page scrolls, too.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func end() {
        tick()
        timer?.invalidate()
        timer = nil
        keepMonth()
    }

    private func tick() {
        guard let relay else { return }
        let now = relay.reading()
        let fresh = Sample(down: Double(now.down &- last.down), up: Double(now.up &- last.up))
        last = (now.down, now.up)
        samples = Array((samples + [fresh]).suffix(60))
        down = now.down
        up = now.up
        connections = now.connections
        sites = now.sites.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
        rollMonth()
        let more = UInt64(fresh.down + fresh.up)
        month += more
        unsaved += more
        if unsaved > 1_000_000 { keepMonth() }
    }

    /// The month's count starts over when the month does.
    private func rollMonth() {
        let key = Date().formatted(.iso8601.year().month())
        guard Store.settings.string(forKey: "vpn.month") != key else { return }
        Store.settings.set(key, forKey: "vpn.month")
        month = 0
        unsaved = 0
        keepMonth()
    }

    private func keepMonth() {
        Store.settings.set(month, forKey: "vpn.month.bytes")
        unsaved = 0
    }
}


// MARK: - the relay

/// A SOCKS5 server on loopback for WebKit, which sends each connection on
/// its way: straight out, or to Hysteria's own SOCKS5 port with the same
/// request — and then copies the bytes both ways, counting the tunnel's.
final class Relay: @unchecked Sendable {
    enum Route: Equatable {
        /// VPN off: everything straight out.
        case direct
        /// VPN on, Hysteria on its way: connections wait for it.
        case hold
        /// VPN on, Hysteria listening at this port.
        case tunnel(UInt16)
        /// VPN on, Hysteria not coming: connections are turned away.
        case refuse
    }

    private let queue = DispatchQueue(label: "com.officecommun.search.vpn.relay")
    private var listener: NWListener?
    /// Fixed for the run once picked, so stores told about it once stay right.
    private(set) var port: UInt16 = 0
    // The rest is the queue's.
    private var route = Route.direct
    private var waiting: [Pair] = []
    private var pairs: [ObjectIdentifier: Pair] = [:]
    private var down: UInt64 = 0
    private var up: UInt64 = 0
    private var sites: [String: UInt64] = [:]

    /// Told, on the main thread, when the listener fails after it was up.
    var onFailure: (() -> Void)?
    /// Which listener is the current one, so a failure from one stopped on
    /// purpose isn't taken for the current one's.
    private var generation = 0

    /// Listens, if it isn't already, and waits until it is: the stores are
    /// pointed at it as soon as this returns, before any page loads.
    /// Called on the main thread.
    func start() -> Bool {
        if queue.sync(execute: { listener != nil }) { return true }
        if port == 0 { port = Relay.freePort() ?? 0 }
        guard port != 0, let number = NWEndpoint.Port(rawValue: port) else { return false }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: number) else {
            port = 0
            return false
        }
        let mine: Int = queue.sync {
            generation += 1
            self.listener = listener
            return generation
        }
        let ready = DispatchSemaphore(value: 0)
        var up = false
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                up = true
                ready.signal()
            case .failed:
                ready.signal()
                guard let self, self.generation == mine else { return }
                self.listener?.cancel()
                self.listener = nil
                if up { DispatchQueue.main.async { self.onFailure?() } }
            default: break
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 2)
        let listening = queue.sync { up && self.listener === listener }
        if !listening {
            queue.sync {
                if self.listener === listener { self.listener = nil }
                generation += 1
            }
            listener.cancel()
            // Another port next time.
            port = 0
        }
        return listening
    }

    /// A port of its own again at the next start.
    func renew() { port = 0 }

    func stop() {
        queue.sync {
            generation += 1
            listener?.cancel()
            listener = nil
            for pair in waiting { pair.close() }
            waiting = []
            for pair in pairs.values { pair.close() }
            pairs = [:]
        }
    }

    /// Where connections go from now on. Those open another way end — WebKit
    /// opens them again, through here, the new way.
    func route(_ next: Route) {
        queue.async {
            guard next != self.route else { return }
            self.route = next
            for pair in self.pairs.values where (pair.way == .direct || pair.way.tunneled) && pair.way != Pair.Way(next) {
                pair.close()
            }
            if next != .hold {
                let held = self.waiting
                self.waiting = []
                for pair in held where !pair.closed { self.send(pair) }
            }
        }
    }

    func reset() {
        queue.sync { down = 0; up = 0; sites = [:] }
    }

    func reading() -> (down: UInt64, up: UInt64, connections: Int, sites: [String: UInt64]) {
        queue.sync { (down, up, pairs.values.filter { $0.way.tunneled }.count, sites) }
    }

    // MARK: SOCKS5, WebKit's side

    private func accept(_ inbound: NWConnection) {
        let pair = Pair(inbound: inbound)
        let key = ObjectIdentifier(pair)
        pairs[key] = pair
        pair.onClose = { [weak self] in
            self?.pairs[key] = nil
            self?.waiting.removeAll { $0 === pair }
        }
        inbound.start(queue: queue)
        // The greeting: version, how many ways to sign in, the ways. No
        // signing in is the only one offered back.
        read(inbound, 2, pair) { [weak self] head in
            guard head[0] == 5 else { pair.close(); return }
            self?.read(inbound, Int(head[1]), pair) { _ in
                inbound.send(content: Data([5, 0]), completion: .idempotent)
                self?.request(pair)
            }
        }
    }

    /// The request: CONNECT to a name, an IPv4 or an IPv6 address, and a port.
    private func request(_ pair: Pair) {
        read(pair.inbound, 4, pair) { [weak self] head in
            guard let self else { return }
            guard head[0] == 5, head[1] == 1 else { self.answer(pair, 7); return }
            let kind = head[3]
            func finish(_ address: Data, _ host: String) {
                self.read(pair.inbound, 2, pair) { port in
                    pair.request = head + address + port
                    pair.host = host
                    pair.port = UInt16(port[0]) << 8 | UInt16(port[1])
                    self.send(pair)
                }
            }
            switch kind {
            case 1:
                self.read(pair.inbound, 4, pair) { address in finish(address, address.map(String.init).joined(separator: ".")) }
            case 4:
                self.read(pair.inbound, 16, pair) { address in
                    let words = stride(from: 0, to: 16, by: 2).map { String(UInt16(address[address.startIndex + $0]) << 8 | UInt16(address[address.startIndex + $0 + 1]), radix: 16) }
                    finish(address, words.joined(separator: ":"))
                }
            case 3:
                self.read(pair.inbound, 1, pair) { length in
                    self.read(pair.inbound, Int(length[length.startIndex]), pair) { name in
                        finish(length + name, String(decoding: name, as: UTF8.self))
                    }
                }
            default:
                self.answer(pair, 8)
            }
        }
    }

    /// Off to wherever the route says, or held, or turned away.
    private func send(_ pair: Pair) {
        if Relay.isLocal(pair.host) {
            out(pair, .local)
            return
        }
        switch route {
        case .direct: out(pair, .direct)
        case .tunnel(let port): through(pair, port)
        case .refuse: answer(pair, 1)
        case .hold:
            waiting.append(pair)
            // Held a while for Hysteria to come up, as at launch, then let go.
            queue.asyncAfter(deadline: .now() + 20) { [weak self, weak pair] in
                guard let self, let pair, self.waiting.contains(where: { $0 === pair }) else { return }
                self.waiting.removeAll { $0 === pair }
                self.answer(pair, 1)
            }
        }
    }

    /// Straight out, by the Mac's own network.
    private func out(_ pair: Pair, _ way: Pair.Way) {
        guard let port = NWEndpoint.Port(rawValue: pair.port) else { answer(pair, 1); return }
        let outbound = NWConnection(host: NWEndpoint.Host(pair.host), port: port, using: .tcp)
        pair.way = way
        pair.outbound = outbound
        outbound.stateUpdateHandler = { [weak self, weak pair] state in
            guard let self, let pair else { return }
            switch state {
            case .ready:
                guard !pair.connected else { return }
                pair.connected = true
                // Succeeded; the address it was bound to is nobody's business.
                pair.inbound.send(content: Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { [weak self] _ in
                    self?.pump(pair, upward: true)
                    self?.pump(pair, upward: false)
                })
            case .waiting(let error), .failed(let error):
                if pair.connected { pair.close() } else { self.answer(pair, Relay.code(error)) }
            default: break
            }
        }
        outbound.start(queue: queue)
    }

    /// To Hysteria: its greeting, then WebKit's own request word for word,
    /// whose answer goes back to WebKit as Hysteria gives it.
    private func through(_ pair: Pair, _ port: UInt16) {
        let outbound = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        pair.way = .tunnel(port)
        pair.outbound = outbound
        pair.site = Relay.site(pair.host)
        outbound.stateUpdateHandler = { [weak self, weak pair] state in
            guard let self, let pair else { return }
            switch state {
            case .ready:
                guard !pair.connected else { return }
                pair.connected = true
                outbound.send(content: Data([5, 1, 0]), completion: .idempotent)
                self.read(outbound, 2, pair) { reply in
                    guard reply[reply.startIndex] == 5, reply[reply.startIndex + 1] == 0 else { self.answer(pair, 1); return }
                    outbound.send(content: pair.request, completion: .contentProcessed { _ in
                        self.pump(pair, upward: true)
                        self.pump(pair, upward: false)
                    })
                }
            case .waiting, .failed:
                // Nothing listening: Hysteria went away between the two.
                if pair.connected { pair.close() } else { self.answer(pair, 1) }
            default: break
            }
        }
        outbound.start(queue: queue)
    }

    /// A failure reply, and the end of the connection.
    private func answer(_ pair: Pair, _ code: UInt8) {
        guard !pair.closed else { return }
        pair.inbound.send(content: Data([5, code, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { [weak pair] _ in
            pair?.close()
        })
    }

    private func read(_ connection: NWConnection, _ count: Int, _ pair: Pair, then: @escaping (Data) -> Void) {
        guard count > 0 else { then(Data()); return }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak pair] data, _, _, _ in
            guard let pair, !pair.closed else { return }
            guard let data, data.count == count else { pair.close(); return }
            then(Data(data))
        }
    }

    // MARK: the bytes

    private func pump(_ pair: Pair, upward: Bool) {
        guard let from = upward ? pair.inbound : pair.outbound, let to = upward ? pair.outbound : pair.inbound else { return }
        from.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak pair] data, _, complete, error in
            guard let self, let pair, !pair.closed else { return }
            if let data, !data.isEmpty {
                if pair.way.tunneled {
                    if upward { self.up &+= UInt64(data.count) } else { self.down &+= UInt64(data.count) }
                    if let site = pair.site { self.sites[site, default: 0] &+= UInt64(data.count) }
                }
                to.send(content: data, completion: .contentProcessed { [weak self, weak pair] error in
                    guard let self, let pair else { return }
                    if error != nil { pair.close(); return }
                    if complete { pair.finish(upward) } else { self.pump(pair, upward: upward) }
                })
                if complete { to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent) }
            } else if complete {
                to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                pair.finish(upward)
            } else if error != nil {
                pair.close()
            } else {
                self.pump(pair, upward: upward)
            }
        }
    }

    // MARK: calls (UDP)

    // Pages' TURN traffic: datagrams from WebKit, passed one by one to
    // Hysteria's forwarded port and back, counted under "Calls". With no
    // Hysteria to pass them to, they are dropped — TURN tries again.

    private var callsListener: NWListener?
    private var callsGeneration = 0
    private var callsUpstream: UInt16?
    private var flows: [ObjectIdentifier: Flow] = [:]
    private var sweeping = false

    final class Flow {
        let inbound: NWConnection
        var outbound: NWConnection?
        var last = Date()
        init(inbound: NWConnection) { self.inbound = inbound }
        func close() { inbound.cancel(); outbound?.cancel(); outbound = nil }
    }

    /// Listens for calls at this UDP port, if it isn't already, and waits
    /// until it is. Called on the main thread.
    func startCalls(_ port: UInt16) -> Bool {
        if queue.sync(execute: { callsListener != nil }) { return true }
        guard let number = NWEndpoint.Port(rawValue: port) else { return false }
        let parameters = NWParameters.udp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: number) else { return false }
        let mine: Int = queue.sync {
            callsGeneration += 1
            callsListener = listener
            return callsGeneration
        }
        let ready = DispatchSemaphore(value: 0)
        var up = false
        listener.newConnectionHandler = { [weak self] connection in self?.acceptFlow(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                up = true
                ready.signal()
            case .failed:
                ready.signal()
                guard let self, self.callsGeneration == mine else { return }
                self.callsListener?.cancel()
                self.callsListener = nil
            default: break
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 2)
        let listening = queue.sync { up && callsListener === listener }
        if !listening {
            queue.sync {
                if callsListener === listener { callsListener = nil }
                callsGeneration += 1
            }
            listener.cancel()
        }
        if listening { queue.async { self.sweep() } }
        return listening
    }

    func stopCalls() {
        queue.sync {
            callsGeneration += 1
            callsListener?.cancel()
            callsListener = nil
            callsUpstream = nil
            for flow in flows.values { flow.close() }
            flows = [:]
        }
    }

    /// Where Hysteria forwards calls now; nil while it isn't up.
    func calls(to port: UInt16?) {
        queue.async {
            guard port != self.callsUpstream else { return }
            self.callsUpstream = port
            for flow in self.flows.values {
                flow.outbound?.cancel()
                flow.outbound = nil
            }
        }
    }

    private func acceptFlow(_ inbound: NWConnection) {
        let flow = Flow(inbound: inbound)
        let key = ObjectIdentifier(flow)
        flows[key] = flow
        inbound.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.flows[key]?.close()
                self?.flows[key] = nil
            default: break
            }
        }
        inbound.start(queue: queue)
        receiveCalls(flow)
    }

    private func receiveCalls(_ flow: Flow) {
        flow.inbound.receiveMessage { [weak self, weak flow] data, _, _, error in
            guard let self, let flow, error == nil else { return }
            if let data, !data.isEmpty, let port = self.callsUpstream {
                flow.last = Date()
                self.up &+= UInt64(data.count)
                self.sites["Calls", default: 0] &+= UInt64(data.count)
                self.outbound(flow, port).send(content: data, completion: .idempotent)
            }
            self.receiveCalls(flow)
        }
    }

    private func outbound(_ flow: Flow, _ port: UInt16) -> NWConnection {
        if let made = flow.outbound { return made }
        let made = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        flow.outbound = made
        made.start(queue: queue)
        func back() {
            made.receiveMessage { [weak self, weak flow] data, _, _, error in
                guard let self, let flow, error == nil, flow.outbound === made else { return }
                if let data, !data.isEmpty {
                    flow.last = Date()
                    self.down &+= UInt64(data.count)
                    self.sites["Calls", default: 0] &+= UInt64(data.count)
                    flow.inbound.send(content: data, completion: .idempotent)
                }
                back()
            }
        }
        back()
        return made
    }

    /// Flows quiet for five minutes — a call long over — are let go.
    private func sweep() {
        guard !sweeping else { return }
        sweeping = true
        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self else { return }
            self.sweeping = false
            let stale = Date().addingTimeInterval(-300)
            for (key, flow) in self.flows where flow.last < stale {
                flow.close()
                self.flows[key] = nil
            }
            if self.callsListener != nil { self.sweep() }
        }
    }

    // MARK: helpers

    /// SOCKS5's reply codes for why a connection out failed.
    private static func code(_ error: NWError) -> UInt8 {
        if case .posix(let code) = error {
            switch code {
            case .ECONNREFUSED: return 5
            case .EHOSTUNREACH, .EHOSTDOWN: return 4
            case .ENETUNREACH, .ENETDOWN: return 3
            default: break
            }
        }
        if case .dns = error { return 4 }
        return 1
    }

    /// This Mac, and the network it is on: a router's page, a printer, a
    /// dev server — nowhere a server far away could reach.
    static func isLocal(_ host: String) -> Bool {
        let name = host.lowercased()
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") { return true }
        // A name of one word — router, nas — is the local network's own.
        if !name.contains("."), !name.contains(":") { return true }
        if let v4 = IPv4Address(name) {
            let b = [UInt8](v4.rawValue)
            return b[0] == 127 || b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254) || (b[0] == 100 && (64...127).contains(b[1])) || b[0] == 0
        }
        if let v6 = IPv6Address(name) {
            let b = [UInt8](v6.rawValue)
            return v6.isLoopback || v6.isLinkLocal || (b[0] & 0xFE) == 0xFC
        }
        return false
    }

    /// Whether a loopback port is free to listen on now.
    static func isFree(_ port: UInt16, udp: Bool = false) -> Bool {
        bound(port, udp: udp) == port
    }

    /// A free TCP (or UDP) port on loopback, asked of the system by binding
    /// port 0.
    static func freePort(udp: Bool = false) -> UInt16? {
        bound(0, udp: udp)
    }

    private static func bound(_ port: UInt16, udp: Bool) -> UInt16? {
        let socket = Darwin.socket(AF_INET, udp ? SOCK_DGRAM : SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, size) == 0 && getsockname(socket, $0, &size) == 0
            }
        }
        guard bound else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }

    /// A host as a site: example.com for www.example.com and cdn.example.com.
    static func site(_ host: String) -> String {
        Vault.registrable(host.lowercased())
    }

    /// One page's connection: WebKit's side and wherever it was sent.
    final class Pair {
        enum Way: Equatable {
            case pending, local, direct, tunnel(UInt16)

            init(_ route: Route) {
                switch route {
                case .direct: self = .direct
                case .tunnel(let port): self = .tunnel(port)
                case .hold, .refuse: self = .pending
                }
            }

            var tunneled: Bool { if case .tunnel = self { return true } else { return false } }
        }

        let inbound: NWConnection
        var outbound: NWConnection?
        var way = Way.pending
        var request = Data()
        var host = ""
        var port: UInt16 = 0
        var site: String?
        /// Past the reply: from here a failure ends it, rather than answers.
        var connected = false
        var onClose: (() -> Void)?
        private(set) var closed = false
        private var finished: Set<Bool> = []

        init(inbound: NWConnection) {
            self.inbound = inbound
            inbound.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }

        func finish(_ upward: Bool) {
            finished.insert(upward)
            if finished.count == 2 { close() }
        }

        func close() {
            guard !closed else { return }
            closed = true
            inbound.cancel()
            outbound?.cancel()
            onClose?()
            onClose = nil
        }
    }
}
