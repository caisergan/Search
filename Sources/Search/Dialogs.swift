import AppKit
import WebKit

// The questions a page is allowed to ask, and the answers it gets.
//
// WebKit does nothing with alert(), confirm(), prompt(), a file input or a
// password-protected site unless somebody answers for them — and "nothing"
// means confirm() is always false, so "leave without saving?" leaves, and a
// file picker that never opens. Each one here is the system's own sheet on the
// window the page is in, which is what every other browser on this Mac shows.

extension Browser {
    // MARK: - alert, confirm, prompt

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        if claudeAnswers(webView, "alert", message) != nil { completionHandler(); return }
        let alert = Dialogs.alert(from: frame, saying: message)
        alert.addButton(withTitle: "OK")
        Dialogs.show(alert, over: webView) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        if let claude = claudeAnswers(webView, "confirm", message) { completionHandler(claude.accept); return }
        let alert = Dialogs.alert(from: frame, saying: message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        Dialogs.show(alert, over: webView) { answer in
            completionHandler(answer == .alertFirstButtonReturn)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        if let claude = claudeAnswers(webView, "prompt", prompt) {
            completionHandler(claude.accept ? (claude.text ?? defaultText ?? "") : nil)
            return
        }
        let alert = Dialogs.alert(from: frame, saying: prompt)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        Dialogs.show(alert, over: webView) { answer in
            completionHandler(answer == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    // MARK: - choosing a file

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        // A file for a page of Claude's goes in with a.upload; the chooser
        // would open on a window nobody sees.
        if claudeAnswers(webView, "file chooser", "the page opened a file chooser — use upload on its field instead") != nil {
            completionHandler(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.resolvesAliases = true
        let finish: (NSApplication.ModalResponse) -> Void = { answer in
            completionHandler(answer == .OK ? panel.urls : nil)
        }
        if let window = Dialogs.window(for: webView) {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    // MARK: - a site that asks who you are, or can't prove who it is

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            trust(webView, challenge, completionHandler)
        case NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodNTLM:
            signIn(webView, challenge, completionHandler)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// Every https connection comes through here, not only the broken ones,
    /// so the certificate is checked first and the system is left to it when
    /// it holds up. When it doesn't: this Mac itself — localhost and its
    /// loopback addresses, which nothing on the network can stand in for —
    /// is taken on trust; anything else, a .local name or a private address
    /// on the same Wi-Fi included, is asked about, once per site per launch,
    /// and only for the page itself, never for something a page pulled in.
    private func trust(
        _ webView: WKWebView,
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host.lowercased()
        if Dialogs.isLoopback(host) || Dialogs.excused.contains(host) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        // Never taken on trust for Claude: its tab goes back, and it is told.
        if claudeAnswers(webView, "certificate", "\(host) can't prove who it is — its certificate isn't trusted; the page was not loaded") != nil {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // A picture, a script, a font from a site with a bad certificate is
        // simply not loaded. Only the page you asked for is worth a question.
        guard let tab = tab(for: webView),
              (tab.address?.host() ?? tab.pending?.host())?.lowercased() == host
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "\(host) can't prove who it is"
        alert.informativeText = "Its certificate isn't trusted by this Mac. Someone could be reading what you send. Continue only if you know why it looks like this."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Go Back")
        alert.addButton(withTitle: "Continue Anyway")
        Dialogs.show(alert, over: webView) { answer in
            guard answer == .alertSecondButtonReturn else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            Dialogs.excused.insert(host)
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    /// A site behind a name and a password — a staging server, a router. One
    /// wrong answer gets another go; the second is taken as "not for me".
    private func signIn(
        _ webView: WKWebView,
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.previousFailureCount < 2 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let space = challenge.protectionSpace
        // Claude signs in only with a name and password it was given for this
        // (a.dialog with text "name:password"); otherwise it is cancelled.
        if let claude = claudeAnswers(webView, "login", "\(space.host) asks for a name and a password" + (space.realm.map { " (“\($0)”)" } ?? "")) {
            let parts = (claude.text ?? "").split(separator: ":", maxSplits: 1).map(String.init)
            if claude.accept, parts.count == 2 {
                completionHandler(.useCredential, URLCredential(user: parts[0], password: parts[1], persistence: .forSession))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = "\(space.host) asks you to sign in"
        alert.informativeText = space.realm.map { "“\($0)”" } ?? "The site wants a name and a password."
        if challenge.previousFailureCount > 0 {
            alert.informativeText += "\nThat wasn't accepted — try again."
        }
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        let name = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        name.placeholderString = "Name"
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        pass.placeholderString = "Password"
        name.nextKeyView = pass
        box.addSubview(name)
        box.addSubview(pass)
        alert.accessoryView = box
        alert.window.initialFirstResponder = name

        Dialogs.show(alert, over: webView) { answer in
            guard answer == .alertFirstButtonReturn else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(
                .useCredential,
                URLCredential(user: name.stringValue, password: pass.stringValue, persistence: .forSession)
            )
        }
    }

    // MARK: - a page that asks before it is left

    /// A page holding something unsaved — a message half written, a form, an
    /// upload under way — says so with a beforeunload handler, and every
    /// browser asks before leaving it: closing its tab, going somewhere else
    /// in it, reloading it. WebKit asks an app that isn't Safari through a
    /// name outside the public framework; with nobody answering to it, the
    /// page was left without a word, and what was in it was gone.
    ///
    /// The words are the browser's own, as in Safari and Chrome — what a
    /// page wrote for this has not been shown in years, a page could say
    /// anything there — and WebKit asks only of a page you have touched.
    @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    func webView(
        _ webView: WKWebView,
        runBeforeUnloadConfirmPanelWithMessage message: NSString?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let tab = tab(for: webView)
        // A tab of Claude's is left as it always was: nobody is there to ask.
        if tab?.bench == true { return completionHandler(true) }
        // Just told to stay: WebKit asks once more while the page is put
        // back as it was (see `stayed`), and the answer hasn't changed.
        if staying.contains(webView) { return completionHandler(false) }
        let host = frame.securityOrigin.host.isEmpty ? (webView.backForwardList.currentItem?.url.host() ?? "") : frame.securityOrigin.host
        leaveAsks.append(LeaveAsk(web: webView, tab: tab?.id, host: host) { [weak self, weak webView] leave in
            completionHandler(leave)
            guard let self, let webView, !leave else { return }
            self.stayed(webView)
        })
        askToLeave()
    }

    /// One question at a time, each over its own page: closing several tabs
    /// at once can raise several, and a sheet for a tab that isn't the one on
    /// screen would be a question about a page nobody can see.
    private func askToLeave() {
        guard leaveAsking == nil, !leaveAsks.isEmpty else { return }
        let ask = leaveAsks.removeFirst()
        guard let web = ask.web else {
            // The page went while its question waited.
            ask.answer(true)
            return askToLeave()
        }
        let tab = ask.tab.flatMap { id in tabs.first { $0.id == id } }
        let closing = tab.map { parting.contains($0.id) } ?? false
        if closing, let tab, tab.id != activeID { select(tab) }
        let site = ask.host.hasPrefix("www.") ? String(ask.host.dropFirst(4)) : ask.host
        let alert = NSAlert()
        alert.messageText = closing ? "Close this tab?" : "Leave this page?"
        alert.informativeText = (site.isEmpty ? "This page" : site) + " may be holding changes you haven't saved."
        alert.addButton(withTitle: closing ? "Close" : "Leave")
        // Escape stays, whatever the button is called.
        alert.addButton(withTitle: "Stay").keyEquivalent = "\u{1b}"
        ask.alert = alert
        ask.finish = { [weak self] leave in
            ask.finish = nil
            ask.answer(leave)
            self?.leaveAsking = nil
            self?.askToLeave()
        }
        leaveAsking = ask
        // A test run started hidden has no window a sheet could come down
        // on — the app took one put up there for its last window closing,
        // and quit. There the question waits for the bench (see `leave`).
        guard !(Store.testing && NSApp.isHidden) else { return }
        Dialogs.show(alert, over: web) { answer in ask.finish?(answer == .alertFirstButtonReturn) }
    }

    /// You chose to stay. A tab that was closing isn't any more. A page that
    /// was being sent elsewhere by Search itself — an address typed, Back, a
    /// reload — is a page WebKit goes on calling loading, under the address
    /// it was asked for and never went to, for as long as nothing else is
    /// loaded: what makes it let go is another load, so it is given one of
    /// its own page, refused as it is asked for (see decidePolicyFor), and
    /// the tab says again what its page is.
    private func stayed(_ webView: WKWebView) {
        let tab = tab(for: webView)
        if let tab, parting.contains(tab.id) {
            stays(tab)
            return
        }
        tab?.stayed()
        guard let here = webView.backForwardList.currentItem?.url,
              webView.isLoading || webView.url != here
        else { return }
        staying.add(webView)
        refusing.add(webView)
        webView.open(here)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak webView] in
            guard let self, let webView else { return }
            self.staying.remove(webView)
            self.refusing.remove(webView)
        }
    }

    // MARK: - a page whose process went away

    /// WebKit runs each page in a process of its own, and the system kills
    /// those under memory pressure — background tabs first. Left alone, the
    /// tab shows white until somebody thinks to reload. Saying so, with the
    /// one thing worth offering, is what the failure view is for.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        tab.fullscreenGone()
        // Being closed, and waiting on a page that can no longer answer.
        if parting.contains(tab.id) {
            close(tab)
            return
        }
        // In front of you: straight back, a reload beats a white page with a
        // button on it. Behind another tab: the moment you come back to it.
        if tab.id == activeID, !tab.isBlank {
            tab.recoverFromCrash()
        } else {
            tab.stale = true
        }
    }
}

/// A page asking whether it may be left, waiting for its turn to be asked.
/// WebKit holds the page until the handler it gave is called, so the handler
/// is kept with the question and called once, whatever becomes of it.
@MainActor
final class LeaveAsk {
    weak var web: WKWebView?
    let tab: Tab.ID?
    let host: String
    /// The sheet, while it is up, and what either of its buttons does.
    var alert: NSAlert?
    var finish: ((Bool) -> Void)?
    private var reply: ((Bool) -> Void)?

    init(web: WKWebView, tab: Tab.ID?, host: String, reply: @escaping (Bool) -> Void) {
        self.web = web
        self.tab = tab
        self.host = host
        self.reply = reply
    }

    func answer(_ leave: Bool) {
        let reply = reply
        self.reply = nil
        reply?(leave)
    }

    /// WebKit raises an exception for a handler let go of without an answer.
    deinit { reply?(true) }
}

enum Dialogs {
    /// Sites with bad certificates that were accepted, for this launch only.
    static var excused = Set<String>()

    static func alert(from frame: WKFrameInfo, saying message: String) -> NSAlert {
        let alert = NSAlert()
        // The site's name as the title, so a page can't dress its message up
        // as one from the system or from the browser.
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says" : host
        alert.informativeText = message
        alert.alertStyle = .informational
        return alert
    }

    /// The window the page is in, or the browser's window for a tab that
    /// isn't on stage right now — one waiting in a room off every screen (see
    /// Backstage) included: a sheet there was a question nobody could see,
    /// and the page stood still until it was answered.
    @MainActor
    static func window(for webView: WKWebView) -> NSWindow? {
        if let window = webView.window, !(window is Room) { return window }
        return Links.browserWindow() ?? NSApp.mainWindow
    }

    @MainActor
    static func show(
        _ alert: NSAlert,
        over webView: WKWebView,
        then finish: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = window(for: webView) {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// This Mac itself: a certificate here can only have been made here.
    /// Only the names that can't mean anything else: localhost, and the
    /// loopback addresses written as addresses — four numbers and nothing
    /// more, so 127.0.0.1.example.com is a website like any other.
    static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return false }
        return parts[0] == "127"
    }
}
