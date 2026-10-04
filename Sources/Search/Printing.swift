import AppKit
import WebKit

// Printing: ⌘P, and a page's own Print button.
//
// window.print() — or document.execCommand("print") — reaches the browser
// only through a name outside WebKit's public framework, and with nobody
// answering to it WebKit printed nothing and said nothing: a CV builder's
// Print / PDF button, a boarding pass, a receipt, each a button that did
// nothing at all. Answered, it is the system's own sheet, as ⌘P is, which is
// also where Save as PDF lives.

extension Browser {
    /// ⌘P. The page in front, as it is.
    func printPage() {
        guard let tab = active, !tab.isBlank else { return }
        Printing.run(tab.web) {}
    }

    /// A page asking to be printed. The frame that asked is what goes on the
    /// paper: a site often prints from a frame of its own, made for the
    /// purpose and holding only what is to be printed — react-to-print does,
    /// and printed from the page instead, a CV came out as the website around
    /// it. print() returns once the sheet is put away, as in Safari, so a page
    /// that takes that frame down the moment it returns keeps it until then.
    ///
    /// WebKit holds the page's scripts until it hears back, so every way out
    /// of here answers exactly once: left without an answer, the page would
    /// stand still for good, and never print again.
    @objc(_webView:printFrame:pdfFirstPageSize:completionHandler:)
    func webView(_ webView: WKWebView, printFrame frame: AnyObject?, pdfFirstPageSize: CGSize, completionHandler: @escaping () -> Void) {
        // A tab of Claude's that Claude works in out of sight: there's nobody
        // at it to print for, and the sheet would come down over your page.
        // Claude hears of it with its next answer. One in front of you is
        // yours to print from.
        if let tab = tab(for: webView), tab.bench, tab.id != activeID {
            let host = webView.url?.host() ?? "the page"
            Agent.asked[tab.id, default: []].append(["kind": "print", "message": "\(host) asked to print — nothing was printed", "accepted": false])
            return completionHandler()
        }
        Printing.run(webView, frame: frame, then: completionHandler)
    }
}

@MainActor
enum Printing {
    /// Whether a print sheet is up. A second page asking meanwhile is
    /// answered at once, and printed nothing: two sheets can't share a window.
    private(set) static var busy = false

    /// The print sheet for `web` — for one of its frames, given one — on the
    /// window it is in; `then` once it has been put away, printed or not.
    static func run(_ web: WKWebView, frame: AnyObject? = nil, then: @escaping () -> Void) {
        guard !busy else { return then() }
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = false
        let job = operation(for: web, frame: frame, info: info)
        // WebKit's printing view comes without a size of its own: it is
        // given the page's, as ⌘P always gave it.
        job.view?.frame = web.bounds
        // The name Save as PDF suggests is the printed frame's own title, as
        // in Safari — a page printing its CV from a frame names the frame
        // for the CV, just for the moment — or, with none, the page's.
        if job.view?.printJobTitle.isEmpty ?? true, let title = web.title, !title.isEmpty { job.jobTitle = title }
        busy = true
        let finish = Finish { busy = false; then() }
        if let window = Dialogs.window(for: web) {
            job.runModal(for: window, delegate: finish, didRun: #selector(Finish.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        } else {
            job.run()
            finish.done()
        }
    }

    /// The frame's own print operation, through WebKit's name for it outside
    /// the public framework, asked for first; the whole page otherwise.
    private static func operation(for web: WKWebView, frame: AnyObject?, info: NSPrintInfo) -> NSPrintOperation {
        let forFrame = NSSelectorFromString("_printOperationWithPrintInfo:forFrame:")
        if let frame, web.responds(to: forFrame),
           let job = web.perform(forFrame, with: info, with: frame)?.takeUnretainedValue() as? NSPrintOperation {
            return job
        }
        return web.printOperation(with: info)
    }

    /// What the sheet calls back when it is put away. AppKit keeps no hold
    /// on it, so it keeps one on itself until then.
    private final class Finish: NSObject {
        private var then: (() -> Void)?
        private static var held: Set<Finish> = []

        init(_ then: @escaping () -> Void) {
            self.then = then
            super.init()
            Finish.held.insert(self)
        }

        func done() {
            Finish.held.remove(self)
            let then = self.then
            self.then = nil
            then?()
        }

        @objc func printOperationDidRun(_ job: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            done()
        }
    }
}
