import AppKit
import Combine
import QuickLookThumbnailing

/// Files parked on the notch: drop them on the Shelf zone, drag them back out later.
/// Only references are kept (the files stay where they are). Missing files drop off.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [URL] = []
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    private static let file = LauncherSettings.supportDirectory.appendingPathComponent("shelf.json")

    init() {
        let paths = JSONFile.load([String].self, from: Self.file) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        items.forEach(loadThumbnail)
    }

    func add(_ urls: [URL]) {
        for u in urls where !items.contains(u) {
            items.append(u)
            loadThumbnail(u)
        }
        save()
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        thumbnails[url] = nil
        save()
    }

    func clear() {
        items.removeAll()
        thumbnails.removeAll()
        save()
    }

    /// Drop entries whose file was moved or deleted.
    func prune() {
        let before = items.count
        items.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        if items.count != before { save() }
    }

    private func save() {
        JSONFile.save(items.map(\.path), to: Self.file)
    }

    private func loadThumbnail(_ url: URL) {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            guard let img = rep?.nsImage else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.thumbnails[url] = img } }
        }
    }

    func icon(_ url: URL) -> NSImage {
        thumbnails[url] ?? IconCache.icon(forFile: url)
    }
}
