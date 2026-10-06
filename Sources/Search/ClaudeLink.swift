import AppKit

// Connecting Claude Code to Search, from Settings, one step at a time.
//
// Claude reaches Search through a small MCP server, mcp/search_mcp.py, which
// Claude Code starts and which talks to the bench's socket (see Bench.swift
// and Agent.swift). It ships inside the app, in Contents/Resources, so a
// person who only ever downloaded Search has it. Settings › General shows,
// under "Let Claude use Search", what is still missing: Claude Code itself,
// Python 3 to run the server, and the server added to Claude Code — which a
// button does, through Claude Code's own `claude mcp add` — and then checks
// that it all holds together: Claude Code starts the server, and the server
// reaches Search.
//
// Nothing here runs on its own: every step is a button, or a look that
// changes nothing. A test world never touches your Claude Code: it keeps
// Claude Code's settings of its own (CLAUDE_CONFIG_DIR), and names the server
// after itself, pointed at its own socket.

@MainActor
final class ClaudeLink: ObservableObject {
    static let shared = ClaudeLink()

    /// Where one step stands.
    enum Step: Equatable {
        /// Not looked at yet.
        case unknown
        case checking
        case done(String)
        /// Still to do, with what to do.
        case missing(String)
        /// There, but not right.
        case warning(String)

        var done: Bool { if case .done = self { return true } else { return false } }

        var said: String {
            switch self {
            case .unknown: return ""
            case .checking: return "Checking…"
            case .done(let s), .missing(let s), .warning(let s): return s
            }
        }
    }

    @Published private(set) var claude: Step = .unknown
    @Published private(set) var python: Step = .unknown
    @Published private(set) var added: Step = .unknown
    @Published private(set) var connection: Step = .unknown
    /// Adding or checking, so the buttons wait.
    @Published private(set) var busy = false
    /// Looking at the steps again.
    @Published private(set) var looking = false
    /// What is registered under Search's name isn't Search's: left alone.
    @Published private(set) var foreign = false

    private(set) var claudePath: String?
    private(set) var pythonPath: String?
    /// The server as Claude Code has it now: what it runs, with what.
    private var server: (command: String, args: [String], env: [String: String])?

    /// Claude Code has something under Search's name.
    var registered: Bool { server != nil }
    /// The server the connection was last checked with: changed since, the
    /// answer is no longer about it.
    private var checked: String?

    private var serverSaid: String? {
        server.map { "\($0.command) \($0.args) \($0.env.sorted { $0.key < $1.key })" }
    }

    /// What Claude Code calls Search: "search" for the browser you use, and a
    /// name of its own for a test world.
    static var name: String { Store.world.map { "search-\($0)" } ?? "search" }

    /// The server, inside the app — or, run from the build folder, beside
    /// the source it was built from.
    static var script: URL? {
        if let bundled = Bundle.main.url(forResource: "search_mcp", withExtension: "py") { return bundled }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("mcp/search_mcp.py")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    /// Claude Code's settings of a test world's own; nil for yours.
    static var configDirectory: URL? { Store.testing ? Store.file("claude-config") : nil }

    /// Where Claude Code keeps the servers added for every project.
    static var configFile: URL {
        configDirectory?.appendingPathComponent(".claude.json")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    /// The command that adds Search to Claude Code, for a person who would
    /// rather paste it into Terminal.
    var command: String {
        let python = pythonPath ?? "python3"
        let script = ClaudeLink.script?.path ?? "/path/to/Search/mcp/search_mcp.py"
        let world = Store.world.map { " -e SEARCH_WORLD=\($0)" } ?? ""
        return "claude mcp add --scope user \(ClaudeLink.name)\(world) -- \(ClaudeLink.quoted(python)) \(ClaudeLink.quoted(script))"
    }

    /// Claude Code's own installer, for a Mac without it.
    static let installClaude = "curl -fsSL https://claude.ai/install.sh | bash"

    /// What to ask Claude once it is connected.
    static let firstAsk = "What tabs do I have open in Search?"

    // MARK: - looking

    /// Every step looked at again. Changes nothing.
    func refresh() {
        guard !busy, !looking else { return }
        if claude == .unknown { claude = .checking }
        if python == .unknown { python = .checking }
        if added == .unknown { added = .checking }
        looking = true
        Task {
            await look()
            looking = false
        }
    }

    private func look() async {
        claudePath = await ClaudeLink.findClaude()
        if let path = claudePath {
            let version = await ClaudeLink.run(path, ["--version"], timeout: 10)
            let number = version?.out.split(separator: " ").first.map(String.init) ?? ""
            claude = .done(number.isEmpty ? "Found at \(ClaudeLink.tilde(path))" : "Claude Code \(number), at \(ClaudeLink.tilde(path))")
        } else {
            claude = .missing("Not found on this Mac. Install it from Terminal, then check again")
        }

        if let found = await ClaudeLink.findPython() {
            pythonPath = found.path
            python = .done("Python \(found.version), at \(found.path)")
        } else {
            pythonPath = nil
            python = .missing("Search's connector runs on Python 3, which comes with Apple's command line tools")
        }

        readRegistration()
    }

    /// What Claude Code has under Search's name, read from its settings file.
    private func readRegistration() {
        defer { if serverSaid != checked { connection = .unknown } }
        foreign = false
        server = nil
        guard let data = try? Data(contentsOf: ClaudeLink.configFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any],
              let server = servers[ClaudeLink.name] as? [String: Any]
        else {
            added = .missing("Not added yet")
            return
        }
        let command = server["command"] as? String ?? ""
        let args = server["args"] as? [String] ?? []
        self.server = (command, args, server["env"] as? [String: String] ?? [:])
        guard let theirs = args.first(where: { $0.hasSuffix("search_mcp.py") }) else {
            foreign = true
            added = .warning("Claude Code already has a server named “\(ClaudeLink.name)” that isn't Search's — remove it with claude mcp remove \(ClaudeLink.name) -s user, then add Search")
            return
        }
        let ours = ClaudeLink.script.map { URL(fileURLWithPath: theirs).standardizedFileURL == $0.standardizedFileURL } ?? false
        if !FileManager.default.fileExists(atPath: theirs) {
            added = .warning("Added, but it points at a file that's gone: \(ClaudeLink.tilde(theirs))")
        } else if !FileManager.default.isExecutableFile(atPath: command) && !command.hasPrefix("python") {
            added = .warning("Added, but what runs it is gone: \(command)")
        } else if !ours {
            added = .warning("Added, but it runs another copy: \(ClaudeLink.tilde(theirs)) — Update makes it this Search's")
        } else {
            added = .done("Added, for every project")
        }
    }

    // MARK: - doing

    /// Search added to Claude Code, or brought up to date: the copy of the
    /// server inside this app, for every project. Then checked.
    func add(_ done: @escaping (String) -> Void) {
        guard !busy else { return }
        // Read again first: what is under the name may have changed since
        // the last look, and a server that isn't Search's is never replaced.
        readRegistration()
        guard !foreign, let claude = claudePath, let python = pythonPath, let script = ClaudeLink.script else { return }
        busy = true
        added = .checking
        Task {
            if self.server != nil {
                _ = await ClaudeLink.run(claude, ["mcp", "remove", "--scope", "user", ClaudeLink.name], timeout: 20)
            }
            var args = ["mcp", "add", "--scope", "user", ClaudeLink.name]
            if let world = Store.world { args += ["-e", "SEARCH_WORLD=\(world)"] }
            args += ["--", python, script.path]
            let out = await ClaudeLink.run(claude, args, timeout: 20)
            readRegistration()
            busy = false
            guard added.done else {
                added = .warning("Claude Code didn't add it" + ((out?.out).map { ": " + ClaudeLink.firstLine($0) } ?? ""))
                done("Claude Code didn't add Search")
                return
            }
            done("Search is added to Claude Code")
            check()
        }
    }

    /// Whether it holds together: Claude Code starts the server, and the
    /// server, started the same way, reaches Search and hears back.
    func check() {
        guard !busy else { return }
        guard let claude = claudePath else { connection = .missing("Claude Code first"); return }
        guard let server else { connection = .missing("Add Search to Claude Code first"); return }
        busy = true
        connection = .checking
        checked = serverSaid
        Task {
            defer { busy = false }
            // Claude Code's own look: it starts the server as a session would.
            let seen = await ClaudeLink.run(claude, ["mcp", "get", ClaudeLink.name], timeout: 45)
            let status = seen?.out.split(separator: "\n").first { $0.contains("Status:") }
                .map { $0.replacingOccurrences(of: "Status:", with: "").trimmingCharacters(in: .whitespaces) } ?? ""
            guard status.contains("Connected") else {
                let issue = seen?.out.split(separator: "\n").first { $0.contains("Issue:") }
                    .map { $0.replacingOccurrences(of: "Issue:", with: "").trimmingCharacters(in: .whitespaces) }
                connection = .warning("Claude Code couldn't start it" + (issue.map { ": \($0)" } ?? (status.isEmpty ? "" : " (\(status))")))
                return
            }
            // Then through the server to Search and back, as a tool call.
            switch await ClaudeLink.roundTrip(server) {
            case .success(let said): connection = .done("Claude Code starts it, and it reaches Search — \(said)")
            case .failure(let why): connection = .warning("Claude Code starts it, but it didn't reach Search: \(why.said)")
            }
        }
    }

    /// Apple's command line tools, Python with them: Apple's own installer.
    func installPython() {
        Task { _ = await ClaudeLink.run("/usr/bin/xcode-select", ["--install"], timeout: 10) }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - finding things

    /// Where Claude Code's installers put it, or wherever your shell finds
    /// it: an app started from the Dock has a PATH of its own, without
    /// what your shell's profile adds.
    private static func findClaude() async -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let known = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                     "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        if let found = known.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let out = await run(shell, ["-lc", "command -v claude"], timeout: 8), out.status == 0 else { return nil }
        let path = firstLine(out.out)
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// A Python 3.7 or later that runs without asking anything. The one in
    /// /usr/bin is only a stand-in until Apple's command line tools are in:
    /// run before, it puts up their installer — so it is tried only when
    /// xcode-select says they are.
    private static func findPython() async -> (path: String, version: String)? {
        var candidates: [String] = []
        if let tools = await run("/usr/bin/xcode-select", ["-p"], timeout: 5), tools.status == 0 { candidates.append("/usr/bin/python3") }
        candidates += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            guard let out = await run(path, ["-c", "import sys; print('%d.%d.%d' % sys.version_info[:3])"], timeout: 10),
                  out.status == 0 else { continue }
            let version = firstLine(out.out)
            let parts = version.split(separator: ".").compactMap { Int($0) }
            if parts.count >= 2, parts[0] == 3, parts[1] >= 7 { return (path, version) }
        }
        return nil
    }

    // MARK: - running things

    struct Ran {
        let status: Int32
        let out: String
    }

    /// A program run off the main thread, its output and errors together,
    /// stopped after `timeout`. Nil when it couldn't start.
    nonisolated static func run(_ path: String, _ args: [String], input: Data? = nil, extra: [String: String] = [:], timeout: Double) async -> Ran? {
        let configDirectory = await MainActor.run { ClaudeLink.configDirectory }
        return await Task.detached(priority: .userInitiated) { () -> Ran? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            var env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
            if let configDirectory { env["CLAUDE_CONFIG_DIR"] = configDirectory.path }
            env.merge(extra) { _, new in new }
            process.environment = env
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            let feed = Pipe()
            process.standardInput = input == nil ? FileHandle.nullDevice : feed
            do { try process.run() } catch { return nil }
            if let input {
                feed.fileHandleForWriting.write(input)
                try? feed.fileHandleForWriting.close()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Ran(status: process.terminationStatus, out: String(decoding: data, as: UTF8.self))
        }.value
    }

    struct Failure: Error {
        let said: String
    }

    /// The registered server started as Claude Code starts it, asked what
    /// tabs Claude can use. Its requests say they come from Settings, so
    /// "last used by Claude" stays Claude's.
    private static func roundTrip(_ server: (command: String, args: [String], env: [String: String])) async -> Result<String, Failure> {
        let lines = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2024-11-05", "capabilities": [:], "clientInfo": ["name": "search-settings", "version": "1"]]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "tabs_context", "arguments": [:]]],
        ]
        var input = Data()
        for line in lines {
            guard let data = try? JSONSerialization.data(withJSONObject: line) else { continue }
            input.append(data)
            input.append(0x0A)
        }
        let command = server.command.hasPrefix("/") ? server.command : "/usr/bin/env"
        let args = server.command.hasPrefix("/") ? server.args : [server.command] + server.args
        var extra = server.env
        extra["SEARCH_MCP_FROM"] = "settings"
        guard let out = await run(command, args, input: input, extra: extra, timeout: 30) else {
            return .failure(Failure(said: "\(server.command) couldn't be started"))
        }
        for line in out.out.split(separator: "\n") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  json["id"] as? Int == 2 else { continue }
            guard let result = json["result"] as? [String: Any] else {
                return .failure(Failure(said: ((json["error"] as? [String: Any])?["message"] as? String) ?? "no answer"))
            }
            let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            if result["isError"] as? Bool == true {
                return .failure(Failure(said: text.replacingOccurrences(of: "Error: ", with: "")))
            }
            let tabs = text.components(separatedBy: "\n\n").first?.split(separator: "\n").filter { !$0.isEmpty }.count ?? 0
            return .success(tabs == 0 ? "no tab of Claude's open yet" : tabs == 1 ? "1 tab Claude can use" : "\(tabs) tabs Claude can use")
        }
        return .failure(Failure(said: out.out.isEmpty ? "the server said nothing" : firstLine(out.out)))
    }

    // MARK: - small things

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A path as a shell reads it: in single quotes when it needs them.
    static func quoted(_ text: String) -> String {
        let plain = text.allSatisfy { $0.isLetter || $0.isNumber || "/._-+@:".contains($0) }
        return plain ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
