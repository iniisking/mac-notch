import AppKit
import Combine

/// Something copied on another device and handed over by Universal Clipboard.
struct RemoteClip: Equatable {
    var text: String?
    var url: URL?
    var image: NSImage?
    var date: Date

    var preview: String {
        if let url { return url.absoluteString }
        if let text { return NotchNotification.oneLine(text) }
        if image != nil { return "Image" }
        return "Item"
    }

    static func == (a: RemoteClip, b: RemoteClip) -> Bool {
        a.date == b.date && a.text == b.text && a.url == b.url
    }
}

/// Universal Clipboard: polls the general pasteboard's change count (cheap) and, when the new
/// contents carry the `com.apple.is-remote-clipboard` marker, reports them as coming from an
/// iPhone / iPad. Local copies are ignored.
@MainActor
final class ClipboardMonitor: ObservableObject {
    @Published private(set) var last: RemoteClip?
    let received = PassthroughSubject<RemoteClip, Never>()

    static let remoteType = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
    private var changeCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        changeCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else { return }
        changeCount = pb.changeCount
        guard let types = pb.types, types.contains(Self.remoteType) else { return }
        // The remote payload can take a moment to land; read it after a short beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.read() }
    }

    private func read() {
        let pb = NSPasteboard.general
        var clip = RemoteClip(date: Date())
        if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            clip.text = s
            if !s.contains(where: \.isWhitespace), let u = URL(string: s), let scheme = u.scheme,
               ["http", "https"].contains(scheme.lowercased()) {
                clip.url = u
            }
        } else if let u = pb.string(forType: .URL).flatMap(URL.init(string:)) {
            clip.url = u
        }
        if clip.text == nil, clip.url == nil, let img = NSImage(pasteboard: pb) {
            clip.image = img
        }
        DebugLog.write("universal clipboard: \(clip.image != nil ? "image" : clip.url != nil ? "link" : "text")")
        last = clip
        received.send(clip)
    }

    func debugDemo() {
        let clip = RemoteClip(text: "https://developer.apple.com/documentation/appkit",
                              url: URL(string: "https://developer.apple.com/documentation/appkit"), date: Date())
        last = clip
        received.send(clip)
    }
}
