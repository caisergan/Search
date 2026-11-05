import Foundation

/// Tabs of one site, together under a line of their own in the column. What
/// makes them one is the domain, not the address: docs.google.com and
/// drive.google.com go together, as do a site's cms. and its dev-cms.
///
/// A group lives with its space's row and is written down with it (see
/// Session). Its tabs stay ordinary tabs in the row, side by side, each saying
/// which group it is in (Tab.group): ⌘1–⌘9, ⇧⌘] and the row across the top
/// never hear of groups.
struct TabGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    /// The domain that brought it together, which a new tab of the same site
    /// is matched against, whatever the group has been renamed to.
    let site: String
    var name: String
    /// Folded is how a group starts: making one is for clearing the column.
    var folded = true

    /// The domain of an address a tab can be grouped by: a page of the web,
    /// which leaves out an extension's pages, files and empty tabs.
    static func site(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return Vault.registrable(host)
    }

    /// A site's name as its own pages write it, read off their titles: up to
    /// three words that spell the domain's first label. YouTube for
    /// youtube.com, Ege Asırlık for egeasirlik.com.tr. Pages that never say
    /// get the label with a capital; a bare address, the address.
    static func name(of site: String, from titles: [String]) -> String {
        guard let first = site.split(separator: ".").first.map(String.init) else { return site }
        if first.allSatisfy(\.isNumber) { return site }
        let label = plain(first)
        for title in titles {
            let words = title.components(separatedBy: nameBreaks).filter { !$0.isEmpty }
            for start in words.indices {
                for count in 1...3 where start + count <= words.count {
                    let run = words[start..<(start + count)]
                    if plain(run.joined()) == label { return run.joined(separator: " ") }
                }
            }
        }
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    /// What parts one word of a title from the next. A hyphen does: "X-Ray"
    /// is no name for x.com, and "E-Tablolar" none for google.com.
    private static let nameBreaks = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "·•|/:,;()[]–—-"))

    /// A word as a domain would write it. Turkish's dotless ı has no accent
    /// for folding to take off.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "İ", with: "i")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }
}

/// A group just closed with its cross, for as long as its line offers Undo.
/// Only what it takes to bring the tabs back: their pages are gone already.
struct ClosedGroup: Identifiable {
    struct Page {
        let url: URL
        let title: String
        let name: String?
        /// The page's back list and scroll, as a reopened tab gets them.
        let memory: Any?
    }

    let id = UUID()
    let group: TabGroup
    let pages: [Page]
    /// Where it stood among the groups, which is where its line stays.
    let at: Int
    /// Which page was on screen, if one of these was.
    let looked: Int?
    /// The entries closing them added to Recently Closed, to take back.
    let ghosts: [Browser.Ghost.ID]

    /// How long the line stays. Long enough to see what just happened.
    static let patience: TimeInterval = 6
}
