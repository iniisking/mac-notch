import AppKit
import Combine
import Quartz

/// Spotlight file search by name (NSMetadataQuery), most recently used first.
@MainActor
final class FileSearch: ObservableObject {
    @Published private(set) var results: [URL] = []
    @Published private(set) var isSearching = false
    private var query: NSMetadataQuery?
    private var pending: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var lastText = ""
    var limit = 40

    func search(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t != lastText else { return }
        lastText = t
        pending?.cancel()
        guard t.count >= 2 else {
            stop()
            results = []
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.start(t) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func stop() {
        query?.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        query = nil
        isSearching = false
    }

    func reset() {
        stop()
        lastText = ""
        results = []
    }

    private func start(_ text: String) {
        stop()
        let q = NSMetadataQuery()
        // Every word must appear in the name: "inv pdf" finds "Invoice March.pdf".
        let words = text.split(separator: " ").map(String.init)
        let parts = words.map { NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, $0) }
        q.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: parts)
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false),
                             NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        q.notificationBatchingInterval = 0.1
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.collect() }
        }
        observers.append(center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main, using: update))
        observers.append(center.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main, using: update))
        query = q
        isSearching = true
        q.start()
    }

    private func collect() {
        guard let q = query else { return }
        q.disableUpdates()
        var urls: [URL] = []
        let count = min(q.resultCount, 400)
        for i in 0..<count {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            // Skip noise inside app bundles, caches and Library.
            if path.contains("/Library/") || path.contains(".app/") || path.contains("/node_modules/") || path.contains("/.") { continue }
            urls.append(URL(fileURLWithPath: path))
            if urls.count >= limit { break }
        }
        q.enableUpdates()
        results = urls
        isSearching = false
    }

    static func item(for url: URL, query: String) -> LauncherItem {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let parent = url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        var item = LauncherItem(
            id: "file:\(url.path)", title: url.lastPathComponent, subtitle: parent, icon: .file(url),
            accessory: isDir ? "Folder" : "File", section: "Files",
            actions: actions(for: url), preview: nil, learnKey: "file:\(url.path)")
        item.score = FuzzyMatch.score(query, url.lastPathComponent) * 0.6
        return item
    }

    static func actions(for url: URL) -> [LauncherAction] {
        [
            LauncherAction(title: "Open", symbol: "arrow.up.forward.square") { m in
                NSWorkspace.shared.open(url); m.hide()
            },
            LauncherAction(title: "Show in Finder", symbol: "folder", shortcut: "⌘↩") { m in
                NSWorkspace.shared.activateFileViewerSelecting([url]); m.hide()
            },
            LauncherAction(title: "Quick Look", symbol: "eye", shortcut: "⌘Y") { m in
                m.quickLook(url)
            },
            LauncherAction(title: "Add to Shelf", symbol: "tray.and.arrow.down") { m in
                m.services.shelf.add([url]); m.hide(toast: "Added to Shelf")
            },
            LauncherAction(title: "Copy File", symbol: "doc.on.doc") { m in
                PasteBack.copy { $0.writeObjects([url as NSURL]) }; m.hide(toast: "File copied")
            },
            LauncherAction(title: "Copy Path", symbol: "link") { m in
                PasteBack.copy(text: url.path); m.hide(toast: "Path copied")
            },
            LauncherAction(title: "Open With Terminal", symbol: "terminal") { m in
                let dir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? url : url.deletingLastPathComponent()
                if let term = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                    NSWorkspace.shared.open([dir], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())
                }
                m.hide()
            },
            LauncherAction(title: "AirDrop", symbol: "dot.radiowaves.up.forward") { m in
                m.hide(); AirDropMonitor.send([url])
            },
            LauncherAction(title: "Move to Trash", symbol: "trash", destructive: true) { m in
                NSWorkspace.shared.recycle([url]) { _, _ in }
                m.refresh()
            },
        ]
    }
}

/// Quick Look from the launcher (a QLPreviewPanel needs a data source object).
final class QuickLookSource: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookSource()
    var urls: [URL] = []

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { urls[index] as NSURL }

    @MainActor
    func show(_ urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}
