import AppKit
import UniformTypeIdentifiers

// Pages on this Mac, and bookmarks in the file every browser reads.
//
// File › Open File… (⌘O) opens a page from this Mac in a tab, as every other
// browser's File menu does; Search already opened one double-clicked in the
// Finder, and nothing but the Finder could get one here. Bookmarks go out as,
// and come in from, the HTML file Chrome, Safari, Firefox and Edge all write
// under "Export bookmarks" — Netscape's format, older than most of the
// browsers that still keep to it.

extension Browser {
    // MARK: - a page on this Mac

    /// What a tab can show from a file. Anything else WebKit would only hand
    /// back as a download of the file you already have.
    private static let pages: [UTType] = [
        .html, .pdf, .plainText, .svg, .image, .xml, .json, .webArchive, UTType("public.xhtml"),
    ].compactMap { $0 }

    /// ⌘O. Each file picked opens in a tab of its own, the last in front; the
    /// first goes into a blank tab you are on rather than beside it.
    func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Browser.pages
        panel.prompt = "Open"
        present(panel) { [weak self] urls in self?.openFiles(urls) }
    }

    func openFiles(_ urls: [URL]) {
        for (index, url) in urls.enumerated() {
            if index == 0 {
                arrive(url)
            } else {
                open(url, foreground: index == urls.count - 1)
            }
        }
    }

    // MARK: - bookmarks, in and out

    /// Bookmarks › Import Bookmarks…: an HTML file another browser wrote,
    /// kept in a folder named after it — importing the same file again puts
    /// that folder back as it now is, rather than adding a second.
    func importBookmarks() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.html]
        panel.prompt = "Import"
        panel.message = "A bookmarks file, as Chrome, Safari, Firefox or Edge export one."
        present(panel) { [weak self] urls in
            guard let file = urls.first else { return }
            self?.importBookmarks(from: file)
        }
    }

    /// How many came in.
    @discardableResult
    func importBookmarks(from file: URL) -> Int {
        guard let data = try? Data(contentsOf: file) else {
            announce("Couldn't read that file")
            return 0
        }
        let found = BookmarkFile.read(BookmarkFile.text(data))
        let count = Bookmarks.count(found.nodes)
        guard count > 0 else {
            announce("No bookmarks in that file")
            return 0
        }
        bookmarks.take(found.nodes, from: file.deletingPathExtension().lastPathComponent)
        announce(count == 1 ? "1 bookmark from \(file.lastPathComponent)" : "\(count) bookmarks from \(file.lastPathComponent)")
        Task { @MainActor in
            for (host, icon) in found.icons { await Favicons.shared.adopt(icon, for: host) }
            self.objectWillChange.send()
        }
        return count
    }

    /// Bookmarks › Export Bookmarks…: every folder and page, in the file any
    /// browser takes in.
    func exportBookmarks() {
        guard !bookmarks.isEmpty else {
            announce("No bookmarks to export")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "Bookmarks.html"
        panel.prompt = "Export"
        present(panel) { [weak self] urls in
            guard let file = urls.first else { return }
            self?.exportBookmarks(to: file)
        }
    }

    /// Whether the file was written.
    @discardableResult
    func exportBookmarks(to file: URL) -> Bool {
        do {
            try Data(BookmarkFile.write(bookmarks.roots).utf8).write(to: file, options: .atomic)
            let count = bookmarks.count
            announce(count == 1 ? "1 bookmark exported" : "\(count) bookmarks exported")
            return true
        } catch {
            announce("Couldn't save \(file.lastPathComponent)")
            return false
        }
    }

    /// Over the window as a sheet, or on its own when there is no window to
    /// put it on.
    private func present(_ panel: NSSavePanel, then use: @escaping ([URL]) -> Void) {
        let answered: (NSApplication.ModalResponse) -> Void = { answer in
            guard answer == .OK else { return }
            use((panel as? NSOpenPanel)?.urls ?? panel.url.map { [$0] } ?? [])
        }
        if let window = Links.window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: answered)
        } else {
            answered(panel.runModal())
        }
    }
}

/// The Netscape bookmarks file: a `<DL>` for each folder, an `<H3>` for its
/// name, an `<A HREF>` for each page. Written as Chrome writes it; read as
/// loosely as the browsers that write it are inconsistent.
enum BookmarkFile {
    // MARK: - writing

    static func write(_ roots: [Bookmark]) -> String {
        var lines = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<!-- This is an automatically generated file.",
            "     It will be read and overwritten.",
            "     DO NOT EDIT! -->",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<TITLE>Bookmarks</TITLE>",
            "<H1>Bookmarks</H1>",
            "<DL><p>",
        ]
        func add(_ nodes: [Bookmark], depth: Int) {
            let indent = String(repeating: "    ", count: depth)
            for node in nodes {
                if let url = node.url {
                    lines.append("\(indent)<DT><A HREF=\"\(escape(url))\">\(escape(node.title))</A>")
                } else {
                    lines.append("\(indent)<DT><H3>\(escape(node.title))</H3>")
                    lines.append("\(indent)<DL><p>")
                    add(node.children ?? [], depth: depth + 1)
                    lines.append("\(indent)</DL><p>")
                }
            }
        }
        add(roots, depth: 1)
        lines.append("</DL><p>")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - reading

    /// The file as text: UTF-8 as every browser writes it now, or the Latin-1
    /// an old export can be in.
    static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// Folders and pages, and the icons the file carried for them (Chrome
    /// and Firefox put each site's in, as a data: address), by host.
    static func read(_ html: String) -> (nodes: [Bookmark], icons: [String: Data]) {
        // Tags only, and the text right after an <H3> or an <A>: every
        // browser's export is one tag per line, but nothing says it must be.
        let tag = try! NSRegularExpression(pattern: "<(/?)(dl|h3|a)\\b([^>]*)>", options: [.caseInsensitive])
        let text = html as NSString
        var levels: [[Bookmark]] = [[]]
        var names: [String?] = []
        var pending: String?
        var icons: [String: Data] = [:]

        func close() {
            let children = levels.removeLast()
            let name = names.popLast() ?? nil
            if let name {
                levels[levels.count - 1].append(.folder(name, children))
            } else {
                levels[levels.count - 1].append(contentsOf: children)
            }
        }

        var at = 0
        while at < text.length, let match = tag.firstMatch(in: html, range: NSRange(location: at, length: text.length - at)) {
            at = match.range.location + match.range.length
            let closing = text.substring(with: match.range(at: 1)) == "/"
            let name = text.substring(with: match.range(at: 2)).lowercased()
            let attributes = text.substring(with: match.range(at: 3))
            switch (name, closing) {
            case ("dl", false):
                levels.append([])
                names.append(pending)
                pending = nil
            case ("dl", true):
                if levels.count > 1 { close() }
            case ("h3", false), ("a", false):
                // What it says: the text up to the next tag, which a title
                // never holds unescaped — so one left unclosed ends there
                // rather than swallowing the lines after it.
                let next = text.range(of: "<", range: NSRange(location: at, length: text.length - at))
                let end = next.location == NSNotFound ? text.length : next.location
                let raw = text.substring(with: NSRange(location: at, length: end - at))
                at = end
                let closer = "</\(name)>"
                if end + closer.utf16.count <= text.length,
                   text.substring(with: NSRange(location: end, length: closer.utf16.count)).lowercased() == closer {
                    at = end + closer.utf16.count
                }
                let title = decode(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                if name == "h3" {
                    pending = title.isEmpty ? "Folder" : title
                } else if let href = value(of: "href", in: attributes), let url = URL(string: decode(href)),
                          let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) {
                    levels[levels.count - 1].append(.site(title, url))
                    if let host = url.host()?.lowercased(), icons[host] == nil, icons.count < 400,
                       let icon = value(of: "icon", in: attributes), let data = picture(icon) {
                        icons[host] = data
                    }
                }
            default:
                break
            }
        }
        // A file cut short still gives what it had.
        while levels.count > 1 { close() }
        return (levels[0], icons)
    }

    /// An attribute's value, quoted either way or not at all.
    private static func value(of name: String, in attributes: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes))
        else { return nil }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: attributes) { return String(attributes[range]) }
        }
        return nil
    }

    /// A base64 data: address's bytes: the only kind of icon worth carrying.
    private static func picture(_ address: String) -> Data? {
        guard address.hasPrefix("data:image/"), let comma = address.firstIndex(of: ","),
              address[..<comma].hasSuffix(";base64")
        else { return nil }
        return Data(base64Encoded: String(address[address.index(after: comma)...]))
    }

    /// The entities a browser writes into a title or an address.
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#39": "'", "nbsp": "\u{00A0}"]
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            guard let semi = after.firstIndex(of: ";"), after.distance(from: after.startIndex, to: semi) <= 10 else {
                out += "&"
                rest = after
                continue
            }
            let entity = String(after[..<semi])
            if let known = named[entity.lowercased()] {
                out += known
            } else if entity.hasPrefix("#x") || entity.hasPrefix("#X"), let code = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                out.unicodeScalars.append(scalar)
            } else if entity.hasPrefix("#"), let code = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(code) {
                out.unicodeScalars.append(scalar)
            } else {
                out += "&" + entity + ";"
            }
            rest = after[after.index(after: semi)...]
        }
        return out + rest
    }
}
