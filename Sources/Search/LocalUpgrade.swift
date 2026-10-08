import WebKit

// A site being built on this Mac, and served over plain http, that asks for
// `upgrade-insecure-requests` — Next.js apps with a strict policy, Express
// with helmet's defaults. WebKit honours it on localhost too: the page comes
// in over http, then every stylesheet, script, picture and font it asks for
// is sent to https://localhost, where the dev server isn't listening for
// that, and the page shows as bare text with broken pictures. Chrome leaves
// this Mac's own addresses alone and shows it whole; Safari breaks it as we
// did, and WebKit has no switch for it.
//
// What WebKit can't be told, it can be spared from hearing. A page from this
// Mac that asks for the upgrade is kept rather than shown — the response
// WebKit already has, so the server is asked once — and handed back to the
// same address with that one directive taken out of its policy. Everything
// else the policy says still holds, and the page loads its files over the
// http it came over. Reload, back and forward, a form sent and sent again on
// reload: each response is looked at as it comes, so each is put right.
//
// What it costs: the page is shown once it has all arrived rather than as it
// streams in — a few tens of milliseconds on a dev server's page. What it
// can't reach: a frame inside the page that asks for the upgrade itself (only
// a whole page can be handed back), and a worker served with it.

@MainActor
final class LocalUpgrade: NSObject {
    static let shared = LocalUpgrade()

    /// Sites on this Mac that asked in a `<meta>` tag rather than a header:
    /// that is only seen once the page is in, so the page is loaded again and
    /// from then on every page of theirs is kept and put right on the way in.
    /// Again in a view of its own: WebKit carries a site's upgrade on from one
    /// page to the next in the same view — even about:blank in between keeps
    /// it — so a reload there would still have asked every file over https.
    private var asksInPage: Set<String> = []

    /// Pages being kept, by the view they are for, until all of them is here.
    private var keeping: [ObjectIdentifier: URL] = [:]
    private var kept: [ObjectIdentifier: Kept] = [:]

    /// A form sent to this Mac, kept until its answer is in: WebKit's download
    /// keeps the method but not what was sent, and the page handed back has to
    /// carry both for a reload to send the form again, as any page would.
    private var sent: [ObjectIdentifier: URLRequest] = [:]

    private struct Kept {
        let download: WKDownload
        let view: ObjectIdentifier
        let response: HTTPURLResponse
        let request: URLRequest
        let file: URL
    }

    /// This Mac itself, as a dev server is reached: localhost and its
    /// subdomains, and the loopback addresses.
    static func isLocal(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return false }
        return Dialogs.isLoopback(host) || host.hasSuffix(".localhost") || host == "0.0.0.0"
    }

    static func origin(of url: URL) -> String {
        "\(url.host?.lowercased() ?? ""):\(url.port ?? 80)"
    }

    /// Every main-frame load is told here first, so a form's fields can go
    /// with the page that answers it — and so a page still being kept is let
    /// go once the tab is going somewhere else, rather than taking it back
    /// there when it arrives.
    func asking(_ action: WKNavigationAction, in webView: WKWebView) {
        guard action.targetFrame?.isMainFrame ?? true else { return }
        let view = ObjectIdentifier(webView)
        keeping[view] = nil
        for (id, page) in kept where page.view == view {
            kept[id] = nil
            page.download.cancel { _ in try? FileManager.default.removeItem(at: page.file) }
        }
        let request = action.request
        if Self.isLocal(request.url), request.httpMethod?.uppercased() == "POST", request.httpBody != nil {
            sent[view] = request
        } else {
            sent[view] = nil
        }
    }

    /// Whether this response is to be kept and put right instead of shown.
    func wants(_ response: WKNavigationResponse, in webView: WKWebView) -> Bool {
        guard response.isForMainFrame,
              let http = response.response as? HTTPURLResponse, let url = http.url, Self.isLocal(url),
              ["text/html", "application/xhtml+xml"].contains(http.mimeType?.lowercased() ?? "")
        else { return false }
        let asked = http.value(forHTTPHeaderField: "Content-Security-Policy").map(Self.upgrades) ?? false
        guard asked || asksInPage.contains(Self.origin(of: url)) else { return false }
        keeping[ObjectIdentifier(webView)] = url
        return true
    }

    /// The download a kept page became. False for any other download, which
    /// is the person's own and goes to Downloads as usual.
    func take(_ download: WKDownload, response: URLResponse, in webView: WKWebView) -> Bool {
        let key = ObjectIdentifier(webView)
        guard let url = keeping[key], url == response.url, let http = response as? HTTPURLResponse else { return false }
        keeping[key] = nil
        var request = download.originalRequest ?? URLRequest(url: url)
        // The address it ended at, after any redirect.
        request.url = url
        if let form = sent.removeValue(forKey: key), form.httpMethod == request.httpMethod {
            request.httpBody = form.httpBody
            request.setValue(form.value(forHTTPHeaderField: "Content-Type"), forHTTPHeaderField: "Content-Type")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("search-local-\(UUID().uuidString)")
        kept[ObjectIdentifier(download)] = Kept(download: download, view: key, response: http, request: request, file: file)
        download.delegate = self
        return true
    }

    /// After a page from this Mac is in: did it ask for the upgrade in a
    /// `<meta>` tag? Then its site is remembered and `again` loads the page
    /// once more, in a fresh view — from then on its pages are put right on
    /// the way in.
    func check(_ webView: WKWebView, again: @escaping () -> Void) {
        guard let url = webView.url, Self.isLocal(url), !asksInPage.contains(Self.origin(of: url)) else { return }
        let script = """
        [...document.querySelectorAll('meta[http-equiv]')].some(m =>
            m.httpEquiv.toLowerCase() === 'content-security-policy' && /upgrade-insecure-requests/i.test(m.content))
        """
        webView.evaluateJavaScript(script, in: nil, in: Web.world) { [weak self, weak webView] result in
            guard let self, let webView, case .success(let found as Bool) = result, found,
                  webView.url == url else { return }
            self.asksInPage.insert(Self.origin(of: url))
            again()
        }
    }

    // MARK: - Putting it right

    /// Whether a policy — or several, comma-joined as a repeated header
    /// arrives — asks for the upgrade.
    static func upgrades(_ policy: String) -> Bool {
        policy.split(separator: ",").contains { one in
            one.split(separator: ";").contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "upgrade-insecure-requests" }
        }
    }

    /// The policy without the upgrade, and nothing else changed.
    static func withoutUpgrade(_ policy: String) -> String {
        policy.split(separator: ",", omittingEmptySubsequences: false).map { one in
            one.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.lowercased() != "upgrade-insecure-requests" }
                .joined(separator: "; ")
        }.joined(separator: ", ")
    }

    /// The page with the upgrade taken out of any `<meta>` policy in it. Read
    /// a byte to a character, so a page in any encoding comes back exactly as
    /// it was everywhere but there.
    static func withoutUpgrade(page data: Data) -> Data {
        guard let text = String(data: data, encoding: .isoLatin1),
              text.range(of: "upgrade-insecure-requests", options: .caseInsensitive) != nil,
              let tag = try? NSRegularExpression(pattern: "<meta\\b[^>]*>", options: .caseInsensitive),
              let content = try? NSRegularExpression(pattern: "(\\bcontent\\s*=\\s*)(\"[^\"]*\"|'[^']*')", options: .caseInsensitive)
        else { return data }
        var result = text as NSString
        // From the end, so the ranges still ahead stay where they were.
        for match in tag.matches(in: text, range: NSRange(location: 0, length: result.length)).reversed() {
            let meta = result.substring(with: match.range)
            guard meta.range(of: "content-security-policy", options: .caseInsensitive) != nil,
                  let value = content.firstMatch(in: meta, range: NSRange(location: 0, length: (meta as NSString).length))
            else { continue }
            let quoted = (meta as NSString).substring(with: value.range(at: 2))
            let quote = String(quoted.prefix(1))
            let policy = withoutUpgrade(String(quoted.dropFirst().dropLast()))
            let fixed = (meta as NSString).replacingCharacters(in: value.range(at: 2), with: quote + policy + quote)
            result = result.replacingCharacters(in: match.range, with: fixed) as NSString
        }
        return (result as String).data(using: .isoLatin1) ?? data
    }

    /// The page, whole, handed back to its address with its policy put right.
    private func handBack(_ page: Kept, data: Data, to webView: WKWebView) {
        var headers: [String: String] = [:]
        for (name, value) in page.response.allHeaderFields {
            guard let name = name as? String else { continue }
            switch name.lowercased() {
            case "content-security-policy":
                headers[name] = Self.withoutUpgrade("\(value)")
            // The body was decoded on the way in, so these no longer describe
            // it; and its cookies were kept when it arrived.
            case "content-encoding", "content-length", "transfer-encoding", "set-cookie":
                continue
            default:
                headers[name] = "\(value)"
            }
        }
        guard let url = page.response.url,
              let response = HTTPURLResponse(url: url, statusCode: page.response.statusCode, httpVersion: "HTTP/1.1", headerFields: headers)
        else { return }
        webView.loadSimulatedRequest(page.request, response: response, responseData: Self.withoutUpgrade(page: data))
    }
}

extension LocalUpgrade: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        completionHandler(kept[ObjectIdentifier(download)]?.file)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let page = kept.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let data = try? Data(contentsOf: page.file)
        try? FileManager.default.removeItem(at: page.file)
        guard let data, let webView = download.webView else { return }
        handBack(page, data: data, to: webView)
    }

    /// The server went away mid-page, or the load was stopped: the tab stays
    /// on the page it had, as after any stopped load.
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let page = kept.removeValue(forKey: ObjectIdentifier(download)) else { return }
        try? FileManager.default.removeItem(at: page.file)
    }
}
