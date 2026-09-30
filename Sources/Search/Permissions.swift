import AppKit
import Combine
import SwiftUI
import UserNotifications
import WebKit

// What a site may use: the camera, the microphone, where you are,
// notifications, pop-up windows — and, each time it is asked for, your screen.
//
// A site asks, a card says so at the top of its page, and the answer is kept for that
// site, as in Chrome: asked once, not at every visit. What was kept can be
// changed on the site's card (a click on the tab you are on › Permissions)
// or forgotten in Settings › Privacy. It stays on this Mac: none of it is
// among the settings that sync (see Sync.swift), since it grants something.
//
// WebKit asks an app that isn't Safari for all but the camera and the
// microphone only through names outside the public framework. They are
// answered here by those names; a WebKit that stopped asking would leave
// a page refused, as every one of them was before.

/// Something a site may ask to use.
enum Permission: String, CaseIterable, Identifiable {
    case camera, microphone, location, notifications, popups, screen

    var id: String { rawValue }

    /// Kept once answered. Your screen is never: what is shown is picked
    /// each time, from the system's own list.
    var kept: Bool { self != .screen }

    /// Every one that is kept, in the order a card lists them.
    static let keptKinds: [Permission] = allCases.filter(\.kept)

    var title: String {
        switch self {
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .location: return "Location"
        case .notifications: return "Notifications"
        case .popups: return "Pop-ups"
        case .screen: return "Screen"
        }
    }

    var symbol: String {
        switch self {
        case .camera: return "video"
        case .microphone: return "mic"
        case .location: return "location"
        case .notifications: return "bell"
        case .popups: return "macwindow.on.rectangle"
        case .screen: return "rectangle.inset.filled.on.rectangle"
        }
    }

    /// The name the Permissions API gives it, for navigator.permissions.query.
    init?(queried name: String) {
        switch name {
        case "camera": self = .camera
        case "microphone": self = .microphone
        case "geolocation": self = .location
        case "notifications", "push": self = .notifications
        default: return nil
        }
    }

    static func kinds(for type: WKMediaCaptureType) -> [Permission] {
        switch type {
        case .camera: return [.camera]
        case .microphone: return [.microphone]
        default: return [.camera, .microphone]
        }
    }
}

/// What a page is taking from the Mac right now: the camera, the microphone,
/// the screen — each off, on, or held quiet.
struct Capture: Equatable {
    var camera: WKMediaCaptureState = .none
    var microphone: WKMediaCaptureState = .none
    var screen: WKMediaCaptureState = .none

    var any: Bool { camera != .none || microphone != .none || screen != .none }
    /// Something of it is on and not held.
    var live: Bool { camera == .active || microphone == .active || screen == .active }

    /// The symbol the row shows: the screen first, then the camera.
    var symbol: String {
        if screen != .none { return "rectangle.inset.filled.on.rectangle" }
        if camera != .none { return live ? "video.fill" : "video.slash.fill" }
        return live ? "mic.fill" : "mic.slash.fill"
    }

    var help: String {
        var what: [String] = []
        if camera != .none { what.append("camera") }
        if microphone != .none { what.append("microphone") }
        if screen != .none { what.append("screen") }
        let list = what.count > 1 ? what.dropLast().joined(separator: ", ") + " and " + what.last! : what.first ?? ""
        return live ? "Using your \(list) — click to pause" : "Your \(list), paused — click to resume"
    }
}

/// What was answered for a site. Nothing kept means it is asked.
enum Choice: String {
    case allow, block
}

/// Every site's answers, kept in Search's settings on this Mac.
@MainActor
final class SitePermissions: ObservableObject {
    static let shared = SitePermissions()

    /// By host, then by what was asked.
    @Published private(set) var sites: [String: [Permission: Choice]] = [:]

    private let store = Store.settings
    private static let key = "permissions"

    private init() {
        let saved = store.dictionary(forKey: SitePermissions.key) as? [String: [String: String]] ?? [:]
        for (host, kinds) in saved {
            var answers: [Permission: Choice] = [:]
            for (kind, choice) in kinds {
                if let kind = Permission(rawValue: kind), kind.kept, let choice = Choice(rawValue: choice) {
                    answers[kind] = choice
                }
            }
            if !answers.isEmpty { sites[host] = answers }
        }
        carryOver()
    }

    func choice(_ kind: Permission, for host: String) -> Choice? {
        sites[host]?[kind]
    }

    /// Kept, or — with nil — forgotten, to be asked again.
    func set(_ choice: Choice?, _ kind: Permission, for host: String) {
        guard kind.kept, !host.isEmpty else { return }
        var answers = sites[host] ?? [:]
        answers[kind] = choice
        sites[host] = answers.isEmpty ? nil : answers
        save()
    }

    func forget(_ host: String) {
        guard sites[host] != nil else { return }
        sites[host] = nil
        save()
    }

    func forgetAll() {
        guard !sites.isEmpty else { return }
        sites = [:]
        save()
    }

    /// The sites with something kept, in order.
    var hosts: [String] { sites.keys.sorted() }

    /// Where the question is from: the frame's own site, which is what a
    /// page embedding another can't answer for.
    static func host(of origin: WKSecurityOrigin, page: WKWebView) -> String {
        let host = origin.host.isEmpty ? (page.url?.host() ?? "") : origin.host
        return host.lowercased()
    }

    private func save() {
        let plain = sites.mapValues { answers in
            Dictionary(uniqueKeysWithValues: answers.map { ($0.key.rawValue, $0.value.rawValue) })
        }
        store.set(plain, forKey: SitePermissions.key)
    }

    /// The camera and microphone answers kept before there was this list:
    /// one setting each, "capture.host|type", WebKit's numbering of what was
    /// asked for — camera, microphone, or both.
    private func carryOver() {
        let old = store.dictionaryRepresentation().filter { $0.key.hasPrefix("capture.") }
        guard !old.isEmpty else { return }
        for (key, value) in old {
            store.removeObject(forKey: key)
            let parts = key.dropFirst("capture.".count).split(separator: "|")
            guard parts.count == 2, let allowed = value as? Bool, let raw = Int(parts[1]),
                  let type = WKMediaCaptureType(rawValue: raw)
            else { continue }
            let host = String(parts[0]).lowercased()
            for kind in Permission.kinds(for: type) where sites[host]?[kind] == nil {
                sites[host, default: [:]][kind] = allowed ? .allow : .block
            }
        }
        save()
    }
}

/// A page asking for something, waiting for an answer. WebKit holds the page
/// until each handler it gave is called, so the handlers are kept with the
/// question and every one of them is called, whatever becomes of it.
@MainActor
final class PermissionAsk: Identifiable, Equatable {
    let id = UUID()
    let host: String
    let kinds: [Permission]
    /// The page that asked. Gone, and the question goes with it.
    weak var page: WKWebView?
    private var answers: [(Bool) -> Void]

    init(host: String, kinds: [Permission], page: WKWebView, answer: @escaping (Bool) -> Void) {
        self.host = host
        self.kinds = kinds
        self.page = page
        answers = [answer]
    }

    nonisolated static func == (a: PermissionAsk, b: PermissionAsk) -> Bool { a.id == b.id }

    /// The same question again from the same page: one answer for both.
    func also(_ answer: @escaping (Bool) -> Void) { answers.append(answer) }

    func answer(_ yes: Bool) {
        let waiting = answers
        answers = []
        waiting.forEach { $0(yes) }
    }

    /// The site, as the tab's card names it.
    var site: String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }

    var symbol: String { kinds.count > 1 ? "video" : kinds.first?.symbol ?? "questionmark" }

    /// What the site wants, after its name.
    var wish: String {
        if Set(kinds) == [.camera, .microphone] { return "wants to use your camera and microphone" }
        switch kinds.first {
        case .camera: return "wants to use your camera"
        case .microphone: return "wants to use your microphone"
        case .location: return "wants to know your location"
        case .notifications: return "wants to send you notifications"
        case .popups: return "wants to open a pop-up window"
        case .screen: return "wants to share your screen"
        case nil: return "wants something"
        }
    }

    /// What follows once allowed, where there is more to it.
    var then: String? {
        switch kinds.first {
        case .screen: return "You pick the window or screen next."
        case .location: return "macOS asks once whether Search may know where this Mac is."
        default: return nil
        }
    }

    /// The whole question, for the bench.
    var question: String { "\(site) \(wish)" }
}

/// A window a page tried to open on its own, without a click or a key, and
/// that was stopped. Said once, at the top of the page, with a way to let it through.
struct BlockedPopup: Equatable, Identifiable {
    let id = UUID()
    /// The site of the page that tried: what "Always allow" is for.
    let host: String
    /// Where the window would have gone, when WebKit said.
    let url: URL?
    let tab: Tab.ID

    var site: String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
}

// MARK: - the question, at the top of the page

/// A site asking for something of yours, as a card hanging from the top of
/// its page: whose page, what it wants, and the two answers, Allow on the
/// right as macOS puts the one that does something. The buttons wait half a
/// second before they take a click, as Chrome's do: a page can't have you
/// double-click a spot and put the card under the second click.
struct PermissionCard: View {
    let ask: PermissionAsk
    let browser: Browser

    @State private var armed = false

    init(ask: PermissionAsk, browser: Browser) {
        self.ask = ask
        self.browser = browser
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // The site's own icon, or its letter, as its tab wears it.
            Mark(icon: Favicons.shared.cached(ask.host), letter: ask.site.first.map { String($0).uppercased() } ?? "•", size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(ask.site)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Image(systemName: ask.symbol)
                        .font(.system(size: 10.5, weight: .medium))
                    Text(ask.wish)
                        .font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Palette.ink.opacity(0.85))
                if let then = ask.then {
                    Text(then)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Button { browser.answerAsk(false) } label: {
                Text("Don't Allow")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Palette.wash, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!armed)
            Button { browser.answerAsk(true) } label: {
                Text("Allow")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!armed)
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 460)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 22, y: 8)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { armed = true }
        }
    }
}

/// A window the page tried to open by itself, stopped: said once, with the
/// window it would have been and a way to let the site's through. Smaller
/// than a question — nothing waits on it.
struct PopupNotice: View {
    let blocked: BlockedPopup
    let browser: Browser

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            Text("Pop-up blocked on \(blocked.site)")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            if blocked.url != nil {
                Button { browser.openBlockedPopup() } label: {
                    Text("Open")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Palette.wash, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(blocked.url?.absoluteString ?? "")
            }
            Button { browser.allowPopups() } label: {
                Text("Always Allow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(Palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
            Button { browser.dismissBlockedPopup() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Not now")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 5)
    }
}

/// A site you let know where you are asked, and macOS said Search may not:
/// where to change that, since nothing in Search can.
struct LocationNotice: View {
    let browser: Browser

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            Text("macOS doesn't let Search use your location")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Button {
                browser.locationRefused = false
                LocationFeed.openSettings()
            } label: {
                Text("Open Settings")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(Palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
            Button { browser.locationRefused = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 5)
    }
}

// MARK: - asking

extension Browser {
    /// Answered at once from what is kept, or asked at the top of the page. A site
    /// refused anything it asked for is refused the lot.
    func ask(_ kinds: [Permission], host: String, from page: WKWebView, answer: @escaping (Bool) -> Void) {
        let kept = SitePermissions.shared
        if kinds.allSatisfy(\.kept) {
            let choices = kinds.map { kept.choice($0, for: host) }
            if choices.contains(.block) { return answer(false) }
            if choices.allSatisfy({ $0 == .allow }) { return answer(true) }
        }
        if let same = asks.first(where: { $0.page === page && $0.kinds == kinds && $0.host == host }) {
            same.also(answer)
            return
        }
        asks.append(PermissionAsk(host: host, kinds: kinds, page: page, answer: answer))
        refreshAsking()
    }

    /// The card's buttons. Kept for the site, unless it was your screen.
    func answerAsk(_ yes: Bool) {
        guard let ask = asking else { return }
        for kind in ask.kinds where kind.kept {
            SitePermissions.shared.set(yes ? .allow : .block, kind, for: ask.host)
        }
        asks.removeAll { $0 === ask }
        ask.answer(yes)
        if yes, ask.kinds.contains(.notifications) { WebNotifications.shared.mayShow() }
        refreshAsking()
    }

    /// Which question is on screen: the first from the tab you are looking
    /// at, or from a page that isn't a tab of the row. A tab behind the one
    /// on screen waits to be looked at, as in Chrome, rather than asking
    /// over somebody else's page. A page that has gone takes its question
    /// with it, refused.
    func refreshAsking() {
        let gone = asks.filter { $0.page == nil || tab(for: $0.page!).map { $0.asleep } == true }
        asks.removeAll { ask in gone.contains { $0 === ask } }
        gone.forEach { $0.answer(false) }
        let shown = asks.first { ask in
            guard let page = ask.page else { return false }
            guard let tab = tabs.first(where: { $0.built === page }) else { return true }
            return tab.id == activeID
        }
        if asking !== shown { asking = shown }
    }

    // MARK: - pop-ups

    /// Whether a page may open a window it asked for. From a click or a key,
    /// always — as Safari's blocker has it — and on its own only where you
    /// let it; stopped, and said so, everywhere else.
    func mayOpen(_ action: WKNavigationAction, from webView: WKWebView) -> Bool {
        let key = "_isUserInitiated"
        if action.responds(to: NSSelectorFromString(key)), action.value(forKey: key) as? Bool == true { return true }
        guard let host = (webView.url?.host() ?? action.sourceFrame.securityOrigin.host).nilIfEmpty?.lowercased() else {
            return false
        }
        switch SitePermissions.shared.choice(.popups, for: host) {
        case .allow:
            return true
        case .block:
            return false
        case nil:
            if let tab = tab(for: webView), tab.id == activeID {
                blockedPopup = BlockedPopup(host: host, url: action.request.url, tab: tab.id)
                let shown = blockedPopup?.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                    if self?.blockedPopup?.id == shown { self?.blockedPopup = nil }
                }
            }
            return false
        }
    }

    /// The notice's buttons: the window it would have been, opened now in a
    /// tab of its own; and pop-ups let through on the site from now on.
    func openBlockedPopup() {
        guard let blocked = blockedPopup else { return }
        blockedPopup = nil
        guard let url = blocked.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        open(url, foreground: true, from: tabs.first { $0.id == blocked.tab })
    }

    func allowPopups() {
        guard let blocked = blockedPopup else { return }
        blockedPopup = nil
        SitePermissions.shared.set(.allow, .popups, for: blocked.host)
        announce("Pop-ups allowed on \(blocked.site)")
    }

    func dismissBlockedPopup() { blockedPopup = nil }
}

// MARK: - what WebKit asks, by the names it asks with

extension Browser {
    /// A tab of Claude's is refused all of these, as it is the camera: nobody
    /// is at its page to be asked (see requestMediaCapturePermissionFor).
    private func refusedForClaude(_ webView: WKWebView, _ what: String, host: String) -> Bool {
        guard let tab = tab(for: webView), tab.bench else { return false }
        Agent.asked[tab.id, default: []].append(["kind": what, "message": "\(host) asked for \(what)", "accepted": false])
        return true
    }

    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func geolocation(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let host = SitePermissions.host(of: origin, page: webView)
        if refusedForClaude(webView, "your location", host: host) { return decisionHandler(.deny) }
        ask([.location], host: host, from: webView) { decisionHandler($0 ? .grant : .deny) }
    }

    @objc(_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:)
    func notificationPermission(_ webView: WKWebView, origin: WKSecurityOrigin, decisionHandler: @escaping (Bool) -> Void) {
        let host = SitePermissions.host(of: origin, page: webView)
        if refusedForClaude(webView, "notifications", host: host) { return decisionHandler(false) }
        ask([.notifications], host: host, from: webView, answer: decisionHandler)
    }

    /// Asked each time, never kept; allowed, the system's own list of
    /// screens and windows is what picks what is shared.
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func displayCapture(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, systemAudio: Bool, decisionHandler: @escaping (Int) -> Void) {
        let host = SitePermissions.host(of: origin, page: webView)
        if refusedForClaude(webView, "your screen", host: host) { return decisionHandler(0) }
        // WKDisplayCapturePermissionDecision: 0 deny, 1 the screen prompt.
        ask([.screen], host: host, from: webView) { decisionHandler($0 ? 1 : 0) }
    }

    /// navigator.permissions.query: what the page would be told if it asked.
    /// WKPermissionDecision's numbering: 0 prompt, 1 granted, 2 denied.
    @objc(_webView:queryPermission:forOrigin:completionHandler:)
    func queryPermission(_ webView: WKWebView, name: String, origin: WKSecurityOrigin, completionHandler: @escaping (Int) -> Void) {
        let host = SitePermissions.host(of: origin, page: webView)
        guard let kind = Permission(queried: name), tab(for: webView)?.bench != true else { return completionHandler(0) }
        switch SitePermissions.shared.choice(kind, for: host) {
        case .allow: completionHandler(1)
        case .block: completionHandler(2)
        case nil: completionHandler(0)
        }
    }

    /// The camera, the microphone or the screen going on, off or quiet: the
    /// tab says so in the row.
    @objc(_webView:mediaCaptureStateDidChange:)
    func mediaCaptureStateDidChange(_ webView: WKWebView, state: UInt) {
        tab(for: webView)?.readCapture()
    }
}

// MARK: - notifications

/// A site's notifications, shown by macOS as the app's own. WebKit hands a
/// page's `new Notification(…)` and a service worker's to the website data
/// store's delegate; this is that delegate, for every store a tab uses. A
/// click brings Search forward on that site's tab.
///
/// A test run shows nothing on anybody's screen and asks macOS nothing: what
/// would have been shown is kept for the bench.
@MainActor
final class WebNotifications: NSObject {
    static let shared = WebNotifications()

    /// What a test run would have shown, for the bench.
    private(set) var shownInTest: [[String: String]] = []
    private var asked = false
    /// Each shown notification's site, by its identifier.
    private var sites: [String: String] = [:]
    /// What WebKit sent, as it sent it, for telling it of a click.
    private var sent: [String: NSDictionary] = [:]

    /// The pages' own, `new Notification(…)`: WebKit hands those to the
    /// process pool's notification provider, set once, as its C interface
    /// has it. A service worker's go to the website data store (below).
    func provide(for pool: WKProcessPool) {
        guard !provided else { return }
        provided = WebKitNotifications.install(on: pool)
    }
    private var provided = false

    /// Every store a tab uses is watched; WebKit keeps its delegate weakly,
    /// and this object for as long as the app runs.
    func watch(_ store: WKWebsiteDataStore) {
        let set = NSSelectorFromString("set_delegate:")
        guard store.responds(to: set) else { return }
        if store.value(forKey: "_delegate") as AnyObject? === self { return }
        store.perform(set, with: self)
    }

    /// A site was just let send them: macOS is asked, once, whether Search
    /// may show notifications at all.
    func mayShow() {
        guard !Store.testing, !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// What WebKit asks as a page opens: which sites may, as origins.
    @objc(notificationPermissionsForWebsiteDataStore:)
    func permissions(_ store: WKWebsiteDataStore) -> NSDictionary {
        allowedOrigins as NSDictionary
    }

    /// A service worker's notification — one a site sends while its tab is
    /// in the background, or gone.
    @objc(websiteDataStore:showNotification:)
    func show(_ store: WKWebsiteDataStore, notification: NSObject) {
        guard let data = notification.perform(NSSelectorFromString("dictionaryRepresentation"))?.takeUnretainedValue() as? NSDictionary
        else { return }
        let origin = notification.value(forKey: "origin") as? String ?? ""
        let host = URL(string: origin)?.host()?.lowercased() ?? ""
        let tag = notification.value(forKey: "tag") as? String ?? ""
        let identifier = "web." + (tag.isEmpty ? UUID().uuidString : "\(origin).\(tag)")
        guard post(identifier, origin: origin, host: host, title: notification.value(forKey: "title") as? String ?? "",
                   body: notification.value(forKey: "body") as? String ?? "", from: "worker")
        else { return }
        clicks[identifier] = { [weak store] in
            let click = NSSelectorFromString("_processPersistentNotificationClick:completionHandler:")
            guard let store, store.responds(to: click) else { return }
            typealias Send = @convention(c) (AnyObject, Selector, NSDictionary, @escaping @convention(block) (Bool) -> Void) -> Void
            unsafeBitCast(store.method(for: click), to: Send.self)(store, click, data) { _ in }
        }
    }

    /// A page's own notification, from WebKit's provider.
    fileprivate func showFromPage(id: UInt64, origin: String, host: String, title: String, body: String, tag: String, manager: UnsafeRawPointer) {
        let identifier = "web." + (tag.isEmpty ? "\(origin).page.\(id)" : "\(origin).\(tag)")
        pages[id] = identifier
        guard post(identifier, origin: origin, host: host, title: title, body: body, from: "page") else { return }
        WebKitNotifications.shown(id, manager: manager)
        clicks[identifier] = { WebKitNotifications.clicked(id, manager: manager) }
    }

    /// The page closed its own notification, or it went with the page.
    fileprivate func closeFromPage(id: UInt64) {
        guard let identifier = pages.removeValue(forKey: id) else { return }
        clicks[identifier] = nil
        if !Store.testing { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier]) }
    }

    /// Only for a site still allowed — a choice changed since WebKit was told
    /// is the one that counts. Whether it went up.
    private func post(_ identifier: String, origin: String, host: String, title: String, body: String, from path: String) -> Bool {
        guard SitePermissions.shared.choice(.notifications, for: host) == .allow else { return false }
        sites[identifier] = origin
        latest[path] = identifier
        if Store.testing {
            shownInTest.append(["title": title, "body": body, "site": host, "from": path])
            return true
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        content.body = body
        content.threadIdentifier = host
        content.userInfo = ["site": host]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        return true
    }

    /// Which sites may, for WebKit's provider: origins, as it compares them.
    fileprivate var allowedOrigins: [String: Bool] {
        var out: [String: Bool] = [:]
        for (host, answers) in SitePermissions.shared.sites {
            guard let choice = answers[.notifications] else { continue }
            out["https://\(host)"] = choice == .allow
            out["http://\(host)"] = choice == .allow
        }
        return out
    }

    private var clicks: [String: () -> Void] = [:]
    private var pages: [UInt64: String] = [:]
    /// The last shown from a page and from a worker, for the bench.
    private var latest: [String: String] = [:]

    /// A click on one: the page told, then Search in front on a tab of that
    /// site — the one with the same origin, port and all, or another of its
    /// host, or a new one on its front page.
    func clicked(_ identifier: String, browser: Browser?) {
        let origin = sites[identifier]
        clicks.removeValue(forKey: identifier)?()
        NSApp.activate(ignoringOtherApps: true)
        guard let browser, let origin, let site = URL(string: origin) else { return }
        let same = browser.tabs.first { $0.address.map(WebNotifications.origin) == origin }
        let host = site.host()?.lowercased()
        if let tab = same ?? browser.tabs.first(where: { $0.address?.host()?.lowercased() == host }) {
            browser.select(tab)
        } else {
            browser.open(site, foreground: true)
        }
    }

    /// An address's origin as WebKit writes one: scheme, host, and a port
    /// only where it isn't the scheme's own.
    static func origin(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        var out = "\(scheme)://\(url.host()?.lowercased() ?? "")"
        if let port = url.port, !(scheme == "https" && port == 443), !(scheme == "http" && port == 80) { out += ":\(port)" }
        return out
    }

    /// For the bench: what a test run would have shown, the last fifty.
    var shown: [[String: String]] { Array(shownInTest.suffix(50)) }

    /// For the bench: a click on the last one shown from a page or from a
    /// worker, as macOS would pass it.
    func clickLast(from path: String, browser: Browser?) {
        guard let identifier = latest[path] else { return }
        clicked(identifier, browser: browser)
    }
}

/// WebKit's C notification provider, by name — the interface its own test
/// runners use to show a page's notifications. Nothing here runs unless every
/// name is there; a WebKit without them leaves pages' notifications unshown,
/// as they were.
@MainActor
private enum WebKitNotifications {
    typealias Ref = UnsafeRawPointer
    private static let wk = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW)

    private static func name<T>(_ symbol: String, _: T.Type) -> T? {
        guard let wk, let found = dlsym(wk, symbol) else { return nil }
        return unsafeBitCast(found, to: T.self)
    }

    private static let copyString = name("WKStringCopyCFString", (@convention(c) (CFAllocator?, Ref) -> Unmanaged<CFString>?).self)
    private static let makeString = name("WKStringCreateWithUTF8CString", (@convention(c) (UnsafePointer<CChar>) -> Ref?).self)
    private static let makeBoolean = name("WKBooleanCreate", (@convention(c) (Bool) -> Ref?).self)
    private static let makeDictionary = name("WKDictionaryCreate", (@convention(c) (UnsafePointer<Ref?>, UnsafePointer<Ref?>, Int) -> Ref?).self)
    private static let release = name("WKRelease", (@convention(c) (Ref) -> Void).self)
    private static let title = name("WKNotificationCopyTitle", (@convention(c) (Ref) -> Ref?).self)
    private static let body = name("WKNotificationCopyBody", (@convention(c) (Ref) -> Ref?).self)
    private static let tag = name("WKNotificationCopyTag", (@convention(c) (Ref) -> Ref?).self)
    private static let origin = name("WKNotificationGetSecurityOrigin", (@convention(c) (Ref) -> Ref?).self)
    private static let host = name("WKSecurityOriginCopyHost", (@convention(c) (Ref) -> Ref?).self)
    private static let originString = name("WKSecurityOriginCopyToString", (@convention(c) (Ref) -> Ref?).self)
    private static let id = name("WKNotificationGetID", (@convention(c) (Ref) -> UInt64).self)
    private static let didShow = name("WKNotificationManagerProviderDidShowNotification", (@convention(c) (Ref, UInt64) -> Void).self)
    private static let didClick = name("WKNotificationManagerProviderDidClickNotification", (@convention(c) (Ref, UInt64) -> Void).self)

    /// The provider as WebKit reads it (WKNotificationProviderV0): a version
    /// and a pointer, then seven callbacks. Made once, for as long as the app
    /// runs.
    private static var provider: UnsafeMutableRawPointer?

    static func install(on pool: WKProcessPool) -> Bool {
        guard let managerOf = name("WKContextGetNotificationManager", (@convention(c) (Ref) -> Ref?).self),
              let set = name("WKNotificationManagerSetProvider", (@convention(c) (Ref, UnsafeRawPointer) -> Void).self),
              copyString != nil, makeString != nil, makeBoolean != nil, makeDictionary != nil, release != nil,
              title != nil, body != nil, tag != nil, origin != nil, host != nil, originString != nil, id != nil, didShow != nil, didClick != nil,
              let notifications = managerOf(Unmanaged.passUnretained(pool).toOpaque())
        else { return false }
        typealias Show = @convention(c) (Ref?, Ref?, Ref?) -> Void
        typealias One = @convention(c) (Ref?, Ref?) -> Void
        typealias Permissions = @convention(c) (Ref?) -> Ref?
        let show: Show = { _, notification, _ in
            guard let raw = notification.map({ UInt(bitPattern: $0) }) else { return }
            MainActor.assumeIsolated {
                guard let notification = UnsafeRawPointer(bitPattern: raw) else { return }
                WebKitNotifications.show(notification)
            }
        }
        let cancel: One = { notification, _ in
            guard let raw = notification.map({ UInt(bitPattern: $0) }) else { return }
            MainActor.assumeIsolated {
                guard let notification = UnsafeRawPointer(bitPattern: raw) else { return }
                WebNotifications.shared.closeFromPage(id: WebKitNotifications.id!(notification))
            }
        }
        let destroyed: One = cancel
        let add: One = { manager, _ in
            let raw = manager.map { UInt(bitPattern: $0) }
            MainActor.assumeIsolated { WebKitNotifications.manager = raw.flatMap { UnsafeRawPointer(bitPattern: $0) } }
        }
        let remove: One = { _, _ in }
        let permissions: Permissions = { _ in
            let raw = MainActor.assumeIsolated { WebKitNotifications.permissions().map { UInt(bitPattern: $0) } }
            return raw.flatMap { UnsafeRawPointer(bitPattern: $0) }
        }
        let clear: One = { _, _ in }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: 72, alignment: 8)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: 72)
        memory.storeBytes(of: Int32(0), toByteOffset: 0, as: Int32.self)
        let callbacks: [UnsafeRawPointer] = [
            unsafeBitCast(show, to: UnsafeRawPointer.self), unsafeBitCast(cancel, to: UnsafeRawPointer.self),
            unsafeBitCast(destroyed, to: UnsafeRawPointer.self), unsafeBitCast(add, to: UnsafeRawPointer.self),
            unsafeBitCast(remove, to: UnsafeRawPointer.self), unsafeBitCast(permissions, to: UnsafeRawPointer.self),
            unsafeBitCast(clear, to: UnsafeRawPointer.self),
        ]
        for (index, callback) in callbacks.enumerated() {
            memory.storeBytes(of: callback, toByteOffset: 16 + 8 * index, as: UnsafeRawPointer.self)
        }
        provider = memory
        manager = notifications
        set(notifications, memory)
        return true
    }

    /// The manager WebKit last named: the one clicks are told to.
    private static var manager: Ref?

    private static func text(_ copied: Ref?) -> String {
        guard let copied else { return "" }
        defer { release?(copied) }
        return (copyString?(nil, copied)?.takeRetainedValue() as String?) ?? ""
    }

    private static func show(_ notification: Ref) {
        guard let manager, let origin = origin?(notification) else { return }
        let site = text(host?(origin)).lowercased()
        WebNotifications.shared.showFromPage(
            id: id!(notification), origin: text(originString?(origin)), host: site, title: text(title?(notification)),
            body: text(body?(notification)), tag: text(tag?(notification)), manager: manager
        )
    }

    static func shown(_ id: UInt64, manager: Ref) { didShow?(manager, id) }
    static func clicked(_ id: UInt64, manager: Ref) { didClick?(manager, id) }

    /// Origins to whether they may, as a WKDictionary WebKit takes ownership of.
    private static func permissions() -> Ref? {
        guard let makeString, let makeBoolean, let makeDictionary, let release else { return nil }
        let allowed = WebNotifications.shared.allowedOrigins
        var keys: [Ref?] = []
        var values: [Ref?] = []
        for (origin, may) in allowed {
            keys.append(origin.withCString { makeString($0) })
            values.append(makeBoolean(may))
        }
        let dictionary = keys.withUnsafeBufferPointer { k in
            values.withUnsafeBufferPointer { v in makeDictionary(k.baseAddress!, v.baseAddress!, allowed.count) }
        }
        (keys + values).compactMap { $0 }.forEach { release($0) }
        return dictionary
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
