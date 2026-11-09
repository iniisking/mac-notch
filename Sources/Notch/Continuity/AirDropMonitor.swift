import AppKit
import Combine
import QuickLookThumbnailing

/// Files that arrived together over AirDrop.
struct AirDropBatch: Identifiable, Equatable {
    let id = UUID()
    var files: [URL]
    var date: Date
    var thumbnail: NSImage?

    var title: String {
        files.count == 1 ? files[0].lastPathComponent : "\(files.count) items"
    }

    static func == (a: AirDropBatch, b: AirDropBatch) -> Bool { a.id == b.id && a.thumbnail === b.thumbnail }
}

/// Incoming AirDrop: watches ~/Downloads (readable thanks to Full Disk Access) and picks out new
/// files whose quarantine attribute names `sharingd`, the AirDrop daemon. Arrivals within a second
/// are grouped, and the first one gets a Quick Look thumbnail.
///
/// Outgoing AirDrop is `send(_:)`: the system AirDrop picker for files dropped on the notch.
@MainActor
final class AirDropMonitor: ObservableObject {
    @Published private(set) var recent: [AirDropBatch] = []
    let received = PassthroughSubject<AirDropBatch, Never>()

    private let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    private var source: DispatchSourceFileSystemObject?
    private var known = Set<String>()
    private var pending: [URL] = []
    private var debounce: DispatchWorkItem?

    func start() {
        guard source == nil else { return }
        known = Set(listing())
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { DebugLog.write("airdrop: can't watch Downloads"); return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func listing() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    private func scan() {
        let now = listing()
        let added = now.filter { !known.contains($0) && !$0.hasPrefix(".") }
        known = Set(now)
        guard !added.isEmpty else { return }
        // sharingd may still be writing; check the quarantine after a beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            for name in added {
                let url = self.folder.appendingPathComponent(name)
                if Self.isAirDrop(url) { self.pending.append(url) }
            }
            self.flushSoon()
        }
    }

    private func flushSoon() {
        guard !pending.isEmpty else { return }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let batch = AirDropBatch(files: pending, date: Date())
        pending.removeAll()
        DebugLog.write("airdrop: received \(batch.files.count) item(s)")
        add(batch)
    }

    private func add(_ batch: AirDropBatch) {
        recent.insert(batch, at: 0)
        if recent.count > 6 { recent.removeLast(recent.count - 6) }
        Self.thumbnail(for: batch.files[0]) { [weak self] img in
            guard let self else { return }
            var b = batch
            b.thumbnail = img
            if let i = self.recent.firstIndex(where: { $0.id == batch.id }) { self.recent[i] = b }
            self.received.send(b)
        }
    }

    /// `com.apple.quarantine` looks like "0083;6720f1a2;sharingd;UUID".
    static func isAirDrop(_ url: URL) -> Bool {
        let name = "com.apple.quarantine"
        let len = getxattr(url.path, name, nil, 0, 0, 0)
        guard len > 0 else { return false }
        var buf = [UInt8](repeating: 0, count: len)
        guard getxattr(url.path, name, &buf, len, 0, 0) == len,
              let s = String(bytes: buf, encoding: .utf8) else { return false }
        return s.split(separator: ";").dropFirst(2).first?.lowercased() == "sharingd"
    }

    static func thumbnail(for url: URL, done: @escaping @MainActor (NSImage?) -> Void) {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2,
                                               representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            let img = rep?.nsImage
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    done(img ?? NSWorkspace.shared.icon(forFile: url.path))
                }
            }
        }
    }

    // MARK: - Sending

    /// Opens the system AirDrop picker for these files.
    static func send(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        DebugLog.write("airdrop: sending \(urls.count) item(s)")
        NSApp.activate(ignoringOtherApps: true)
        if service.canPerform(withItems: urls) {
            service.perform(withItems: urls)
        }
    }

    // MARK: - Debug

    func debugDemo() {
        let url = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails")
        let pics = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?
            .filter { ["heic", "jpg", "png"].contains($0.pathExtension.lowercased()) } ?? []
        add(AirDropBatch(files: [pics.first ?? URL(fileURLWithPath: "/System/Applications/Photos.app")], date: Date()))
    }
}
