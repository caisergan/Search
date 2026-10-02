import AppKit
import UserNotifications

// Downloads, told to the rest of the Mac the way Safari tells it.
//
// The Finder: a file still coming in shows a bar across its icon, and its
// cross cancels it — a progress published for the file, which is what the
// Finder watches for. The Dock: the Downloads stack gives its little jump
// when a file lands in it, and Search's own icon carries how many are still
// coming in. Get Info says where a file came from. And a download that ends
// while Search is in the background says so in a notification, which shows
// the file when clicked.

@MainActor
final class DownloadsMac: NSObject {
    /// The progress the Finder is shown, one per file coming in.
    private var shown: [UUID: Progress] = [:]
    private var asked = false

    override init() {
        super.init()
        // A test run keeps to itself: no notifications, no asking for them.
        if !Store.testing { UNUserNotificationCenter.current().delegate = self }
    }

    /// Kept in step with the list: a bar in the Finder for each file coming
    /// in, taken away as each stops; the count on the Dock icon.
    func sync(_ items: [Download], count: Int) {
        let going = items.filter { $0.state == .running && $0.file != nil }
        let ids = Set(going.map(\.id))
        for (id, progress) in shown where !ids.contains(id) {
            progress.unpublish()
            shown[id] = nil
        }
        for item in going {
            guard let file = item.file else { continue }
            let progress = shown[item.id] ?? publish(item, file)
            if item.expected > 0, progress.totalUnitCount != item.expected { progress.totalUnitCount = item.expected }
            if progress.completedUnitCount != item.received { progress.completedUnitCount = item.received }
        }
        let badge = count > 0 ? "\(count)" : nil
        if NSApp.dockTile.badgeLabel != badge { NSApp.dockTile.badgeLabel = badge }
    }

    private func publish(_ item: Download, _ file: URL) -> Progress {
        let progress = Progress(parent: nil, userInfo: [
            .fileOperationKindKey: Progress.FileOperationKind.downloading,
            .fileURLKey: file,
        ])
        progress.kind = .file
        progress.totalUnitCount = max(1, item.expected)
        progress.completedUnitCount = item.received
        progress.isCancellable = true
        // The Finder's cross on the file's icon.
        let id = item.id
        progress.cancellationHandler = {
            DispatchQueue.main.async {
                guard let item = Downloads.shared.item(id) else { return }
                Downloads.shared.cancel(item)
            }
        }
        progress.publish()
        shown[item.id] = progress
        return progress
    }

    /// A download at its end: marked with where it came from, the Dock's
    /// stack told, and — Search being in the background — a notification.
    func ended(_ item: Download) {
        if item.state == .done, let file = item.file {
            markOrigin(of: file, item)
            // What makes the Downloads stack in the Dock give its jump.
            DistributedNotificationCenter.default().post(
                name: Notification.Name("com.apple.DownloadFileFinished"), object: file.resolvingSymlinksInPath().path
            )
        }
        guard !Store.testing, !NSApp.isActive, item.state == .done || item.failed else { return }
        notify(item)
    }

    /// Get Info's "Where from": the file's own address, and the page's.
    private func markOrigin(of file: URL, _ item: Download) {
        let origins = [item.source, item.page]
            .compactMap { $0 }
            .filter { ["http", "https", "ftp"].contains($0.scheme?.lowercased() ?? "") }
            .map(\.absoluteString)
        guard !origins.isEmpty,
              let data = try? PropertyListSerialization.data(fromPropertyList: origins, format: .binary, options: 0)
        else { return }
        _ = data.withUnsafeBytes { bytes in
            setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", bytes.baseAddress, data.count, 0, 0)
        }
    }

    private func notify(_ item: Download) {
        let center = UNUserNotificationCenter.current()
        let post = {
            let content = UNMutableNotificationContent()
            if item.state == .done {
                content.title = "Downloaded"
                content.body = item.name
            } else {
                content.title = "Couldn't download \(item.name)"
                if case .failed(let why) = item.state { content.body = why }
            }
            content.userInfo = ["download": item.id.uuidString]
            center.add(UNNotificationRequest(identifier: "download.\(item.id.uuidString)", content: content, trigger: nil))
        }
        if asked {
            post()
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.asked = true
                if granted { post() }
            }
        }
    }
}

extension DownloadsMac: UNUserNotificationCenterDelegate {
    /// Only a download's is shown in front of Search — and only in the
    /// background is one sent — and a site's, which a site sends whenever it
    /// has something to say, as it would in Chrome (see Permissions.swift).
    /// An extension's is left as it was.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let id = notification.request.identifier
        if id.hasPrefix("web.") { return completionHandler([.banner, .list, .sound]) }
        completionHandler(id.hasPrefix("download.") ? [.banner, .list] : [])
    }

    /// A click on one shows the file.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        if identifier.hasPrefix("web.") {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { WebNotifications.shared.clicked(identifier, browser: Downloads.shared.browser) }
                completionHandler()
            }
            return
        }
        let id = (response.notification.request.content.userInfo["download"] as? String).flatMap(UUID.init)
        DispatchQueue.main.async {
            if let id, let item = Downloads.shared.item(id) {
                if item.state == .done {
                    Downloads.shared.reveal(item)
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                    Downloads.shared.browser?.hoarding = true
                }
            }
            completionHandler()
        }
    }
}
