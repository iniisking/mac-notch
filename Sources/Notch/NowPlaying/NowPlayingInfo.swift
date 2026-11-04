import AppKit

enum MediaSourceKind: Equatable {
    case spotify
    case youtubeMusic
    case youtube
    case other(String)   // bundle id

    var isSupported: Bool {
        if case .other = self { return false }
        return true
    }

    @MainActor var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .youtubeMusic: return "YouTube Music"
        case .youtube: return "YouTube"
        case .other(let id): return AppInfoProvider.shared.info(for: id).name
        }
    }
}

enum MediaCommand: Int {
    case play = 0, pause = 1, togglePlayPause = 2, next = 4, previous = 5
}

struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double          // seconds, 0 if unknown
    var elapsed: Double           // seconds at `timestamp`
    var timestamp: Date
    var rate: Double
    var isPlaying: Bool
    var bundleID: String
    var parentBundleID: String?
    var artwork: NSImage?

    /// Elapsed time extrapolated to `now`.
    func elapsed(at now: Date) -> Double {
        var e = elapsed
        if isPlaying { e += now.timeIntervalSince(timestamp) * (rate > 0 ? rate : 1) }
        if duration > 0 { e = min(e, duration) }
        return max(0, e)
    }

    /// Identity of the track (ignores playback position).
    var trackKey: String { "\(bundleID)|\(title)|\(artist)" }

    static func == (a: NowPlayingInfo, b: NowPlayingInfo) -> Bool {
        a.title == b.title && a.artist == b.artist && a.album == b.album && a.duration == b.duration
            && a.elapsed == b.elapsed && a.timestamp == b.timestamp && a.rate == b.rate
            && a.isPlaying == b.isPlaying && a.bundleID == b.bundleID && a.parentBundleID == b.parentBundleID
            && a.artwork === b.artwork
    }
}

extension Double {
    var mmss: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let s = Int(self.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
