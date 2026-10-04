import AppKit
import NaturalLanguage
import SwiftUI
import Translation
import WebKit

// A page in another language, in yours — translated on this Mac by macOS's
// own translation, as Safari does it. The page's words never go to a server
// to be read; the first time a language is wanted, macOS offers to download
// it, once.
//
// When a page has loaded, its language is read from its own words. One in a
// language you don't read is offered at the top of the page: what it is in
// and what it would be translated into, each a menu — the first to put right
// a language read wrong, the second for any language macOS translates, kept
// for the pages after — and a menu of rules beside them: always or never for
// the language, always or never for the site. View › Translate, or the
// site's card, does it any time. The page is translated from the top down,
// in batches, as the text is; what it adds afterwards — a feed going on, a
// reply opening — is translated as it arrives. Show Original puts back every
// word as it was.
//
// A test run translates nothing for real: it marks each piece instead, so the
// page's side can be checked without asking macOS for anything.

/// What a page was read to be written in, or what you said it is.
struct PageLanguage: Equatable {
    let code: String
    /// What its words said, before you put it right.
    var detected: String?
    var corrected: Bool { code != detected }
    var name: String { Translator.name(of: code) }
}

/// A language or a site translated as its pages load, or never offered.
enum TranslateRule: String {
    case always, never
}

/// A line of one of the translator's menus (see TranslateMenu).
enum TranslateEntry {
    case heading(String)
    case item(String, on: Bool = false, badge: String? = nil, act: () -> Void)
    case separator
}

@MainActor
final class Translator: ObservableObject {
    static let shared = Translator()

    /// What each tab's page is in, as far as its words say.
    @Published private(set) var read: [Tab.ID: PageLanguage] = [:]
    /// Tabs whose page is translated, or being.
    @Published private(set) var translated: Set<Tab.ID> = []
    /// The page on screen offered a translation.
    @Published private(set) var offered: Tab.ID?
    /// A page translated a moment ago, which says so — what from, and the
    /// way back — before it gets out of the way. A translation nobody asked
    /// for on this page, by a rule, is never one you can't see happened.
    @Published private(set) var settled: Tab.ID?
    /// The language a page just translated is asked about: you have
    /// translated it by hand often enough to want it always.
    @Published private(set) var nudge: String?
    /// How far the tab's translation has got: pieces sent, pieces back.
    @Published private(set) var progress: [Tab.ID: (sent: Int, done: Int)] = [:]
    /// Said at the top of the page when a translation couldn't happen.
    @Published var trouble: String?

    /// What pages are translated into: the language last picked, or the
    /// Mac's own.
    @Published private(set) var target: String
    var targetName: String { Translator.name(of: target) }
    /// Every language macOS translates (see key(of:)). Until macOS has
    /// said, the ones it translated when this was written.
    @Published private(set) var languages: [String] = Translator.known
    /// For each language a page is in, the ones macOS would have to
    /// download before translating it into them.
    @Published private(set) var downloads: [String: Set<String>] = [:]

    /// The Mac's first language, from System Settings › Language & Region.
    let mac: String

    private let store = Store.settings
    /// Each tab's page, counted: a new one makes an answer about the last stale.
    private var generation: [Tab.ID: Int] = [:]
    /// Each tab's translation, counted: what comes back for one put aside
    /// — into another language, or from one put right — isn't this one's.
    private var rounds: [Tab.ID: Int] = [:]
    /// Tabs whose translation has said it is done, once.
    private var told: Set<Tab.ID> = []
    /// What puts the offer, or the word that a page is translated, away.
    private var hush: DispatchWorkItem?
    private var learned = false

    private var always: Set<String> { Set(store.stringArray(forKey: "translate.always") ?? []) }
    private var never: Set<String> { Set(store.stringArray(forKey: "translate.never") ?? []) }
    private var sites: [String: String] { store.dictionary(forKey: "translate.sites") as? [String: String] ?? [:] }
    /// Sites said always or never in a private tab: for private tabs only,
    /// until Search quits. Written down, the site's name would be a line of
    /// the history a private tab doesn't keep. A site put back to no rule
    /// there is kept as nil, so a rule from an ordinary tab doesn't show
    /// through.
    private var privateSites: [String: TranslateRule?] = [:]
    /// How many times each language was translated from its offer, for the
    /// question whether always.
    private var accepted: [String: Int] { store.dictionary(forKey: "translate.accepted") as? [String: Int] ?? [:] }
    private var nudged: Set<String> { Set(store.stringArray(forKey: "translate.nudged") ?? []) }

    private init() {
        mac = Translator.key(of: Locale.Language(identifier: Locale.preferredLanguages.first ?? "en"))
        target = Store.settings.string(forKey: "translate.target") ?? mac
    }

    /// Whether macOS here translates at all: from 15, on this Mac's own.
    var available: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }

    // MARK: - languages

    /// The languages macOS 15 translates, for as long as it hasn't been
    /// asked — and for a test run, which never asks.
    nonisolated static let known = ["ar", "zh-Hans", "zh-Hant", "nl", "en", "en-GB", "fr", "de", "hi", "id", "it",
                                    "ja", "ko", "pl", "pt", "ru", "es", "th", "tr", "uk", "vi"]

    /// A language as the translator keeps it: its code, with the region
    /// only where it makes a kind of its own (en-GB, where en-US is plain
    /// en), and Chinese by its script — two languages to a translator.
    nonisolated static func key(of language: Locale.Language) -> String {
        guard let code = language.languageCode?.identifier else { return language.minimalIdentifier }
        if code == "zh" { return language.maximalIdentifier.contains("-Hant") ? "zh-Hant" : "zh-Hans" }
        return language.minimalIdentifier
    }

    /// The language alone, without its region or script: what a page
    /// written in it has in common with it.
    nonisolated static func base(_ code: String) -> String {
        code.split(separator: "-").first.map(String.init) ?? code
    }

    nonisolated static func name(of code: String) -> String {
        switch code {
        case "zh-Hans": return "Chinese (Simplified)"
        case "zh-Hant": return "Chinese (Traditional)"
        default: return Locale(identifier: "en_US").localizedString(forIdentifier: code) ?? code
        }
    }

    /// Every language by name, as a menu lists them.
    var named: [String] {
        languages.sorted { Translator.name(of: $0).localizedStandardCompare(Translator.name(of: $1)) == .orderedAscending }
    }

    /// The languages you read: the Mac's, in the order System Settings has
    /// them, and the one pages are translated into. Pages in them are never
    /// offered.
    var readable: [String] {
        var keys: [String] = []
        for identifier in Locale.preferredLanguages {
            let key = Translator.key(of: Locale.Language(identifier: identifier))
            if !keys.contains(key) { keys.append(key) }
        }
        if !keys.contains(target) { keys.append(target) }
        return keys
    }

    func reads(_ code: String) -> Bool {
        readable.contains { Translator.base($0) == Translator.base(code) }
    }

    /// What macOS translates, asked once, the first time a language is to
    /// be picked: asking at launch would cost every launch for a menu most
    /// never open.
    func learn() {
        guard !learned, !Store.testing else { return }
        learned = true
        guard #available(macOS 15, *) else { return }
        Task {
            let found = await Translator.supported()
            if !found.isEmpty { languages = found }
        }
    }

    @available(macOS 15, *)
    nonisolated private static func supported() async -> [String] {
        let all = await LanguageAvailability().supportedLanguages.map(key(of:))
        var keys: [String] = []
        for key in all where !keys.contains(key) {
            // A language macOS has in one kind only goes by its name alone.
            let kinds = all.filter { base($0) == base(key) }
            let kept = Set(kinds).count == 1 && base(key) != "zh" ? base(key) : key
            if !keys.contains(kept) { keys.append(kept) }
        }
        return keys
    }

    /// Which languages a page in this one can't be translated into before
    /// macOS downloads them, for the target menu to say so.
    private func learnDownloads(from source: String) {
        guard downloads[source] == nil else { return }
        if Store.testing {
            downloads[source] = ["ja", "ko"]
            return
        }
        guard #available(macOS 15, *) else { return }
        downloads[source] = []
        let targets = languages
        Task {
            downloads[source] = await Translator.wanting(from: source, to: targets)
        }
    }

    @available(macOS 15, *)
    nonisolated private static func wanting(from source: String, to targets: [String]) async -> Set<String> {
        let availability = LanguageAvailability()
        var found: Set<String> = []
        for target in targets where base(target) != base(source) {
            let status = await availability.status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
            if status == .supported { found.insert(target) }
        }
        return found
    }

    // MARK: - what you said

    /// Whether pages in a language you don't read are offered at all.
    var offers: Bool {
        get { store.object(forKey: "translate.offer") as? Bool ?? true }
        set {
            objectWillChange.send()
            store.set(newValue, forKey: "translate.offer")
            if !newValue { dismiss() }
        }
    }

    /// The language picked to translate into, or nil for the Mac's.
    var chosen: String? { store.string(forKey: "translate.target") }

    /// What pages are translated into from now on. Nothing translated
    /// already changes.
    func setTarget(_ key: String?) {
        let key = key == mac ? nil : key
        store.set(key, forKey: "translate.target")
        target = key ?? mac
    }

    /// The site a page is on, as rules keep it: the host without its www.
    nonisolated static func site(of url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host()?.lowercased(), !host.isEmpty
        else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// What was said for a language. A rule kept for Chinese, before it was
    /// two languages here, still holds for both.
    func rule(language code: String) -> TranslateRule? {
        let names = [code, Translator.base(code)]
        if names.contains(where: always.contains) { return .always }
        if names.contains(where: never.contains) { return .never }
        return nil
    }

    func setRule(_ rule: TranslateRule?, language code: String) {
        objectWillChange.send()
        var always = self.always, never = self.never
        for name in [code, Translator.base(code)] {
            always.remove(name)
            never.remove(name)
        }
        switch rule {
        case .always: always.insert(code)
        case .never: never.insert(code)
        case nil: break
        }
        store.set(always.sorted(), forKey: "translate.always")
        store.set(never.sorted(), forKey: "translate.never")
    }

    func rule(site host: String, shy: Bool) -> TranslateRule? {
        if shy, let kept = privateSites[host] { return kept }
        return sites[host].flatMap(TranslateRule.init(rawValue:))
    }

    func setRule(_ rule: TranslateRule?, site host: String, shy: Bool) {
        objectWillChange.send()
        if shy {
            privateSites[host] = .some(rule)
            return
        }
        var sites = self.sites
        sites[host] = rule?.rawValue
        store.set(sites, forKey: "translate.sites")
    }

    /// Every rule kept, for Settings: languages by name, then sites.
    var rules: [(language: String?, site: String?, rule: TranslateRule)] {
        let languages = (always.map { ($0, TranslateRule.always) } + never.map { ($0, TranslateRule.never) })
            .sorted { Translator.name(of: $0.0) < Translator.name(of: $1.0) }
        let sites = self.sites.compactMap { host, raw in TranslateRule(rawValue: raw).map { (host, $0) } }
            .sorted { $0.0 < $1.0 }
        return languages.map { (language: $0.0, site: nil, rule: $0.1) } + sites.map { (language: nil, site: $0.0, rule: $0.1) }
    }

    /// What a page in this language on this site is owed, from the closest
    /// rule in: never for the site; a language you read; always for the
    /// site; then what you said for its language; then an offer.
    enum Decision { case translate, offer, nothing }

    func decision(for code: String, site: String?, shy: Bool) -> Decision {
        let kept = site.flatMap { rule(site: $0, shy: shy) }
        if kept == .never || reads(code) { return .nothing }
        if kept == .always { return .translate }
        switch rule(language: code) {
        case .never: return .nothing
        case .always: return .translate
        case nil: return offers ? .offer : .nothing
        }
    }

    // MARK: - reading a page

    /// A page just loaded: what it is written in, from its own words, and —
    /// another language than one you read — offered, or translated at once
    /// for a language or a site you said always.
    func read(_ tab: Tab, browser: Browser) {
        // The bench's tabs are read on a test run only: in your browser they
        // are a script's, and nobody is there to be offered anything.
        guard available, !tab.bench || Store.testing, let web = tab.built,
              ["http", "https", "file"].contains(tab.address?.scheme?.lowercased() ?? "")
        else { return }
        // The answer is for this page only: a tab that has gone on to
        // another since keeps what that one will say.
        let page = generation[tab.id, default: 0]
        web.evaluateQuietly(Translator.sample) { [weak self, weak tab, weak browser] value, _ in
            guard let self, let tab, let browser, let found = value as? [String: Any],
                  generation[tab.id, default: 0] == page
            else { return }
            let text = found["text"] as? String ?? ""
            let declared = (found["lang"] as? String ?? "").lowercased()
            guard let code = Translator.language(of: text, declared: declared) else {
                read[tab.id] = nil
                return
            }
            read[tab.id] = PageLanguage(code: code, detected: code)
            consider(tab, browser: browser)
        }
    }

    private func consider(_ tab: Tab, browser: Browser) {
        guard let language = read[tab.id], !translated.contains(tab.id) else { return }
        switch decision(for: language.code, site: Translator.site(of: tab.address), shy: tab.shy) {
        case .translate: translate(tab, browser: browser)
        case .offer where tab.id == browser.activeID: offer(tab)
        default: break
        }
    }

    /// The page's language, from enough of its words to say — a page of
    /// links and buttons says too little to be offered anything.
    nonisolated static func language(of text: String, declared: String) -> String? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 200 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 2).max(by: { $0.value < $1.value }),
              best.value >= 0.6
        else { return nil }
        let code = base(best.key.rawValue)
        // Chinese is two languages to a translator: the script its words
        // are in, or the one the page says.
        if code == "zh" {
            let traditional = best.key == .traditionalChinese || declared.contains("hant")
                || ["zh-tw", "zh-hk", "zh-mo"].contains { declared.hasPrefix($0) }
            return traditional ? "zh-Hant" : "zh-Hans"
        }
        return code
    }

    /// The first two thousand characters of what the page shows, and the
    /// language it says it is in.
    private static let sample = """
    (function () {
      var root = document.body || document.documentElement;
      var text = root ? (root.innerText || '').slice(0, 2000) : '';
      return { text: text, lang: document.documentElement.getAttribute('lang') || '' };
    })()
    """

    // MARK: - at the top of the page

    private func offer(_ tab: Tab) {
        offered = tab.id
        settled = nil
        learn()
        if let code = read[tab.id]?.code { learnDownloads(from: code) }
        hold(false)
    }

    /// The offer goes by itself after a while, and the word that a page is
    /// translated sooner — but not from under the pointer, or while one of
    /// its menus is open.
    func hold(_ holding: Bool) {
        hush?.cancel()
        hush = nil
        guard !holding, offered != nil || settled != nil else { return }
        let shown = (offered, settled)
        let work = DispatchWorkItem { [weak self] in
            guard let self, (offered, settled) == shown else { return }
            offered = nil
            settled = nil
        }
        hush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (offered != nil ? 15 : 4), execute: work)
    }

    /// Not now: the offer, or the word that the page is translated, away.
    func dismiss() {
        hush?.cancel()
        hush = nil
        offered = nil
        settled = nil
    }

    // MARK: - translating

    /// Translate, from the page's offer: counted, for the question whether
    /// always (see nudge).
    func accept(_ tab: Tab, browser: Browser) {
        if let code = read[tab.id]?.code, rule(language: code) == nil {
            var counts = accepted
            counts[code, default: 0] += 1
            store.set(counts, forKey: "translate.accepted")
        }
        translate(tab, browser: browser)
    }

    func translate(_ tab: Tab, browser: Browser) {
        guard available, let web = tab.built else { return }
        if offered == tab.id || settled == tab.id { dismiss() }
        trouble = nil
        let pair = Pair(source: read[tab.id]?.code, target: target)
        translated.insert(tab.id)
        progress[tab.id] = (0, 0)
        rounds[tab.id, default: 0] += 1
        told.remove(tab.id)
        pairs[tab.id] = pair
        open(pair)
        pages[tab.id] = Page(web: web)
        web.evaluateQuietly(TranslateScript.source)
    }

    /// The page as it was, and what arrives from now on left alone.
    func showOriginal(_ tab: Tab) {
        translated.remove(tab.id)
        progress[tab.id] = nil
        pages[tab.id] = nil
        pairs[tab.id] = nil
        told.remove(tab.id)
        if settled == tab.id { dismiss() }
        tab.built?.evaluateQuietly("window.__searchTranslate ? window.__searchTranslate.restore() : false")
    }

    /// The page again, as it is now set: the last translation put back
    /// first, so what goes to macOS is the page's own words.
    private func retranslate(_ tab: Tab, browser: Browser) {
        showOriginal(tab)
        translate(tab, browser: browser)
    }

    /// A new page in the tab, or no page at all any more — the tab closed,
    /// put down or asleep: the translation was the last one's.
    func forget(_ tab: Tab.ID) {
        generation[tab, default: 0] += 1
        translated.remove(tab)
        progress[tab] = nil
        pages[tab] = nil
        pairs[tab] = nil
        read[tab] = nil
        told.remove(tab)
        if offered == tab || settled == tab { dismiss() }
    }

    /// Into another language: this page, and the pages after it, as Chrome
    /// keeps the last one picked.
    func choose(target key: String, for tab: Tab, browser: Browser) {
        let changed = key != target
        setTarget(key)
        if translated.contains(tab.id) {
            if changed { retranslate(tab, browser: browser) }
        } else if read[tab.id].map({ !reads($0.code) }) ?? true {
            translate(tab, browser: browser)
        }
        if changed { browser.announce("Translating into \(Translator.name(of: key)) from now on") }
    }

    /// The page is in another language than its words said: offered or
    /// translated again from that one — or, one you read, left as it is.
    func correct(_ code: String, for tab: Tab, browser: Browser) {
        read[tab.id] = PageLanguage(code: code, detected: read[tab.id]?.detected)
        if reads(code) {
            if translated.contains(tab.id) { showOriginal(tab) }
            if offered == tab.id { dismiss() }
        } else if translated.contains(tab.id) {
            retranslate(tab, browser: browser)
        } else if offered == tab.id {
            learnDownloads(from: code)
        }
    }

    /// Always or never for the page's language, or back to neither if it
    /// was that already.
    func toggle(_ rule: TranslateRule, language code: String, tab: Tab, browser: Browser) {
        let now = self.rule(language: code) == rule ? nil : rule
        setRule(now, language: code)
        if nudge == code { nudge = nil }
        follow(now, tab: tab, browser: browser, said: "\(Translator.name(of: code)) won't be offered again")
    }

    /// Always or never for the page's site.
    func toggle(_ rule: TranslateRule, site host: String, tab: Tab, browser: Browser) {
        let now = self.rule(site: host, shy: tab.shy) == rule ? nil : rule
        setRule(now, site: host, shy: tab.shy)
        follow(now, tab: tab, browser: browser, said: "\(host) won't be translated")
    }

    /// A rule said on this page is for this page too: always translates it,
    /// never puts it back as it was.
    private func follow(_ rule: TranslateRule?, tab: Tab, browser: Browser, said: String) {
        switch rule {
        case .always:
            if !translated.contains(tab.id), let code = read[tab.id]?.code,
               decision(for: code, site: Translator.site(of: tab.address), shy: tab.shy) == .translate {
                translate(tab, browser: browser)
            }
        case .never:
            if translated.contains(tab.id) { showOriginal(tab) }
            dismiss()
            browser.announce(said)
        case nil:
            break
        }
    }

    // MARK: - the pieces, to macOS and back

    /// A piece of a page, by the page's own number for it.
    struct Piece: Sendable {
        let id: Int
        let text: String
    }
    struct Batch {
        let tab: Tab.ID
        let round: Int
        let pieces: [Piece]
    }
    /// From what, into what. No source is macOS's to tell.
    struct Pair: Equatable {
        let source: String?
        let target: String
    }

    /// The pages being translated, by tab, to be handed their pieces back.
    /// Never what keeps one: held here outright, a translated page outlived
    /// its tab — closed or put to sleep, it went on running where nobody
    /// could see it, its timers, its requests and its sound with it.
    private var pages: [Tab.ID: Page] = [:]
    private struct Page { weak var web: WKWebView? }
    /// The translation macOS is doing: from what, into what.
    @Published private(set) var configuration: AnyObject?
    private var pair: Pair?
    private var batches: AsyncStream<Batch>.Continuation?
    private var stream: AsyncStream<Batch>?
    /// Which session is the open one: a session put aside for another
    /// language is cancelled, and what it throws then is no failure of the
    /// one that replaced it.
    private var opened = 0
    /// What each translated tab is translated from and into. One session is
    /// open at a time, so a tab whose pair isn't the open one's keeps what
    /// was translated, and what its page adds afterwards stays as it is
    /// rather than going through a session for other languages.
    private var pairs: [Tab.ID: Pair] = [:]

    /// A session for these languages, or the one already open for them:
    /// the same on another tab joins the translation already going.
    private func open(_ wanted: Pair) {
        if pair == wanted, batches != nil { return }
        batches?.finish()
        opened += 1
        // Pieces still out with the session being put aside never come
        // back: those tabs aren't left saying they are translating.
        for (tab, other) in pairs where other != wanted {
            if let now = progress[tab] { progress[tab] = (now.done, now.done) }
        }
        let (stream, continuation) = AsyncStream.makeStream(of: Batch.self)
        self.stream = stream
        batches = continuation
        pair = wanted
        if Store.testing {
            Task { await self.pretend(stream, into: wanted.target) }
        } else if #available(macOS 15, *) {
            configuration = TranslationBox(TranslationSession.Configuration(
                source: wanted.source.map { Locale.Language(identifier: $0) },
                target: Locale.Language(identifier: wanted.target)))
        }
    }

    /// Pieces from a page (see TranslateRelay).
    func received(_ body: [String: Any], from tab: Tab) {
        guard translated.contains(tab.id), let wanted = pairs[tab.id], wanted == pair else { return }
        if let raw = body["batch"] as? [[Any]] {
            let pieces = raw.compactMap { pair -> Piece? in
                guard pair.count == 2, let id = pair[0] as? Int, let text = pair[1] as? String else { return nil }
                return Piece(id: id, text: text)
            }
            guard !pieces.isEmpty else { return }
            let now = progress[tab.id] ?? (0, 0)
            progress[tab.id] = (now.sent + pieces.count, now.done)
            batches?.yield(Batch(tab: tab.id, round: rounds[tab.id, default: 0], pieces: pieces))
        }
    }

    /// Translations, back into their page.
    private func deliver(_ results: [(Int, String)], to batch: Batch) {
        let tab = batch.tab
        guard translated.contains(tab), rounds[tab] == batch.round, let web = pages[tab]?.web,
              let data = try? JSONSerialization.data(withJSONObject: results.map { [$0.0, $0.1] }),
              let json = String(data: data, encoding: .utf8)
        else { return }
        web.evaluateQuietly("window.__searchTranslate && window.__searchTranslate.apply(\(json))")
        let now = progress[tab] ?? (0, 0)
        progress[tab] = (now.sent, now.done + results.count)
        if now.done + results.count >= now.sent, !told.contains(tab) {
            told.insert(tab)
            settle(tab)
        }
    }

    /// The first time a translation is all back: said, for a moment, with
    /// the way back — and, for a language translated by hand a third time,
    /// asked once whether always.
    private func settle(_ tab: Tab.ID) {
        // Translated once, the languages are on this Mac.
        if let pair = pairs[tab], let source = pair.source { downloads[source]?.remove(pair.target) }
        nudge = nil
        if let code = read[tab]?.code, rule(language: code) == nil, accepted[code, default: 0] >= 3, !nudged.contains(code) {
            nudge = code
            store.set(nudged.union([code]).sorted(), forKey: "translate.nudged")
        }
        if offered == tab { offered = nil }
        settled = tab
        hold(false)
    }

    /// macOS's session, for as long as it is open: every batch through it
    /// as it comes. The first time a language is wanted, macOS asks to
    /// download it (prepareTranslation) before anything is translated.
    @available(macOS 15, *)
    func run(_ session: TranslationSession) async {
        guard let stream else { return }
        let turn = opened
        do {
            try await session.prepareTranslation()
        } catch {
            if turn == opened, !Task.isCancelled { fail(error) }
            return
        }
        for await batch in stream {
            let requests = batch.pieces.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id)) }
            do {
                let responses = try await session.translations(from: requests)
                deliver(responses.compactMap { response in
                    response.clientIdentifier.flatMap(Int.init).map { ($0, response.targetText) }
                }, to: batch)
            } catch {
                if turn == opened, !Task.isCancelled { fail(error) }
                return
            }
        }
    }

    /// A test run's translation: each piece marked with the language it
    /// would be in, for the bench to find.
    private func pretend(_ stream: AsyncStream<Batch>, into target: String) async {
        for await batch in stream {
            deliver(batch.pieces.map { ($0.id, "[\(target)] \($0.text)") }, to: batch)
        }
    }

    private func fail(_ error: Error) {
        let failed = pair
        batches?.finish()
        batches = nil
        pair = nil
        configuration = nil
        for tab in translated { progress[tab] = nil }
        translated = []
        pages = [:]
        pairs = [:]
        told = []
        dismiss()
        trouble = failed.map { failed in
            failed.source.map { "Couldn't translate \(Translator.name(of: $0)) into \(Translator.name(of: failed.target))" }
                ?? "Couldn't translate this page into \(Translator.name(of: failed.target))"
        } ?? "Couldn't translate this page"
        let said = trouble
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.trouble == said { self?.trouble = nil }
        }
    }
}

// MARK: - the menus

extension Translator {
    /// Into what: the languages you read first, as System Settings has
    /// them, then every other macOS translates — those it would download
    /// first said so. The page's own language isn't one.
    func targetMenu(for tab: Tab, browser: Browser) -> [TranslateEntry] {
        learn()
        let source = read[tab.id]?.code
        let usable = named.filter { key in source.map { Translator.base($0) != Translator.base(key) } ?? true }
        let first = readable.filter(usable.contains)
        let rest = usable.filter { !first.contains($0) }
        let fetching = source.flatMap { downloads[$0] } ?? []
        let line = { (key: String) -> TranslateEntry in
            .item(Translator.name(of: key), on: key == self.target, badge: fetching.contains(key) ? "Download" : nil) { [weak self, weak tab] in
                guard let self, let tab else { return }
                choose(target: key, for: tab, browser: browser)
            }
        }
        return [.heading("Translate to")] + first.map(line) + (first.isEmpty || rest.isEmpty ? [] : [.separator]) + rest.map(line)
    }

    /// What the page is in, for when its words were read wrong: what they
    /// said marked, what you said ticked.
    func sourceMenu(for tab: Tab, browser: Browser) -> [TranslateEntry] {
        learn()
        let now = read[tab.id]
        var keys = named
        // A language macOS doesn't translate is still what the page is in.
        if let detected = now?.detected, Translator.closest(detected, in: keys) == nil { keys.insert(detected, at: 0) }
        let ticked = now.flatMap { Translator.closest($0.code, in: keys) }
        let marked = now?.detected.flatMap { Translator.closest($0, in: keys) }
        return [.heading("The page is in")] + keys.map { key in
            .item(Translator.name(of: key), on: key == ticked, badge: key == marked ? "Detected" : nil) { [weak self, weak tab] in
                guard let self, let tab else { return }
                correct(key, for: tab, browser: browser)
            }
        }
    }

    /// The language's own line in a list: itself, or the plain kind of it
    /// (en for a page read as en, not en-GB).
    nonisolated static func closest(_ code: String, in keys: [String]) -> String? {
        if keys.contains(code) { return code }
        return keys.first { $0 == base(code) } ?? keys.first { base($0) == base(code) }
    }

    /// Always and never, for the page's language and its site, each ticked
    /// when it is what you said — and again, to say neither.
    func ruleEntries(for tab: Tab, browser: Browser) -> [TranslateEntry] {
        var entries: [TranslateEntry] = []
        if let code = read[tab.id]?.code, !reads(code) {
            let name = Translator.name(of: code)
            let kept = rule(language: code)
            entries += [
                .item("Always Translate \(name)", on: kept == .always) { [weak self, weak tab] in
                    guard let self, let tab else { return }
                    toggle(.always, language: code, tab: tab, browser: browser)
                },
                .item("Never Translate \(name)", on: kept == .never) { [weak self, weak tab] in
                    guard let self, let tab else { return }
                    toggle(.never, language: code, tab: tab, browser: browser)
                },
            ]
        }
        if let host = Translator.site(of: tab.address) {
            if !entries.isEmpty { entries.append(.separator) }
            let kept = rule(site: host, shy: tab.shy)
            entries += [
                .item("Always Translate \(host)", on: kept == .always) { [weak self, weak tab] in
                    guard let self, let tab else { return }
                    toggle(.always, site: host, tab: tab, browser: browser)
                },
                .item("Never Translate \(host)", on: kept == .never) { [weak self, weak tab] in
                    guard let self, let tab else { return }
                    toggle(.never, site: host, tab: tab, browser: browser)
                },
            ]
        }
        return entries
    }

    func rulesMenu(for tab: Tab, browser: Browser) -> [TranslateEntry] {
        let entries = ruleEntries(for: tab, browser: browser)
        return entries + (entries.isEmpty ? [] : [.separator]) + [.item("Translation Settings…") { browser.openTranslationSettings() }]
    }

    /// Whether the site's card has anything to say about translating this
    /// page beyond doing it: a language you don't read, a translation, or a
    /// rule for the site.
    func concerns(_ tab: Tab) -> Bool {
        if translated.contains(tab.id) { return true }
        if let code = read[tab.id]?.code, !reads(code) { return true }
        return Translator.site(of: tab.address).flatMap { rule(site: $0, shy: tab.shy) } != nil
    }
}

/// One of the translator's menus, at the pointer, as the site card's
/// answers to a permission are.
@MainActor
final class TranslateMenu: NSObject {
    private var acts: [() -> Void] = []

    static func show(_ entries: [TranslateEntry]) {
        let target = TranslateMenu()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .heading(let title):
                menu.addItem(.sectionHeader(title: title))
            case .separator:
                menu.addItem(.separator())
            case .item(let title, let on, let badge, let act):
                let item = NSMenuItem(title: title, action: #selector(chosen(_:)), keyEquivalent: "")
                item.target = target
                item.tag = target.acts.count
                item.state = on ? .on : .off
                if let badge { item.badge = NSMenuItemBadge(string: badge) }
                target.acts.append(act)
                menu.addItem(item)
            }
        }
        // Tracked here and now; the target lives for as long as the menu is up.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(target) {}
    }

    @objc private func chosen(_ item: NSMenuItem) {
        guard acts.indices.contains(item.tag) else { return }
        acts[item.tag]()
    }

    /// A menu as words, for the bench.
    static func describe(_ entries: [TranslateEntry]) -> [[String: Any]] {
        entries.map { entry in
            switch entry {
            case .heading(let title): return ["heading": title]
            case .separator: return ["separator": true]
            case .item(let title, let on, let badge, _): return ["title": title, "on": on, "badge": badge ?? ""]
            }
        }
    }

    /// A menu's line, picked by its title, for the bench.
    static func pick(_ title: String, in entries: [TranslateEntry]) -> Bool {
        for case .item(let name, _, _, let act) in entries where name == title {
            act()
            return true
        }
        return false
    }
}

/// TranslationSession.Configuration, held where the rest of the app needn't
/// know it exists: it is only there from macOS 15.
private final class TranslationBox: Equatable {
    let value: Any
    init(_ value: Any) { self.value = value }
    static func == (a: TranslationBox, b: TranslationBox) -> Bool { a === b }
}

/// Where macOS's translation runs: a view of no size in the window, since a
/// session is only lent to a view, for as long as the view has asked.
@available(macOS 15, *)
struct TranslationRunner: View {
    @ObservedObject var translator = Translator.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask((translator.configuration as? TranslationBox)?.value as? TranslationSession.Configuration) { session in
                await translator.run(session)
            }
    }
}

/// Pieces of a page, from the page (see TranslateScript). A content
/// controller holds its handlers strongly, so this stands between the page
/// and the tab.
final class TranslateRelay: NSObject, WKScriptMessageHandler {
    static let name = "searchTranslate"

    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated {
            guard let tab else { return }
            Translator.shared.received(body, from: tab)
        }
    }
}

/// The page's side, in Search's own world: every piece of text worth it —
/// not code, not a field being typed in, not what a page marks
/// translate="no" — and the words in placeholders, titles, alt texts and
/// labels, numbered and sent in batches from the top of the page down. Each
/// comes back into its place with its own spaces kept around it; what the
/// page adds or changes later is sent as it happens; restore() puts every
/// original back.
enum TranslateScript {
    static let source = """
    (function () {
      if (window.__searchTranslate) return window.__searchTranslate.start();
      var post = function (m) { try { window.webkit.messageHandlers.\(TranslateRelay.name).postMessage(m); } catch (e) {} };
      var SKIP = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|CODE|PRE|KBD|SAMP|VAR|TEXTAREA|INPUT|SELECT|OPTION|SVG|MATH|CANVAS|IFRAME|OBJECT)$/;
      var NAMES = ['placeholder', 'title', 'alt', 'aria-label'];
      var LETTER = /[A-Za-zÀ-ɏͰ-ϿЀ-ӿ֐-׿؀-ۿऀ-ॿ぀-ヿ一-鿿가-힯]/;
      // Each piece by number: a text node, or an element and one of its names.
      var targets = [], textIds = new Map(), nameIds = new Map();
      var sent = [], mine = [], original = [], on = false, observer = null, timer = 0;
      function skipped(el) {
        for (var e = el; e && e.nodeType === 1; e = e.parentElement) {
          if (SKIP.test(e.tagName) || e.isContentEditable) return true;
          var t = e.getAttribute('translate');
          if (t === 'no') return true;
          if (t === 'yes') return false;
          if (e.classList && e.classList.contains('notranslate')) return true;
        }
        return false;
      }
      function now(target) { return target.nodeType === 3 ? target.data : (target[0].getAttribute(target[1]) || ''); }
      function number(target, map, key) {
        var id = map.get(key);
        if (id === undefined) { id = targets.length; targets.push(target); map.set(key, id); }
        return id;
      }
      function gather(root) {
        var found = [];
        function take(id, text) {
          if (!text || !text.trim() || !LETTER.test(text)) return;
          // Waiting for its translation, or showing it: nothing to do.
          if (sent[id] === text || mine[id] === text) return;
          // Changed by the page since: what it says now is what it was.
          if (mine[id] !== undefined) { original[id] = undefined; mine[id] = undefined; }
          sent[id] = text;
          found.push([id, text.trim()]);
        }
        var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        for (var node = walker.nextNode(); node; node = walker.nextNode()) {
          if (skipped(node.parentElement)) continue;
          take(number(node, textIds, node), node.data);
        }
        var named = root.querySelectorAll ? root.querySelectorAll('[placeholder],[title],[alt],[aria-label]') : [];
        for (var i = 0; i < named.length; i++) {
          var el = named[i];
          // A field's hint is the page's words, what is typed in it isn't:
          // the element's own tag doesn't keep its names out, only a
          // translate="no" on it or around it.
          if (el.getAttribute('translate') === 'no' || (el.classList && el.classList.contains('notranslate')) || skipped(el.parentElement)) continue;
          var ids = nameIds.get(el);
          if (!ids) { ids = {}; nameIds.set(el, ids); }
          for (var j = 0; j < NAMES.length; j++) {
            var value = el.getAttribute(NAMES[j]);
            if (!value) continue;
            if (ids[NAMES[j]] === undefined) { ids[NAMES[j]] = targets.length; targets.push([el, NAMES[j]]); }
            take(ids[NAMES[j]], value);
          }
        }
        return found;
      }
      function send(found) {
        for (var i = 0; i < found.length; ) {
          var batch = [], chars = 0;
          while (i < found.length && batch.length < 40 && chars < 3000) { batch.push(found[i]); chars += found[i][1].length; i++; }
          post({ batch: batch });
        }
      }
      function apply(results) {
        if (!on) return;
        for (var i = 0; i < results.length; i++) {
          var id = results[i][0], text = results[i][1], target = targets[id];
          // Gone, or changed since it was sent: its answer is for nothing.
          if (!target || now(target) !== sent[id]) continue;
          var before = sent[id];
          if (original[id] === undefined) original[id] = before;
          var next = target.nodeType === 3 ? before.match(/^\\s*/)[0] + text + before.match(/\\s*$/)[0] : text;
          mine[id] = next;
          sent[id] = undefined;
          if (target.nodeType === 3) target.data = next; else target[0].setAttribute(target[1], next);
        }
      }
      function watch() {
        observer = new MutationObserver(function () {
          if (!on) return;
          clearTimeout(timer);
          timer = setTimeout(function () { send(gather(document.body || document.documentElement)); }, 350);
        });
        observer.observe(document.body || document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: NAMES });
      }
      function start() {
        on = true;
        var found = gather(document.body || document.documentElement);
        send(found);
        if (!observer) watch();
        return found.length;
      }
      function restore() {
        on = false;
        clearTimeout(timer);
        if (observer) { observer.disconnect(); observer = null; }
        for (var id = 0; id < targets.length; id++) {
          var target = targets[id];
          if (original[id] === undefined || now(target) !== mine[id]) continue;
          if (target.nodeType === 3) target.data = original[id]; else target[0].setAttribute(target[1], original[id]);
        }
        targets = []; textIds = new Map(); nameIds = new Map(); sent = []; mine = []; original = [];
        return true;
      }
      window.__searchTranslate = { start: start, apply: apply, restore: restore };
      return start();
    })()
    """
}

// MARK: - at the top of the page

/// The offer, the translation under way, the word that it is done, and
/// anything that went wrong — at the top of the page, where the site's
/// questions are too.
struct TranslateNotice: View {
    @ObservedObject var translator = Translator.shared
    @ObservedObject var tab: Tab
    let browser: Browser

    init(tab: Tab, browser: Browser) {
        self.tab = tab
        self.browser = browser
    }

    var body: some View {
        Group {
            if let trouble = translator.trouble {
                pill {
                    mark
                    Text(trouble).foregroundStyle(Palette.ink)
                }
            } else if translator.translated.contains(tab.id), let progress = translator.progress[tab.id], progress.done < progress.sent {
                pill {
                    Ring(size: 10)
                    HStack(spacing: 2) {
                        if let language = translator.read[tab.id] {
                            Text(language.name).foregroundStyle(Palette.ink)
                                .padding(.trailing, 5)
                            arrow
                        } else {
                            Text("Translating to").foregroundStyle(Palette.ink)
                        }
                        targetChoice
                    }
                    Text("\(progress.sent == 0 ? 0 : min(99, progress.done * 100 / progress.sent))%")
                        .monospacedDigit()
                        .foregroundStyle(Palette.muted)
                    button("Show Original", strong: false) { translator.showOriginal(tab) }
                }
            } else if translator.settled == tab.id, translator.translated.contains(tab.id) {
                pill {
                    mark
                    if let code = translator.nudge, translator.read[tab.id]?.code == code {
                        Text("Always translate \(Translator.name(of: code))?").foregroundStyle(Palette.ink)
                        button("Always", strong: true) {
                            translator.toggle(.always, language: code, tab: tab, browser: browser)
                            translator.dismiss()
                        }
                    } else {
                        Text(translator.read[tab.id].map { "Translated from \($0.name)" } ?? "Translated to \(translator.targetName)")
                            .foregroundStyle(Palette.ink)
                        button("Show Original", strong: false) { translator.showOriginal(tab) }
                        more
                    }
                    close
                }
            } else if translator.offered == tab.id, let language = translator.read[tab.id] {
                pill {
                    mark
                    // The two languages as one phrase, Russian → Turkish.
                    HStack(spacing: 2) {
                        Choice(title: language.name, help: "Read from the page's words. Pick another if it's wrong") {
                            menu(translator.sourceMenu(for: tab, browser: browser))
                        }
                        arrow
                        targetChoice
                    }
                    button("Translate", strong: true) { translator.accept(tab, browser: browser) }
                    more
                    close
                }
            }
        }
        .animation(Motion.settle, value: translator.offered)
        .animation(Motion.settle, value: translator.settled)
        .animation(Motion.settle, value: translator.translated)
    }

    private var mark: some View {
        Image(systemName: "character.bubble")
            .foregroundStyle(Palette.muted)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Palette.muted)
    }

    private var targetChoice: some View {
        Choice(title: translator.targetName, help: "The language to translate into, for this page and the next") {
            menu(translator.targetMenu(for: tab, browser: browser))
        }
    }

    /// Always and never, for the language and the site.
    private var more: some View {
        Button { menu(translator.rulesMenu(for: tab, browser: browser)) } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Always or never, for this language or this site")
    }

    private var close: some View {
        Button { translator.dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Not now")
    }

    /// A menu from the bar, which stays for as long as the menu is open.
    private func menu(_ entries: [TranslateEntry]) {
        translator.hold(true)
        TranslateMenu.show(entries)
        translator.hold(false)
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .font(.system(size: 12.5))
            .lineLimit(1)
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(Palette.ground, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 16, y: 5)
            .onHover { translator.hold($0) }
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func button(_ title: String, strong: Bool, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(title)
                .font(.system(size: 12, weight: strong ? .medium : .regular))
                .foregroundStyle(strong ? Palette.ground : Palette.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(strong ? Palette.ink : Palette.wash, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// A language in the bar, which opens the menu to pick another: only a
    /// chevron until the pointer is on it, so it reads as a word.
    private struct Choice: View {
        let title: String
        let help: String
        let act: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(hovering ? Palette.wash : .clear, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .help(help)
        }
    }
}

// MARK: - Settings › Translation

/// What pages are translated into, whether they are offered, and every
/// always and never said from a page's bar, to take back.
struct TranslationSettings: View {
    @ObservedObject private var translator = Translator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                if translator.available {
                    Line("Offer to translate pages", "A page in a language you don't read asks at its top. Off, View › Translate still translates, and what you said always still is") {
                        Switch(on: Binding(get: { translator.offers }, set: { translator.offers = $0 }))
                    }
                    Rule()
                    Line("Translate into", translator.chosen == nil
                         ? "\(Translator.name(of: translator.mac)), the Mac's own. A page's bar can pick another"
                         : "Picked here or from a page's bar. Pages translated already stay as they are") {
                        Picker("", selection: Binding(
                            get: { translator.chosen ?? "" },
                            set: { translator.setTarget($0.isEmpty ? nil : $0) }
                        )) {
                            Text("Mac's language").tag("")
                            Divider()
                            ForEach(choices, id: \.self) { key in
                                Text(Translator.name(of: key)).tag(key)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    Rule()
                    Line("Languages you read", "\(translator.readable.map(Translator.name(of:)).joined(separator: ", ")): the Mac's languages, from System Settings › Language & Region, and what pages are translated into. Pages in them are never offered") {
                        Pill("Change") { Translator.openLanguageSettings() }
                    }
                } else {
                    Line("Translating pages needs macOS 15", "Pages are translated on this Mac by macOS's own translation, there from macOS Sequoia on") {
                        EmptyView()
                    }
                }
            }
            if translator.available, !translator.rules.isEmpty {
                Caption("Said from a page's bar")
                Card {
                    ForEach(Array(translator.rules.enumerated()), id: \.offset) { index, kept in
                        if index > 0 { Rule() }
                        if let code = kept.language {
                            Line(Translator.name(of: code), kept.rule == .always ? "Always translated" : "Never offered") {
                                Pill("Forget") { translator.setRule(nil, language: code) }
                            }
                        } else if let host = kept.site {
                            Line(host, kept.rule == .always ? "Always translated" : "Never translated") {
                                Pill("Forget") { translator.setRule(nil, site: host, shy: false) }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { translator.learn() }
    }

    /// Every language macOS translates, and one picked before that it no
    /// longer lists.
    private var choices: [String] {
        let named = translator.named
        guard let chosen = translator.chosen, !named.contains(chosen) else { return named }
        return [chosen] + named
    }
}

// MARK: - the browser's side

extension Translator {
    /// System Settings › General › Language & Region, where the Mac's
    /// languages are.
    static func openLanguageSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

extension Browser {
    /// View › Translate, or the site's card: the page on screen in the
    /// language pages are translated into, or back as it was.
    func toggleTranslation() {
        guard let tab = active, !tab.isBlank else { return }
        if Translator.shared.translated.contains(tab.id) {
            Translator.shared.showOriginal(tab)
        } else {
            Translator.shared.translate(tab, browser: self)
        }
    }

    /// Settings, open at Translation.
    func openTranslationSettings() {
        Store.settings.set(SettingsPanel.Page.translation.rawValue, forKey: "settings.page")
        tuning = true
    }
}
