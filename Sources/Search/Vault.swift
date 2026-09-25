import Foundation
import Security
import LocalAuthentication

// Where passwords live: the macOS keychain, under this app's own name, as
// internet passwords keyed by site and account. Nothing is written to disk by
// this app in any other form, and nothing is ever logged.
//
// This is the same coffer Safari's are in, but not the same drawer: Apple keeps
// Safari's behind an entitlement no other browser gets. So these are Office
// Browser's — in the system's vault, unlocked with the Mac, shown with Touch ID.

struct Login: Identifiable, Equatable, Hashable {
    var host: String
    var user: String
    /// Empty on anything read back from the keychain: lists never carry a
    /// secret. `Vault.password(of:)` fetches it, at the moment it is used.
    var password: String
    /// When it was last used to sign in, if known. Newest first in lists.
    var used: Date?
    /// Kept from a page sent in the clear, over plain http. Only these are
    /// offered on such a page: one kept from https, or from before this was
    /// written down, is never handed to a page anyone on the way could have
    /// written.
    var clear = false

    var id: String { host + "\u{1}" + user }
}

enum Vault {
    /// What every item of ours is tagged with. A test run tags its own, so a
    /// password saved while trying something never sits among the real ones.
    private static let label = Store.world.map { "Search (\($0))" } ?? "Search"

    // MARK: - reading

    /// The keychain will list many items, or hand over one secret — not
    /// both in one call. Asked for every item's data at once it answers
    /// errSecParam, and it did so quietly enough that for a while this app
    /// saved passwords it could never read back.
    ///
    /// And a secret is never read to make a list. Each item carries its own
    /// list of apps allowed to read it, so a build signed differently from
    /// the one that saved it gets a macOS prompt per item, per read — and a
    /// list read every time the caret entered a field, the page scrolled or
    /// the prompt itself took focus away and gave it back was ten prompts in
    /// a row, Deny or not. Names and sites are readable without asking; the
    /// secret is fetched for the one account you picked, when you pick it.

    /// What is kept for a host, exactly. See `logins(matching:)` for the
    /// version that also looks across a site's subdomains.
    static func logins(for host: String) -> [Login] {
        rows(where: [kSecAttrServer as String: host]).compactMap(login(from:))
    }

    /// The keychain matches a server name exactly, and a sign-in rarely lives
    /// on the page you saved it from — accounts.example.com asks, and the
    /// password was kept for example.com. So the site is matched as a site:
    /// the host first, then anything sharing its registrable domain.
    static func logins(matching host: String) -> [Login] {
        let domain = registrable(host)
        let exact = logins(for: host)
        let wider = rows(where: [:])
            .filter { ($0[kSecAttrServer as String] as? String).map { $0 != host && registrable($0) == domain } ?? false }
            .compactMap(login(from:))
        return (exact + wider).sorted { ($0.used ?? .distantPast) > ($1.used ?? .distantPast) }
    }

    /// Everything this app holds, for the list. Read on demand and never kept
    /// in a property.
    static func all() -> [Login] {
        rows(where: [:]).compactMap(login(from:))
            .sorted { $0.host == $1.host ? $0.user < $1.user : $0.host < $1.host }
    }

    /// The items' attributes — no secrets — narrowed by whatever is given.
    private static func rows(where extra: [String: Any]) -> [[String: Any]] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        extra.forEach { query[$0] = $1 }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else {
            // Nothing kept reads as "not found"; anything else is worth a
            // line in the log, because the panel will only say "nothing".
            if status != errSecItemNotFound { NSLog("Vault: keychain list failed (%d)", status) }
            return []
        }
        return rows
    }

    /// Accounts whose secret the keychain refused this session — you denied
    /// the prompt. Asked again only when you ask for that account yourself.
    private static var refused: Set<String> = []

    /// The secret of one kept account, read now. `asked` is whether you
    /// asked for it — picked it, copied it, showed it — rather than Search
    /// wanting it on its own, which a Deny earlier this session rules out.
    static func password(of login: Login, asked: Bool = true) -> String? {
        if !asked && refused.contains(login.id) { return nil }
        return secret(host: login.host, user: login.user)
    }

    /// One item's secret, by the two things that name it.
    private static func secret(host: String, user: String) -> String? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &out)
        let id = Login(host: host, user: user, password: "").id
        guard status == errSecSuccess, let data = out as? Data else {
            if status == errSecAuthFailed || status == errSecUserCanceled || status == errSecInteractionNotAllowed {
                refused.insert(id)
            } else if status != errSecItemNotFound {
                NSLog("Vault: keychain read failed (%d)", status)
            }
            return nil
        }
        refused.remove(id)
        return String(data: data, encoding: .utf8)
    }

    private static func login(from row: [String: Any]) -> Login? {
        guard let host = row[kSecAttrServer as String] as? String,
              let user = row[kSecAttrAccount as String] as? String
        else { return nil }
        // The keychain has no "last used" of its own: it is in the settings
        // (see `touch`), or, for an item saved before, in the comment.
        let id = Login(host: host, user: user, password: "").id
        let touched = Store.settings.dictionary(forKey: usedKey) as? [String: Double] ?? [:]
        let used = (touched[id] ?? (row[kSecAttrComment as String] as? String).flatMap(Double.init))
            .map(Date.init(timeIntervalSince1970:))
        let clear = (row[kSecAttrProtocol as String] as? String) == (kSecAttrProtocolHTTP as String) || touched["http\u{1}" + id] != nil
        return Login(host: host, user: user, password: "", used: used, clear: clear)
    }

    // MARK: - writing

    @discardableResult
    static func save(host: String, user: String, password: String, used: Date? = nil, clear: Bool = false) -> Bool {
        guard !host.isEmpty, !password.isEmpty,
              let data = password.data(using: .utf8)
        else { return false }

        // Ours only. Server and account alone also match what other apps
        // keep for the same site — git's token for github.com under your
        // username — and an update would write this password over it.
        let identity: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecAttrLabel as String: label,
        ]
        // A web form's, which also keeps ours apart from another app's item
        // in the keychain's eyes: one for the same server, account and
        // protocol — git's — makes adding ours fail as a duplicate.
        var fields: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: label,
            kSecAttrAuthenticationType as String: kSecAttrAuthenticationTypeHTMLForm,
            kSecAttrProtocol as String: clear ? kSecAttrProtocolHTTP : kSecAttrProtocolHTTPS,
        ]
        if let used { fields[kSecAttrComment as String] = String(used.timeIntervalSince1970) }

        let status = SecItemUpdate(identity as CFDictionary, fields as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var fresh = identity.merging(fields) { _, new in new }
        fresh[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(fresh as CFDictionary, nil) == errSecSuccess
    }

    /// It was just used to sign in, over http or https. Lists put it first
    /// from now on, and it is offered where it was last used.
    ///
    /// Kept in the settings, not written onto the keychain item: an item
    /// saved by another build of Search — one signed differently, an older
    /// one, one brought in from Chrome — lets this one change it only after
    /// asking for the Mac's password, and asked again at every sign-in,
    /// "Always Allow" or not. Nothing here needs the keychain.
    static func touch(_ login: Login) {
        var used = Store.settings.dictionary(forKey: usedKey) as? [String: Double] ?? [:]
        used[login.id] = Date().timeIntervalSince1970
        if login.clear { used["http\u{1}" + login.id] = 1 } else { used["http\u{1}" + login.id] = nil }
        Store.settings.set(used, forKey: usedKey)
    }

    private static let usedKey = "passwords.used"

    static func forget(host: String, user: String) {
        SecItemDelete([
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecAttrLabel as String: label,
        ] as CFDictionary)
    }

    // MARK: - sites that asked not to be asked

    private static let neverKey = "passwords.never"

    static var never: Set<String> {
        get { Set(Store.settings.stringArray(forKey: neverKey) ?? []) }
        set { Store.settings.set(Array(newValue).sorted(), forKey: neverKey) }
    }

    static func never(_ host: String) { never.insert(host) }
    static func isNever(_ host: String) -> Bool { never.contains(host) || never.contains(registrable(host)) }

    // MARK: - showing one

    /// A password is shown only to the person the Mac belongs to. Touch ID,
    /// the watch, or the account password — whatever the Mac itself takes.
    static func prove(_ reason: String, _ done: @escaping (Bool) -> Void) {
        let context = LAContext()
        var trouble: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &trouble) else {
            // No way to ask at all — a Mac with no password set. Then there is
            // nothing to prove.
            done(true)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }

    // MARK: - the site behind a host

    /// example.com for www.example.com and accounts.example.com; bbc.co.uk
    /// stays bbc.co.uk.
    static func registrable(_ host: String) -> String {
        Registrable.domain(of: host, isSuffix: Passkeys.publicSuffix.map { test in { test($0 as CFString) } })
    }

    static func host(of text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if !value.contains("://") { value = "https://" + value }
        guard let host = URL(string: value)?.host()?.lowercased() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - taking in an export

    /// A CSV as Google Password Manager, Chrome or Dia write it: name, url,
    /// username, password, note. Read once, put in the keychain, and the file
    /// is yours to delete — this never keeps a copy of it.
    static func take(csv text: String) -> (kept: Int, skipped: Int) {
        var rows = parse(csv: text)
        guard !rows.isEmpty else { return (0, 0) }

        let header = rows.removeFirst().map { $0.lowercased() }
        func column(_ names: [String]) -> Int? {
            header.firstIndex { names.contains($0) }
        }
        guard let urlAt = column(["url", "login_uri", "website", "site"]),
              let userAt = column(["username", "login_username", "user", "email"]),
              let passAt = column(["password", "login_password"])
        else { return (0, rows.count) }

        var kept = 0, skipped = 0
        for row in rows {
            guard row.count > max(urlAt, max(userAt, passAt)) else {
                skipped += 1
                continue
            }
            let host = self.host(of: row[urlAt])
            let password = row[passAt]
            guard !host.isEmpty, !password.isEmpty else {
                skipped += 1
                continue
            }
            let clear = row[urlAt].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
            save(host: host, user: row[userAt], password: password, clear: clear) ? (kept += 1) : (skipped += 1)
        }
        return (kept, skipped)
    }

    /// Quoted fields, doubled quotes inside them, and newlines inside those —
    /// all three turn up in a real export.
    private static func parse(csv text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex

        while index < text.endIndex {
            let c = text[index]
            if quoted {
                if c == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n", "\r":
                    row.append(field)
                    field = ""
                    if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
            index = text.index(after: index)
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
}
