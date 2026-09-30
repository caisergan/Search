import SwiftUI
import WebKit

/// Looking for a word on the page. A pill in the top corner, the same white and
/// hairline as everything else that floats, and gone the moment it isn't wanted.
struct FindBar: View {
    @ObservedObject var browser: Browser

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                if browser.needle.isEmpty {
                    Text("Find on page")
                        .foregroundStyle(Palette.ink.opacity(0.3))
                }
                TextField("", text: $browser.needle)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .focused($focused)
                    .onSubmit { browser.look(forward: true) }
            }
            .font(.system(size: 12.5))
            .frame(width: 160)

            // Which one this is and how many there are, as Chrome says it.
            // Digits of one width, so the arrows beside it keep still while
            // it counts.
            if let said = browser.tally?.said {
                Text(said)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Palette.muted)
                    .fixedSize()
                    .padding(.trailing, 2)
            }

            step("chevron.up") { browser.look(forward: false) }
            step("chevron.down") { browser.look(forward: true) }
            step("xmark") { browser.closeFind() }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Palette.ground, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                browser.missed ? Color.red.opacity(0.35) : Palette.hairline,
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.10), radius: 18, y: 5)
        .padding(.top, 12)
        .padding(.trailing, 14)
        .animation(Motion.quick, value: browser.missed)
        .onAppear { focused = true }
        .onChange(of: browser.findFocus) { _, _ in focused = true }
    }

    private func step(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// How many times the page holds what is looked for, and which of them is
/// the one shown: the "3/12" beside the field.
struct FindTally: Equatable {
    /// How many, as far as they were counted: one past `PageFind.most` means
    /// more than that.
    var count: Int
    /// Which one, the first being 1 — nil where WebKit's word for it can't
    /// be taken (see `PageFind`).
    var place: Int?

    var said: String {
        if count > PageFind.most { return "\(PageFind.most)+" }
        if count == 0 { return "0/0" }
        return place.map { "\($0)/\(count)" } ?? "\(count)"
    }
}

/// WebKit's own count of what a find found.
///
/// WKWebView's find says one thing, found or not. WebKit counts all the same,
/// for whoever asks the way its own test browser does — by names outside the
/// public framework, asked for by name here: a WebKit without them is asked
/// the public way, and the bar shows no numbers, as it never did.
///
/// The count is exact. Which match is the one shown is not something WebKit
/// works out: it keeps a number it puts forward or back by one at each step,
/// right only while every step since the first was its own and the first
/// began at the top of the page. So a new word starts there — the selection
/// let go, the number put back to nothing — which is where a find with no
/// selection starts anyway; and once the selection is no longer the match
/// WebKit left (a click in the page, a word selected by hand), the find goes
/// on from there, as it always did, and only the count is shown.
@MainActor
enum PageFind {
    /// Counted up to here; past it the bar says "1000+", as WebKit's own
    /// find stops counting there too. A letter looked for on a long page is
    /// tens of thousands of matches, walked through again at every key.
    nonisolated static let most = 1000

    private static let find = NSSelectorFromString("_findString:options:maxCount:")
    private static let hide = NSSelectorFromString("_hideFindUI")
    private static let hear = NSSelectorFromString("_setFindDelegate:")

    /// _WKFindOptions: any case, round again at the end, and the number of
    /// the match worked out — which is also what has the matches counted.
    private static let anyCase: UInt = 1 << 0
    private static let backwards: UInt = 1 << 3
    private static let wraps: UInt = 1 << 4
    private static let numbered: UInt = 1 << 9

    static func counts(_ web: WKWebView) -> Bool {
        web.responds(to: find) && web.responds(to: hide) && web.responds(to: hear)
    }

    /// The next match, or the one before: answered to `ears`.
    static func look(for text: String, backwards back: Bool, in web: WKWebView, heard ears: FindEars) {
        web.perform(hear, with: ears)
        typealias Find = @convention(c) (AnyObject, Selector, NSString, UInt, UInt) -> Void
        let options = anyCase | wraps | numbered | (back ? backwards : 0)
        unsafeBitCast(web.method(for: find), to: Find.self)(web, find, text as NSString, options, UInt(most))
    }

    /// WebKit's number for the match put back to nothing, so the next find
    /// counts from the first again.
    static func forget(in web: WKWebView) {
        web.perform(hide)
    }

    // The page's side, in Search's own world.

    /// A new word: the selection let go, so the find starts at the top, and
    /// what the page is — a PDF keeps a selection of its own that nothing
    /// here can let go of.
    static let begin = """
    (function () {
      var s = window.getSelection();
      if (s) s.removeAllRanges();
      window.__searchFound = null;
      return document.contentType || '';
    })()
    """

    /// Whether the selection is still the match the last find left.
    static let still = """
    (function () {
      var s = window.getSelection(), last = window.__searchFound;
      if (!last || !s || s.rangeCount !== 1) return false;
      var r = s.getRangeAt(0);
      return r.startContainer === last.startContainer && r.startOffset === last.startOffset
        && r.endContainer === last.endContainer && r.endOffset === last.endOffset;
    })()
    """

    /// The match a find just left, kept to be compared with. False when it
    /// left none in this page's own text: one inside a frame or a field is
    /// counted from somewhere else than the top of the page.
    static let keep = """
    (function () {
      var s = window.getSelection();
      if (!s || s.rangeCount !== 1 || s.isCollapsed) { window.__searchFound = null; return false; }
      window.__searchFound = s.getRangeAt(0).cloneRange();
      return true;
    })()
    """
}

/// What WebKit says back about a find, through its find delegate. WebKit
/// holds it weakly; the browser keeps it.
final class FindEars: NSObject {
    /// The page, what was looked for, how many there are, and the number of
    /// the one shown, from 0.
    var found: ((WKWebView, String, Int, Int) -> Void)?
    var missed: ((WKWebView, String) -> Void)?

    @objc(_webView:didFindMatches:forString:withMatchIndex:)
    func webView(_ webView: WKWebView, didFindMatches matches: UInt, forString string: NSString, withMatchIndex index: Int) {
        // More than it was asked to count comes as -1.
        let count = Int(bitPattern: matches)
        MainActor.assumeIsolated { found?(webView, string as String, count, index) }
    }

    @objc(_webView:didFailToFindString:)
    func webView(_ webView: WKWebView, didFailToFindString string: NSString) {
        MainActor.assumeIsolated { missed?(webView, string as String) }
    }
}
