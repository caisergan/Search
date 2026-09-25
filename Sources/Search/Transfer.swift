import AppKit

// Tabs, from one browser to another. Tabs › Transfer Tabs.
//
// In: the tabs another browser has open, read from the file it keeps them
// in so it can put them back at its next launch — the same browsers, and
// the same rule, as Import.swift: its file is read, and it is never asked.
// Nothing to allow, nothing that has to be running, and nothing it notices.
// A browser that is closed has kept the tabs it had when it closed; one
// still running writes them down within a few seconds of a change.
//
// Out: the addresses, handed to the other app the way Finder hands it a
// link, so they open there as new tabs.

extension Chromium {
    struct OpenTab {
        let url: URL
        let title: String
        let pinned: Bool
    }

    /// The browsers on this Mac, for sending tabs to. Looked up once: the
    /// menu is built again at every change in the window, and a browser
    /// installed meanwhile can wait for the next launch. Only one someone
    /// installed: a copy a test tool keeps in a Library folder doesn't count.
    static let apps: [(source: Source, app: URL)] = known.compactMap { source in
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundle),
              !app.path.contains("/Library/")
        else { return nil }
        return (source, app)
    }

    /// The browsers that have kept a session, for bringing tabs from.
    static let sessions: [Source] = known.filter { !$0.sessionFiles.isEmpty }

    /// Every window's tabs, every profile's, in the order they are in there.
    /// Only pages: its own new-tab and settings pages mean nothing here.
    static func openTabs(in source: Source) -> [OpenTab] {
        source.sessionFiles.flatMap { SessionFile.tabs(in: $0) }
    }
}

extension Chromium.Source {
    /// The newest session of each profile. Chromium starts a file at each
    /// launch and keeps the one before; the newest is the one being written.
    var sessionFiles: [URL] {
        let profiles = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return profiles.compactMap { profile in
            let folder = profile.appendingPathComponent("Sessions", isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            // The name ends in the time it was started: the newest sorts last.
            return files.filter { $0.lastPathComponent.hasPrefix("Session_") }
                .max { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
    }
}

/// Chromium's session file. Not a database: a log, "SNSS" and a version,
/// then one command after another — this tab went to that window, went to
/// this page, was closed — each a length, a number saying which command,
/// and its fields. Played back from the top, what is left is what was open.
/// The numbers are Chromium's own (session_service_commands.cc); anything
/// else it writes is skipped by its length, unread.
private enum SessionFile {
    private enum Command: UInt8 {
        case tabWindow = 0
        case tabIndex = 2
        case navigation = 6
        case selectedNavigation = 7
        case windowType = 9
        case pinned = 12
        case tabClosed = 16
        case windowClosed = 17
    }

    private final class Entry {
        var window: Int32 = 0
        var index: Int32 = 0
        var selected: Int32?
        var pinned = false
        var pages: [Int32: (url: String, title: String)] = [:]
    }

    static func tabs(in file: URL) -> [Chromium.OpenTab] {
        // Read whole, in one go: a file being written to is at worst cut
        // short at its last command, which the loop below stops before.
        guard let data = try? Data(contentsOf: file), data.count > 8,
              data.prefix(4) == Data("SNSS".utf8)
        else { return [] }
        let bytes = [UInt8](data)

        var entries: [Int32: Entry] = [:]
        var closedWindows = Set<Int32>()
        // Windows that said what they are, and those of them that are an
        // ordinary window rather than an app's or the inspector's.
        var typed = Set<Int32>()
        var ordinary = Set<Int32>()
        func entry(_ id: Int32) -> Entry {
            if let entry = entries[id] { return entry }
            let entry = Entry()
            entries[id] = entry
            return entry
        }

        var at = 8
        while at + 3 <= bytes.count {
            let size = Int(bytes[at]) | Int(bytes[at + 1]) << 8
            guard size >= 1, at + 2 + size <= bytes.count else { break }
            let fields = Fields(bytes: bytes, start: at + 3, end: at + 2 + size)
            let command = Command(rawValue: bytes[at + 2])
            at += 2 + size

            switch command {
            case .tabWindow:
                if let window = fields.int(0), let tab = fields.int(4) { entry(tab).window = window }
            case .tabIndex:
                if let tab = fields.int(0), let index = fields.int(4) { entry(tab).index = index }
            case .navigation:
                // A pickle: its own length first, then the tab, the page's
                // place in the tab's history, the address, the title.
                if let tab = fields.int(4), let index = fields.int(8), let page = fields.page(from: 12) {
                    entry(tab).pages[index] = page
                }
            case .selectedNavigation:
                if let tab = fields.int(0), let index = fields.int(4) { entry(tab).selected = index }
            case .windowType:
                if let window = fields.int(0), let type = fields.int(4) {
                    typed.insert(window)
                    if type == 0 { ordinary.insert(window) }
                }
            case .pinned:
                if let tab = fields.int(0), let flag = fields.byte(4) { entry(tab).pinned = flag != 0 }
            case .tabClosed:
                if let tab = fields.int(0) { entries[tab] = nil }
            case .windowClosed:
                if let window = fields.int(0) { closedWindows.insert(window) }
            case nil:
                break
            }
        }

        let open = entries.values.filter {
            !closedWindows.contains($0.window) && (!typed.contains($0.window) || ordinary.contains($0.window))
        }
        return open
            .sorted { ($0.window, $0.index) < ($1.window, $1.index) }
            .compactMap { entry in
                // The page it is on, not the last one it went to: after going
                // back, the ones ahead are still in its history.
                let page = entry.selected.flatMap { entry.pages[$0] }
                    ?? entry.pages.max { $0.key < $1.key }?.value
                guard let page, let url = URL(string: page.url),
                      url.scheme == "http" || url.scheme == "https"
                else { return nil }
                return Chromium.OpenTab(url: url, title: page.title, pinned: entry.pinned)
            }
    }

    /// One command's fields, read little-endian, never past its end.
    private struct Fields {
        let bytes: [UInt8]
        let start: Int
        let end: Int

        func byte(_ offset: Int) -> UInt8? {
            start + offset < end ? bytes[start + offset] : nil
        }

        func int(_ offset: Int) -> Int32? {
            let i = start + offset
            guard offset >= 0, i + 4 <= end else { return nil }
            let raw = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
            return Int32(bitPattern: raw)
        }

        /// An address, in UTF-8, then a title, in UTF-16; each after its
        /// length, and each padded out to four bytes.
        func page(from offset: Int) -> (url: String, title: String)? {
            guard let length = int(offset), length >= 0 else { return nil }
            let urlStart = start + offset + 4
            let urlEnd = urlStart + Int(length)
            guard urlEnd <= end else { return nil }
            let url = String(decoding: bytes[urlStart..<urlEnd], as: UTF8.self)

            var title = ""
            let titleAt = (urlEnd - start + 3) & ~3
            if let units = int(titleAt), units >= 0, start + titleAt + 4 + Int(units) * 2 <= end {
                let from = start + titleAt + 4
                let code = stride(from: from, to: from + Int(units) * 2, by: 2).map {
                    UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8
                }
                title = String(decoding: code, as: UTF16.self)
            }
            return (url, title)
        }
    }
}
