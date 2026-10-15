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

    /// Test runs only: the next print written to this PDF, without the
    /// sheet, so what went on the paper can be read back (see Bench).
    static var toFile: URL?
    /// The last print, for the bench: from a frame of its own or the
    /// whole page, and the name it was given.
    private(set) static var last: [String: Any] = [:]

    /// The print sheet for `web` — for one of its frames, given one — on the
    /// window it is in; `then` once it has been put away, printed or not.
    static func run(_ web: WKWebView, frame: AnyObject? = nil, then: @escaping () -> Void) {
        guard !busy else { return then() }
        let file = Store.testing ? toFile : nil
        toFile = nil
        let info = file.flatMap { _ in NSPrintInfo.shared.copy() as? NSPrintInfo } ?? NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = false
        if let file {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = file
        }
        let (job, framed) = operation(for: web, frame: frame, info: info)
        if file != nil {
            job.showsPrintPanel = false
            job.showsProgressPanel = false
        }
        // WebKit's printing view comes without a size of its own: it is
        // given the page's, as ⌘P always gave it.
        job.view?.frame = web.bounds
        // The name Save as PDF suggests is the printed frame's own title, as
        // in Safari — a page printing its CV from a frame names the frame
        // for the CV, just for the moment — or, with none, the page's.
        if job.view?.printJobTitle.isEmpty ?? true, let title = web.title, !title.isEmpty { job.jobTitle = title }
        last = ["frame": framed, "title": job.jobTitle ?? job.view?.printJobTitle ?? ""]
        busy = true
        let finish = Finish { busy = false; then() }
        if let window = Dialogs.window(for: web) {
            let before = window.attachedSheet
            job.runModal(for: window, delegate: finish, didRun: #selector(Finish.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
            if let sheet = window.attachedSheet, sheet !== before { finish.room = Room(sheet) }
        } else {
            job.run()
            finish.done()
        }
    }

    /// Room for the sheets. The print sheet comes down at its smallest
    /// height, its preview a thumbnail, and Save as PDF comes down over it at
    /// the save panel's smallest — the PDF's title, author and keywords take
    /// most of that, the folders get a strip of five lines, and the print
    /// sheet's preview and its own Cancel and Save show around the edges, two
    /// of each on screen. So the print sheet is given the height of the
    /// window it comes down over, the preview growing with it, and the save
    /// sheet — wider already — at least its height, covering it whole;
    /// neither past the screen, and only ever larger than the system made
    /// them. Each stays resizable as it was, and the save panel's size is the
    /// system's to remember, as when you drag it.
    @MainActor
    private final class Room {
        /// The tallest the print sheet is made: past this a page's preview
        /// only grows emptier around it.
        static let tallest: CGFloat = 860
        /// The height the save sheet is made at least, so its folders get room.
        static let save: CGFloat = 640
        /// Kept clear between a sheet and the edges of its window and screen.
        static let margin: CGFloat = 20

        private weak var sheet: NSWindow?
        private var watching: NSObjectProtocol?

        init(_ sheet: NSWindow) {
            self.sheet = sheet
            let window = sheet.sheetParent?.frame.height ?? Room.tallest
            Room.grow(sheet, to: NSSize(width: sheet.frame.width, height: min(Room.tallest, window - 2 * Room.margin)))
            // A sheet coming down over the print sheet is the save panel:
            // Save as PDF, or another of the PDF menu's that asks where to.
            // Grown once it is attached, which it is by the next turn.
            watching = NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification, object: sheet, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.cover() } }
            }
        }

        deinit {
            if let watching { NotificationCenter.default.removeObserver(watching) }
        }

        private func cover() {
            guard let sheet, let over = sheet.attachedSheet else { return }
            Room.grow(over, to: NSSize(width: over.frame.width, height: max(Room.save, sheet.frame.height)))
        }

        /// `window` made `size`, no smaller than it is, no larger than it
        /// may be or the screen has room for; centred on its parent, where
        /// the system keeps a sheet, and kept on the screen.
        static func grow(_ window: NSWindow, to size: NSSize) {
            guard let screen = (window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: margin, dy: margin) else { return }
            let old = window.frame
            let width = max(old.width, min(size.width, window.maxSize.width, screen.width))
            let height = max(old.height, min(size.height, window.maxSize.height, screen.height))
            guard width > old.width || height > old.height else { return }
            let centre = window.sheetParent.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? NSPoint(x: old.midX, y: old.midY)
            let x = min(max(centre.x - width / 2, screen.minX), screen.maxX - width)
            let y = min(max(centre.y - height / 2, screen.minY), screen.maxY - height)
            window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
    }

    /// The frame's own print operation, through WebKit's name for it outside
    /// the public framework, asked for first; the whole page otherwise.
    private static func operation(for web: WKWebView, frame: AnyObject?, info: NSPrintInfo) -> (NSPrintOperation, framed: Bool) {
        let forFrame = NSSelectorFromString("_printOperationWithPrintInfo:forFrame:")
        if let frame, web.responds(to: forFrame),
           let job = web.perform(forFrame, with: info, with: frame)?.takeUnretainedValue() as? NSPrintOperation {
            return (job, true)
        }
        return (web.printOperation(with: info), false)
    }

    /// What the sheet calls back when it is put away. AppKit keeps no hold
    /// on it, so it keeps one on itself until then.
    private final class Finish: NSObject {
        private var then: (() -> Void)?
        /// The sheets' room, given up with them.
        var room: Room?
        private static var held: Set<Finish> = []

        init(_ then: @escaping () -> Void) {
            self.then = then
            super.init()
            Finish.held.insert(self)
        }

        func done() {
            Finish.held.remove(self)
            room = nil
            let then = self.then
            self.then = nil
            then?()
        }

        @objc func printOperationDidRun(_ job: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            done()
        }
    }
}
