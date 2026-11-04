import AppKit

/// Works out whether a now-playing item is Spotify, YouTube Music, YouTube or something else.
/// Browsers report their own bundle id, so for those we ask the browser for its tab URLs.
@MainActor
final class SourceClassifier {
    private var cache: [String: MediaSourceKind] = [:]
    private var inFlight: Set<String> = []

    /// Chromium-family browsers share the same AppleScript dictionary.
    private static let chromium: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.beta": "Google Chrome Beta",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "Brave Browser",
        "org.chromium.Chromium": "Chromium",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]
    private static let webkit: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.apple.SafariTechnologyPreview": "Safari Technology Preview",
    ]

    /// Returns a cached/immediate answer, or nil and calls `update` later once the browser answers.
    func classify(_ info: NowPlayingInfo, update: @escaping (MediaSourceKind) -> Void) -> MediaSourceKind? {
        let ids = [info.bundleID, info.parentBundleID].compactMap { $0 }
        if ids.contains(where: { $0.lowercased() == "com.spotify.client" }) { return .spotify }

        // Installed web apps (Chrome/Edge PWAs) have their own bundle ids: use the app's name.
        for id in ids where id.contains(".app.") {
            let name = AppInfoProvider.shared.info(for: id).name.lowercased()
            if name.contains("youtube music") { return .youtubeMusic }
            if name.contains("youtube") { return .youtube }
        }

        guard let browserID = ids.first(where: { Self.chromium[$0] != nil || Self.webkit[$0] != nil }) else {
            return .other(info.bundleID)
        }
        let key = "\(browserID)|\(info.title)"
        if let hit = cache[key] { return hit }
        let guess = Self.guess(info, browserID: browserID)
        guard !inFlight.contains(key) else { return guess }
        // Never `tell` a browser that isn't running (that would launch it).
        guard NSRunningApplication.runningApplications(withBundleIdentifier: browserID).first != nil else {
            return guess
        }
        inFlight.insert(key)
        let isSafari = Self.webkit[browserID] != nil
        let appName = Self.chromium[browserID] ?? Self.webkit[browserID]!
        let titleProp = isSafari ? "name" : "title"
        let script = """
        set out to ""
        tell application "\(appName)"
            repeat with w in windows
                repeat with t in tabs of w
                    set out to out & (URL of t) & (character id 9) & (\(titleProp) of t) & linefeed
                end repeat
            end repeat
        end tell
        return out
        """
        // Long timeout: the first run waits for the user to answer the Automation prompt.
        AppleScriptRunner.run(script, timeout: 60) { [weak self] output in
            guard let self else { return }
            self.inFlight.remove(key)
            // No answer (Automation denied / prompt unanswered): keep the metadata-based guess.
            let kind = output == nil ? guess : Self.decide(tabs: output!, info: info, browserID: browserID)
            DebugLog.write("classify '\(info.title)' via \(appName): \(output == nil ? "AppleScript failed (Automation denied?)" : "\(output!.split(separator: "\n").count) tabs") -> \(kind)")
            // Don't cache failures (e.g. Automation not yet allowed) so we retry next track.
            if output != nil { self.cache[key] = kind }
            update(kind)
        }
        // Show something right away; the browser's answer refines it.
        return guess
    }

    /// Best guess from metadata alone: YouTube Music reports an album; YouTube reports the channel
    /// as artist and no album; calls / other web media usually report neither.
    private static func guess(_ info: NowPlayingInfo, browserID: String) -> MediaSourceKind {
        if !info.album.isEmpty { return .youtubeMusic }
        if !info.artist.isEmpty { return .youtube }
        return .other(browserID)
    }

    private static func decide(tabs: String, info: NowPlayingInfo, browserID: String) -> MediaSourceKind {
        var music: [String] = []   // titles of music.youtube.com tabs
        var video: [String] = []   // titles of youtube.com tabs
        for line in tabs.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard let url = parts.first.flatMap(URL.init(string:)), let host = url.host?.lowercased() else { continue }
            let title = parts.count > 1 ? parts[1].lowercased() : ""
            if host == "music.youtube.com" { music.append(title) }
            else if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be" { video.append(title) }
        }
        let t = info.title.lowercased()
        let musicMatch = !t.isEmpty && music.contains { $0.contains(t) }
        let videoMatch = !t.isEmpty && video.contains { $0.contains(t) }
        if musicMatch && !videoMatch { return .youtubeMusic }
        if videoMatch && !musicMatch { return .youtube }
        if !music.isEmpty && video.isEmpty { return .youtubeMusic }
        if !video.isEmpty && music.isEmpty { return .youtube }
        if !music.isEmpty && !video.isEmpty {
            // Both open, no title match: YouTube Music reports an album, plain YouTube doesn't.
            return info.album.isEmpty ? .youtube : .youtubeMusic
        }
        return .other(browserID)
    }
}
