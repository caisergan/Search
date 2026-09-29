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
// When a page has loaded, its language is read from its own words. One in
// another language than the Mac's is offered at the top of the page —
// Translate, Always for that language, Never for it — and View › Translate,
// or the site's card, does it any time. The page is translated from the top
// down, in batches, as the text is; what it adds afterwards — a feed going
// on, a reply opening — is translated as it arrives. Show Original puts back
// every word as it was.
//
// A test run translates nothing for real: it marks each piece instead, so the
// page's side can be checked without asking macOS for anything.

/// What a page was read to be written in.
struct PageLanguage: Equatable {
    let code: String
    var name: String { Translator.name(of: code) }
}

@MainActor
final class Translator: ObservableObject {
    static let shared = Translator()

    /// What each tab's page is in, as far as its words say.
    @Published private(set) var read: [Tab.ID: PageLanguage] = [:]
    /// Tabs whose page is translated, or being.
    @Published private(set) var translated: Set<Tab.ID> = []
    /// The page on screen offered a translation.
    @Published var offered: Tab.ID?
    /// How far the tab's translation has got: pieces sent, pieces back.
    @Published private(set) var progress: [Tab.ID: (sent: Int, done: Int)] = [:]
    /// Said at the top of the page when a translation couldn't happen.
    @Published var trouble: String?

    /// The Mac's own language: what pages are translated into.
    let target: Locale.Language
    var targetName: String { Translator.name(of: target.languageCode?.identifier ?? "") }

    private let store = Store.settings
    /// Each tab's page, counted: a new one makes an answer about the last stale.
    private var generation: [Tab.ID: Int] = [:]
    private var always: Set<String> { Set(store.stringArray(forKey: "translate.always") ?? []) }
    private var never: Set<String> { Set(store.stringArray(forKey: "translate.never") ?? []) }

    private init() {
        target = Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    }

    /// Whether macOS here translates at all: from 15, on this Mac's own.
    var available: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }

    nonisolated static func name(of code: String) -> String {
        Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
    }

    // MARK: - reading a page

    /// A page just loaded: what it is written in, from its own words, and —
    /// another language than the Mac's — offered, or translated at once for
    /// a language you said always.
    func read(_ tab: Tab, browser: Browser) {
        guard available, !tab.bench, let web = tab.built,
              ["http", "https", "file"].contains(tab.address?.scheme?.lowercased() ?? "")
        else { return }
        // The answer is for this page only: a tab that has gone on to
        // another since keeps what that one will say.
        let page = generation[tab.id, default: 0]
        web.evaluateInSearch(Translator.sample) { [weak self, weak tab, weak browser] value in
            guard let self, let tab, let browser, let found = value as? [String: Any],
                  generation[tab.id, default: 0] == page
            else { return }
            let text = found["text"] as? String ?? ""
            let declared = (found["lang"] as? String ?? "").split(separator: "-").first.map(String.init)?.lowercased() ?? ""
            guard let code = Translator.language(of: text, declared: declared) else {
                read[tab.id] = nil
                return
            }
            read[tab.id] = PageLanguage(code: code)
            guard code != target.languageCode?.identifier, !translated.contains(tab.id) else { return }
            if always.contains(code) {
                translate(tab, browser: browser)
            } else if !never.contains(code), tab.id == browser.activeID {
                offered = tab.id
                let shown = tab.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                    if self?.offered == shown { self?.offered = nil }
                }
            }
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
        let code = best.key.rawValue.split(separator: "-").first.map(String.init) ?? best.key.rawValue
        // Chinese is two languages to a translator, which the page names.
        if code == "zh", declared.hasPrefix("zh") { return "zh" }
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

    // MARK: - translating

    func translate(_ tab: Tab, browser: Browser) {
        guard available, let web = tab.built else { return }
        offered = nil
        trouble = nil
        let source = read[tab.id].map { Locale.Language(identifier: $0.code) }
        translated.insert(tab.id)
        progress[tab.id] = (0, 0)
        open(from: source)
        pages[tab.id] = web
        web.evaluateInSearch(TranslateScript.source)
    }

    /// The page as it was, and what arrives from now on left alone.
    func showOriginal(_ tab: Tab) {
        translated.remove(tab.id)
        progress[tab.id] = nil
        pages[tab.id] = nil
        tab.built?.evaluateInSearch("window.__searchTranslate ? window.__searchTranslate.restore() : false")
    }

    /// A new page in the tab: the translation was the last one's.
    func forget(_ tab: Tab.ID) {
        generation[tab, default: 0] += 1
        translated.remove(tab)
        progress[tab] = nil
        pages[tab] = nil
        read[tab] = nil
        if offered == tab { offered = nil }
    }

    /// Offered, and said no to for good: that language isn't offered again.
    func never(_ code: String) {
        store.set(Array(never.union([code])).sorted(), forKey: "translate.never")
        offered = nil
    }

    /// Always, for that language: its pages translated as they load.
    func always(_ code: String, tab: Tab, browser: Browser) {
        store.set(Array(always.union([code])).sorted(), forKey: "translate.always")
        translate(tab, browser: browser)
    }

    // MARK: - the pieces, to macOS and back

    /// A piece of a page, by the page's own number for it.
    struct Piece: Sendable {
        let id: Int
        let text: String
    }
    struct Batch {
        let tab: Tab.ID
        let pieces: [Piece]
    }

    /// The pages being translated, by tab, to be handed their pieces back.
    private var pages: [Tab.ID: WKWebView] = [:]
    /// The translation macOS is doing: from what, into the Mac's language.
    @Published private(set) var configuration: AnyObject?
    private var source: Locale.Language??
    private var batches: AsyncStream<Batch>.Continuation?
    private var stream: AsyncStream<Batch>?

    /// A session for this language, or the one already open for it: the
    /// same language on another tab joins the translation already going.
    private func open(from language: Locale.Language?) {
        if let source, source == language, batches != nil { return }
        batches?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: Batch.self)
        self.stream = stream
        batches = continuation
        source = .some(language)
        if Store.testing {
            Task { await self.pretend(stream) }
        } else if #available(macOS 15, *) {
            configuration = TranslationBox(TranslationSession.Configuration(source: language, target: target))
        }
    }

    /// Pieces from a page (see TranslateRelay).
    func received(_ body: [String: Any], from tab: Tab) {
        guard translated.contains(tab.id) else { return }
        if let raw = body["batch"] as? [[Any]] {
            let pieces = raw.compactMap { pair -> Piece? in
                guard pair.count == 2, let id = pair[0] as? Int, let text = pair[1] as? String else { return nil }
                return Piece(id: id, text: text)
            }
            guard !pieces.isEmpty else { return }
            let now = progress[tab.id] ?? (0, 0)
            progress[tab.id] = (now.sent + pieces.count, now.done)
            batches?.yield(Batch(tab: tab.id, pieces: pieces))
        }
    }

    /// Translations, back into their page.
    private func deliver(_ results: [(Int, String)], to tab: Tab.ID) {
        guard translated.contains(tab), let web = pages[tab],
              let data = try? JSONSerialization.data(withJSONObject: results.map { [$0.0, $0.1] }),
              let json = String(data: data, encoding: .utf8)
        else { return }
        web.evaluateInSearch("window.__searchTranslate && window.__searchTranslate.apply(\(json))")
        let now = progress[tab] ?? (0, 0)
        progress[tab] = (now.sent, now.done + results.count)
    }

    /// macOS's session, for as long as it is open: every batch through it
    /// as it comes. The first time a language is wanted, macOS asks to
    /// download it (prepareTranslation) before anything is translated.
    @available(macOS 15, *)
    func run(_ session: TranslationSession) async {
        guard let stream else { return }
        do {
            try await session.prepareTranslation()
        } catch {
            fail(error)
            return
        }
        for await batch in stream {
            let requests = batch.pieces.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id)) }
            do {
                let responses = try await session.translations(from: requests)
                deliver(responses.compactMap { response in
                    response.clientIdentifier.flatMap(Int.init).map { ($0, response.targetText) }
                }, to: batch.tab)
            } catch {
                fail(error)
                return
            }
        }
    }

    /// A test run's translation: each piece marked, for the bench to find.
    private func pretend(_ stream: AsyncStream<Batch>) async {
        for await batch in stream {
            deliver(batch.pieces.map { ($0.id, "[\(target.languageCode?.identifier ?? "?")] \($0.text)") }, to: batch.tab)
        }
    }

    private func fail(_ error: Error) {
        batches?.finish()
        batches = nil
        source = nil
        configuration = nil
        let pages = translated
        for tab in pages { progress[tab] = nil }
        translated = []
        trouble = "Couldn't translate this page"
        let said = trouble
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.trouble == said { self?.trouble = nil }
        }
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

/// The offer, the translation under way, and anything that went wrong — at
/// the top of the page, where the site's questions are too.
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
                    Image(systemName: "character.bubble")
                        .foregroundStyle(Palette.muted)
                    Text(trouble).foregroundStyle(Palette.ink)
                }
            } else if translator.translated.contains(tab.id), let progress = translator.progress[tab.id], progress.done < progress.sent {
                pill {
                    Ring(size: 10)
                    Text("Translating to \(translator.targetName)…").foregroundStyle(Palette.ink)
                    Text("\(progress.sent == 0 ? 0 : min(99, progress.done * 100 / progress.sent))%")
                        .monospacedDigit()
                        .foregroundStyle(Palette.muted)
                    button("Show Original", strong: false) { translator.showOriginal(tab) }
                }
            } else if translator.offered == tab.id, let language = translator.read[tab.id] {
                pill {
                    Image(systemName: "character.bubble")
                        .foregroundStyle(Palette.muted)
                    Text("This page is in \(language.name)").foregroundStyle(Palette.ink)
                    button("Translate to \(translator.targetName)", strong: true) { translator.translate(tab, browser: browser) }
                    button("Always", strong: false) { translator.always(language.code, tab: tab, browser: browser) }
                        .help("Translate every page in \(language.name)")
                    button("Never", strong: false) { translator.never(language.code) }
                        .help("Don't offer to translate \(language.name)")
                    Button { translator.offered = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .animation(Motion.settle, value: translator.offered)
        .animation(Motion.settle, value: translator.translated)
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
}

// MARK: - the browser's side

extension Browser {
    /// View › Translate, or the site's card: the page on screen in the Mac's
    /// language, or back as it was.
    func toggleTranslation() {
        guard let tab = active, !tab.isBlank else { return }
        if Translator.shared.translated.contains(tab.id) {
            Translator.shared.showOriginal(tab)
        } else {
            Translator.shared.translate(tab, browser: self)
        }
    }
}
