import Foundation

// Where you have been, so the field can finish the address for you. Kept in one
// small file next to the app's own settings, written a moment after a visit
// rather than on every keystroke.

struct Suggestion: Identifiable, Equatable {
    /// What you would have typed to get here: no scheme, no www.
    let key: String
    let title: String
    let url: URL
    let kind: Kind
    /// Set when this is a page you already have open somewhere.
    var tab: UUID?

    enum Kind {
        /// A page that is open right now.
        case open
        /// Somewhere you have actually been.
        case visited
        /// A bookmark you haven't opened from here yet — brought in from
        /// another browser, say.
        case bookmark
        /// One of the well-known addresses the field knows from the start.
        case known
        /// Not a place at all — words, and an engine to ask.
        case search
    }

    var id: String { key }
}

/// What was typed, taken as words. A place matches when every word turns up
/// in its title or its address, in any order — "github search" finds
/// github.com/driceroland/Search, as it would in Zen or Firefox. Case and
/// accents don't count: "urun katalogu" finds "Ürün kataloğu".
struct Words {
    /// How well a place holds the words. Every word beginning a word of its
    /// own is what was meant; one buried inside a longer word less often is.
    enum Fit {
        case inside
        case starts
    }

    /// Each word, folded, as UTF-8.
    let all: [[UInt8]]

    init(_ typed: String) {
        all = Words.lower(typed).split(whereSeparator: \.isWhitespace).map { Array($0.utf8) }
    }

    var isEmpty: Bool { all.isEmpty }

    /// How `text` (see `fold`) holds every word, if it does. A word of one or
    /// two letters only counts at the start of a word: "x" found inside every
    /// name with an x in it answers nothing. A single letter on its own is
    /// the start of an address, and only addresses answer it — every title
    /// and path has a word beginning with it somewhere.
    func fit(in text: [UInt8]) -> Fit? {
        guard all.contains(where: { $0.count > 1 }) else { return nil }
        var fit = Fit.starts
        for word in all {
            switch Words.find(word, in: text) {
            case nil:
                return nil
            case .starts:
                continue
            case .inside:
                guard word.count >= 3 else { return nil }
                fit = .inside
            }
        }
        return fit
    }

    /// A title or an address as `fit(in:)` reads it: lowercase, without
    /// accents, as UTF-8 — compared byte for byte, which is what keeps a
    /// key press quick over ten thousand places.
    static func fold(_ text: String) -> [UInt8] {
        Array(lower(text).utf8)
    }

    /// The dotless ı is a letter of its own rather than an accented i, so
    /// folding leaves it alone; typed on a keyboard without it, it is an i.
    private static func lower(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ı", with: "i")
    }

    /// Whether `word` begins a word of `text`, is only inside one, or isn't
    /// there at all.
    private static func find(_ word: [UInt8], in text: [UInt8]) -> Fit? {
        text.withUnsafeBytes { hay in
            word.withUnsafeBytes { needle in
                guard let base = hay.baseAddress, let sought = needle.baseAddress else { return nil }
                var found: Fit?
                var from = 0
                while from < hay.count,
                      let hit = memmem(base + from, hay.count - from, sought, needle.count) {
                    let at = base.distance(to: UnsafeRawPointer(hit))
                    if at == 0 || !isWordByte(text[at - 1]) { return .starts }
                    found = .inside
                    from = at + 1
                }
                return found
            }
        }
    }

    /// A byte of a letter or a digit. Past ASCII every byte counts as one:
    /// folding lowers only what it can to ASCII, and what it leaves — ß, a
    /// Cyrillic or a Chinese word — is letters far more often than a dash.
    private static func isWordByte(_ byte: UInt8) -> Bool {
        byte >= 0x80 || (0x30...0x39).contains(byte) || (0x61...0x7A).contains(byte)
    }
}

private struct Visit: Codable {
    var url: String
    var key: String
    var title: String
    var count: Int
    var last: Date
}

@MainActor
final class History: ObservableObject {
    private var visits: [String: Visit] = [:] {
        didSet {
            recentCache = nil
            objectWillChange.send()
        }
    }
    /// The last few places, as the History menu lists them. The menu bar is
    /// drawn again whenever anything in the window changes — every key typed
    /// into the address field included — and sorting the whole history for
    /// it each time cost more than everything else a key press does.
    private var recentCache: [Trace]?
    /// Each place's address and title, folded for `Words`, kept between key
    /// presses rather than folded again for every place on every key. Checked
    /// against the title it was made from, the one part of a place that
    /// changes.
    private var folded: [String: (title: String, text: [UInt8])] = [:]
    /// See `places(of:)`.
    private var marked: (from: [Bookmark], places: [String: (title: String, url: URL)])?
    private var saving = false

    init() { load() }

    // MARK: - which place

    /// What a page is kept under: its address without the scheme, the www or
    /// the #, but with its query — youtube.com/watch?v=… is a different video
    /// for every v, and google.com/search?q=… a different search for every q.
    /// The query keeps its case, as its values do. Only the parameters that
    /// say how you got there are dropped, so a link from a newsletter is the
    /// same place as the page itself.
    static func key(for url: URL) -> String {
        let place = Address.pretty(url).lowercased()
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems
        else { return place }
        let query = items
            .filter { !History.isTrail($0.name) }
            .map { item in item.value.map { item.name + "=" + $0 } ?? item.name }
            .joined(separator: "&")
        guard !query.isEmpty else { return place }
        // github.com/?tab=x, not github.com?tab=x: a key without a slash is
        // a site's front door, and this is a page of it.
        return (place.contains("/") ? place : place + "/") + "?" + query
    }

    /// Campaign and click tags, added by whoever sent the link.
    private static func isTrail(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.hasPrefix("utm_") || trails.contains(name)
    }

    private static let trails: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid",
        "mc_cid", "mc_eid", "igshid", "yclid", "_ga", "_gl",
    ]

    // MARK: - writing

    func record(_ url: URL, title: String) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        let key = History.key(for: url)
        guard !key.isEmpty else { return }

        // Reading a deep page is also, in the way that matters here, another
        // visit to the site. Without this, typing three letters offers the
        // article you happened to open last week rather than the front page —
        // and nobody types a domain meaning to land halfway down it.
        if let host = url.host(), key.contains("/") {
            let root = (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host).lowercased()
            var home = visits[root] ?? Visit(
                url: "https://" + root + "/", key: root, title: "", count: 0, last: Date()
            )
            home.count += 1
            home.last = Date()
            visits[root] = home
        }

        if var seen = visits[key] {
            seen.count += 1
            seen.last = Date()
            seen.url = url.absoluteString
            if !title.isEmpty { seen.title = title }
            visits[key] = seen
        } else {
            visits[key] = Visit(
                url: url.absoluteString,
                key: key,
                title: title,
                count: 1,
                last: Date()
            )
        }
        save()
    }

    /// Somewhere another browser has been. Counted as it was counted there,
    /// so a site visited daily for a year outranks one seen once — the day
    /// you switch, the field already knows you.
    func take(_ url: URL, title: String, count: Int, last: Date) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        let key = History.key(for: url)
        guard !key.isEmpty else { return }
        if var seen = visits[key] {
            seen.count += count
            if last > seen.last { seen.last = last }
            if seen.title.isEmpty { seen.title = title }
            visits[key] = seen
        } else {
            visits[key] = Visit(url: url.absoluteString, key: key, title: title, count: count, last: last)
        }
    }

    /// After a batch of `take`s.
    func settle() { save() }

    /// A page's title usually lands a beat after the page does.
    func retitle(_ url: URL, _ title: String) {
        let key = History.key(for: url)
        guard !title.isEmpty, var seen = visits[key], seen.title != title else { return }
        seen.title = title
        visits[key] = seen
        save()
    }

    func forget() {
        visits = [:]
        folded = [:]
        save()
    }

    /// Everywhere you have been, newest first, for the window that shows it.
    struct Trace: Identifiable, Equatable {
        let key: String
        let title: String
        let url: URL
        let last: Date
        let count: Int

        var id: String { key }
    }

    func everything(matching typed: String = "") -> [Trace] {
        let words = Words(typed)
        return visits.values
            // Every visit to a page also credits its domain, so the address
            // field can offer the front door. Those credits have no title of
            // their own, and in a list of where you have been they are a second
            // copy of every line.
            .filter { !($0.title.isEmpty && !$0.key.contains("/")) }
            .filter { words.isEmpty || words.fit(in: text($0.key, $0.title)) != nil }
            .sorted { $0.last > $1.last }
            .compactMap { visit in
                URL(string: visit.url).map {
                    Trace(
                        key: visit.key,
                        title: visit.title,
                        url: $0,
                        last: visit.last,
                        count: visit.count
                    )
                }
            }
    }

    func forget(_ key: String) {
        visits[key] = nil
        folded[key] = nil
        save()
    }

    /// The last eight places, newest first; worked out again only once the
    /// history has changed.
    func recent() -> [Trace] {
        if let recentCache { return recentCache }
        let made = Array(everything().prefix(8))
        recentCache = made
        return made
    }

    // MARK: - reading

    /// Best matches first. A place you have been always beats a place the app
    /// merely knows the name of, and among places you have been, one you go to
    /// often and recently beats one you saw once in March. A bookmark is a
    /// place kept on purpose: a step ahead of one that matches as well, and
    /// offered even before it has been visited from here.
    func suggestions(for typed: String, limit: Int = 5, bookmarks: [Bookmark] = []) -> [Suggestion] {
        let needle = strip(typed)
        // An empty field proposes nothing. A list of guesses in front of
        // someone who has not yet said what they want is noise, and it is in
        // the way of the one thing they came here to do.
        guard !needle.isEmpty else { return [] }

        let words = Words(needle)
        let now = Date()
        let kept = places(of: bookmarks)
        var scored: [(Suggestion, Double)] = []

        for visit in visits.values {
            guard let rank = rank(visit.key, text(visit.key, visit.title), needle, words),
                  let url = URL(string: visit.url),
                  // The search row under what was typed is already that page;
                  // every search ever made, offered back, would bury the
                  // places among them.
                  !Engine.isResults(url)
            else { continue }
            scored.append((
                Suggestion(key: visit.key, title: visit.title, url: url, kind: .visited),
                rank + 4 + standing(visit, now: now) + (kept[visit.key] == nil ? 0 : 1)
            ))
        }

        for (key, bookmark) in kept where visits[key] == nil {
            guard let rank = rank(key, text(key, bookmark.title), needle, words) else { continue }
            scored.append((
                Suggestion(key: key, title: bookmark.title, url: bookmark.url, kind: .bookmark),
                rank + 4 + 1
            ))
        }

        // Only where memory has nothing to offer. A list of famous websites is
        // a poor substitute for knowing where someone actually goes.
        for known in History.known where visits[known.0] == nil && kept[known.0] == nil {
            guard let rank = rank(known.0, text(known.0, known.1), needle, words) else { continue }
            guard let url = URL(string: "https://" + known.0) else { continue }
            scored.append((
                Suggestion(key: known.0, title: known.1, url: url, kind: .known),
                rank
            ))
        }

        return scored
            .sorted { $0.1 == $1.1 ? $0.0.key.count < $1.0.key.count : $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// What the field should draw greyed out after the caret: the rest of the
    /// best match, or nothing if it doesn't carry on from what was typed.
    func completion(for typed: String, among options: [Suggestion]) -> String? {
        let lower = typed.lowercased()
        guard !lower.isEmpty, lower.count >= 2 else { return nil }
        guard let hit = options.first(where: { $0.key.hasPrefix(lower) }) else { return nil }
        let rest = String(hit.key.dropFirst(lower.count))
        return rest.isEmpty ? nil : rest
    }

    /// How much a place is yours: frecency, plus a preference for a front
    /// door over a room inside it — a bare domain is what a bare domain typed
    /// into a field means. Counted in orders of magnitude, so a site opened
    /// four thousand times sits ahead of one opened forty without drowning
    /// how well each matches what was typed.
    private func standing(_ visit: Visit, now: Date) -> Double {
        log1p(frecency(visit, now: now)) + (visit.key.contains("/") ? 0 : 1.5)
    }

    /// Where the match falls decides most of the ordering: the start of the
    /// host is what people mean when they type an address. Then the words,
    /// in any order, beginning words of the title or the address; then the
    /// middle of a host; a word buried inside a longer one last. "blog" can
    /// find six articles from three sites this way, but only below every
    /// site called blog-something.
    private func rank(_ key: String, _ text: [UInt8], _ needle: String, _ words: Words) -> Double? {
        if key.hasPrefix(needle) { return 6 }
        // Read in place: this runs for every place in the history on every
        // key, and splitting each key into new strings was most of its cost.
        let host = key[..<(key.firstIndex(of: "/") ?? key.endIndex)]
        // "hub" finding github.com, once the "git" has been skipped.
        if let dot = host.firstIndex(of: "."), host[host.index(after: dot)...].hasPrefix(needle) { return 3 }
        let fit = words.fit(in: text)
        if fit == .starts { return 2.5 }
        // Only from two letters up. A single letter matching anywhere inside
        // a name turns "x" into example.com and netflix.com, which is not what
        // anybody meant by it.
        if needle.count >= 2, host.contains(needle) { return 2 }
        return fit == .inside ? 1 : nil
    }

    /// The bookmarks by the place each one is, the first of any two that are
    /// the same place. Worked out again when the bookmarks change, not on
    /// every key: an imported list can run to thousands.
    private func places(of bookmarks: [Bookmark]) -> [String: (title: String, url: URL)] {
        if let marked, marked.from == bookmarks { return marked.places }
        var places: [String: (title: String, url: URL)] = [:]
        for bookmark in bookmarks {
            guard let url = bookmark.url.flatMap(URL.init(string:)) else { continue }
            let key = History.key(for: url)
            if places[key] == nil { places[key] = (bookmark.title, url) }
        }
        marked = (bookmarks, places)
        return places
    }

    /// A place's address and title, folded for `Words`. The address is read
    /// with its percent escapes undone, so a word in a path matches as typed.
    private func text(_ key: String, _ title: String) -> [UInt8] {
        if let made = folded[key], made.title == title { return made.text }
        let text = Words.fold((key.removingPercentEncoding ?? key) + " " + title)
        folded[key] = (title, text)
        return text
    }

    /// Often, and lately. A month-old visit counts for about a third of a
    /// fresh one, which is roughly how long a habit takes to stop being one.
    private func frecency(_ visit: Visit, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(visit.last) / 86_400)
        return Double(visit.count) * exp(-days / 30)
    }

    private func strip(_ typed: String) -> String {
        var text = typed.trimmingCharacters(in: .whitespaces).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        return text
    }

    // MARK: - the file

    private static var folder: URL { Store.folder }
    private static var file: URL { Store.file("history.json") }

    private func load() {
        guard let data = try? Data(contentsOf: History.file) else { return }
        guard let list = try? JSONDecoder().decode([Visit].self, from: data) else {
            Store.quarantine(History.file)
            return
        }
        // Keys written by an older Search can meet under the new rule:
        // they are merged, never trusted to be unique.
        var moved = false
        let kept = list.map { saved in
            var visit = saved
            // Never a front door: its count is the whole site's, and it stays
            // the site's whichever address it last went to.
            guard visit.key.contains("/"), let url = URL(string: visit.url) else { return (visit.key, visit) }
            let key = History.key(for: url)
            if key != visit.key {
                // Kept before the query counted, every video of a site or
                // every search was one place, counting the visits of them all.
                // Its address is the last of them, and it keeps one visit:
                // the rest can't be told apart any more.
                if key.contains("?"), !visit.key.contains("?") { visit.count = 1 }
                visit.key = key
                moved = true
            }
            return (visit.key, visit)
        }
        visits = Dictionary(kept, uniquingKeysWith: { a, b in
            var newer = a.last >= b.last ? a : b
            newer.count = a.count + b.count
            return newer
        })
        if moved { save() }
    }

    /// Coalesced: a busy minute of browsing writes the file once, not thirty
    /// times, and never on the main thread.
    private func save() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            saving = false
            let now = Date()
            // A cap, so the file can't grow without end. What goes is what has
            // been visited least and longest ago. Ten thousand, now that each
            // video and each search is a place of its own: 2.5 MB, read in
            // about 20 ms at launch.
            let list = self.visits.values
                .sorted { self.frecency($0, now: now) > self.frecency($1, now: now) }
                .prefix(10_000)
                .map { $0 }
            DispatchQueue.global(qos: .utility).async {
                guard let data = try? JSONEncoder().encode(list) else { return }
                try? FileManager.default.createDirectory(
                    at: History.folder, withIntermediateDirectories: true
                )
                try? data.write(to: History.file, options: .atomic)
            }
        }
    }

    /// Somewhere to start on the first day, before there is any history to go
    /// on. Ranked below anything actually visited, and dropped from the list
    /// the moment you have been there yourself.
    private static let known: [(String, String)] = [
        ("google.com", "Google"), ("mail.google.com", "Gmail"),
        ("drive.google.com", "Google Drive"), ("calendar.google.com", "Google Calendar"),
        ("maps.google.com", "Google Maps"), ("youtube.com", "YouTube"),
        ("github.com", "GitHub"), ("figma.com", "Figma"), ("vercel.com", "Vercel"),
        ("notion.so", "Notion"), ("linear.app", "Linear"), ("slack.com", "Slack"),
        ("discord.com", "Discord"), ("x.com", "X"), ("linkedin.com", "LinkedIn"),
        ("instagram.com", "Instagram"), ("reddit.com", "Reddit"),
        ("news.ycombinator.com", "Hacker News"), ("stackoverflow.com", "Stack Overflow"),
        ("claude.ai", "Claude"), ("chatgpt.com", "ChatGPT"),
        ("dribbble.com", "Dribbble"), ("behance.net", "Behance"),
        ("awwwards.com", "Awwwards"), ("mobbin.com", "Mobbin"),
        ("siteinspire.com", "SiteInspire"), ("are.na", "Are.na"),
        ("pinterest.com", "Pinterest"), ("framer.com", "Framer"),
        ("webflow.com", "Webflow"), ("developer.apple.com", "Apple Developer"),
        ("swift.org", "Swift"), ("npmjs.com", "npm"), ("supabase.com", "Supabase"),
        ("stripe.com", "Stripe"), ("shopify.com", "Shopify"),
        ("cloudflare.com", "Cloudflare"), ("netlify.com", "Netlify"),
        ("apple.com", "Apple"), ("spotify.com", "Spotify"), ("netflix.com", "Netflix"),
        ("wikipedia.org", "Wikipedia"), ("deepl.com", "DeepL"), ("loom.com", "Loom"),
        ("amazon.fr", "Amazon"), ("leboncoin.fr", "leboncoin"), ("lemonde.fr", "Le Monde"),
    ]
}
