import AppKit
import Combine
import CryptoKit

struct LyricWord: Equatable, Codable {
    let time: Double     // seconds from track start
    let text: String     // empty = end-of-line marker
}

struct LyricLine: Equatable, Codable {
    let time: Double     // seconds from track start
    let text: String     // empty = instrumental gap marker
    /// Word timings from enhanced LRC (`<mm:ss.xx>` tags), when the file has them.
    var words: [LyricWord]? = nil
}

enum LyricsState: Equatable {
    case off
    case loading
    case synced([LyricLine])
    case plainOnly
    case notFound
}

/// Finds synced lyrics on LRCLIB (cached on disk, misses included) and tracks the current line
/// from the MediaRemote position: elapsed + (now − timestamp) × rate + user offset.
@MainActor
final class LyricsService: ObservableObject {
    @Published private(set) var state: LyricsState = .off
    /// Index of the line being sung, or nil before the first line / during instrumental gaps.
    @Published private(set) var currentIndex: Int?
    /// Last line whose time has passed (even an empty gap marker); -1 before the first line.
    @Published private(set) var anchorIndex = -1
    /// When the current line started (wall clock), for timing long-line scrolling.
    private(set) var currentLineStart = Date()
    /// Second line per lyric index (romanization or translation, per Settings).
    @Published private(set) var extras: [Int: String] = [:]
    /// Why there is no second line (e.g. translation language not downloaded).
    @Published private(set) var extrasNote: String?
    /// Timing nudge for this song only, on top of the global offset (saved per track).
    @Published private(set) var trackOffset: Double = 0

    private let player: NowPlayingService
    private let settings: SettingsStore
    private var trackKey: String?
    private var fetchTask: Task<Void, Never>?
    private var extrasTask: Task<Void, Never>?
    private var ticker: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(player: NowPlayingService, settings: SettingsStore) {
        self.player = player
        self.settings = settings
        player.$info
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in self?.infoChanged(info) }
            .store(in: &cancellables)
        settings.$showLyrics
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.trackKey = nil
                self?.infoChanged(self?.player.info)
            }
            .store(in: &cancellables)
        settings.$lyricsOffset
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tick() }
            .store(in: &cancellables)
        // Views read these through the service.
        settings.$lyricsKaraoke.merge(with: settings.$lyricsExtraInStrip)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        settings.$lyricsExtra
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshExtras() } }
            .store(in: &cancellables)
    }

    var karaokeEnabled: Bool { settings.lyricsKaraoke }
    var isPlaying: Bool { player.info?.isPlaying ?? false }

    /// Global offset + this track's nudge.
    var effectiveOffset: Double { settings.lyricsOffset + trackOffset }

    /// Whether the hover card reserves a row for the second line (or the note explaining its absence).
    var hasExtraLine: Bool { settings.lyricsExtra != .off && (!extras.isEmpty || extrasNote != nil) }

    /// Text for the strip under the notch: the second line instead of the original when asked.
    func stripText(for index: Int) -> String {
        if settings.lyricsExtraInStrip, let e = extras[index], !e.isEmpty { return e }
        return lines[index].text
    }

    var lines: [LyricLine] {
        if case .synced(let l) = state { return l }
        return []
    }

    var currentLine: LyricLine? { currentIndex.map { lines[$0] } }

    /// How long the current line lasts (until the next line), for marquee timing.
    var currentLineDuration: Double {
        guard let i = currentIndex else { return 0 }
        let l = lines
        return i + 1 < l.count ? max(0.5, l[i + 1].time - l[i].time) : 4
    }

    // MARK: - Track changes

    private func infoChanged(_ info: NowPlayingInfo?) {
        guard settings.showLyrics, let info else {
            fetchTask?.cancel()
            trackKey = nil
            state = .off
            setIndex(nil)
            stopTicker()
            return
        }
        if info.trackKey != trackKey {
            trackKey = info.trackKey
            trackOffset = TrackOffsets.get(info.trackKey)
            setIndex(nil)
            extrasTask?.cancel()
            extras = [:]
            extrasNote = nil
            fetch(for: info)
        }
        // Every MediaRemote update (play, pause, seek) resyncs.
        tick()
        if info.isPlaying, case .synced = state { startTicker() } else { stopTicker() }
    }

    private func fetch(for info: NowPlayingInfo) {
        fetchTask?.cancel()
        state = .loading
        let query = LyricsQuery(info: info, source: player.source)
        let key = trackKey
        fetchTask = Task { [weak self] in
            let result = await LRCLibClient.lyrics(for: query)
            guard let self, !Task.isCancelled, self.trackKey == key else { return }
            self.state = result
            DebugLog.write("lyrics '\(query.title)' / '\(query.artist)': \(Self.describe(result))")
            self.refreshExtras()
            self.infoChanged(self.player.info)
        }
    }

    private static func describe(_ s: LyricsState) -> String {
        switch s {
        case .synced(let l): return "\(l.count) synced lines"
        case .plainOnly: return "plain only"
        case .notFound: return "not found"
        case .loading: return "loading"
        case .off: return "off"
        }
    }

    // MARK: - Sync clock

    private func startTicker() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let info = player.info, case .synced(let l) = state, !l.isEmpty else {
            setIndex(nil)
            if anchorIndex != -1 { anchorIndex = -1 }
            return
        }
        let position = info.elapsed(at: Date()) + effectiveOffset
        // Last line whose time has passed.
        var lo = 0, hi = l.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if l[mid].time <= position { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        if anchorIndex != found { anchorIndex = found }
        guard found >= 0, !l[found].text.isEmpty else { setIndex(nil); return }
        // Hide after the final line has had its time.
        if found == l.count - 1, position - l[found].time > 8 { setIndex(nil); return }
        setIndex(found)
    }

    private func setIndex(_ i: Int?) {
        guard i != currentIndex else { return }
        currentIndex = i
        currentLineStart = Date()
    }

    /// Seeks the player to a line (hover card click).
    func seek(to line: LyricLine) {
        player.seek(to: max(0, line.time - effectiveOffset + 0.05))
    }

    // MARK: - Karaoke

    /// How much of the current line has been sung, 0…1 (by characters). Uses word timings when the
    /// LRC has them; otherwise an estimate from the line's length and the time until the next line.
    func karaokeProgress(at date: Date) -> Double {
        guard let i = currentIndex, let info = player.info else { return 0 }
        let l = lines
        guard i < l.count else { return 0 }
        let line = l[i]
        let pos = info.elapsed(at: date) + effectiveOffset
        let lineEnd = i + 1 < l.count ? l[i + 1].time : line.time + 6
        if let words = line.words, words.contains(where: { !$0.text.isEmpty }) {
            let counts = words.map { Double($0.text.filter { !$0.isWhitespace }.count) }
            let total = counts.reduce(0, +)
            guard total > 0 else { return 1 }
            var done = 0.0
            for (k, w) in words.enumerated() {
                let next = k + 1 < words.count ? words[k + 1].time : min(lineEnd, w.time + max(0.4, counts[k] * 0.15))
                if pos >= next { done += counts[k]; continue }
                if pos > w.time { done += counts[k] * (pos - w.time) / max(0.05, next - w.time) }
                break
            }
            return min(1, max(0, done / total))
        }
        let span = Self.estimatedSpan(chars: line.text.count, gap: lineEnd - line.time)
        return min(1, max(0, (pos - line.time) / span))
    }

    /// Roughly how long a line takes to sing: ~6 characters a second, never past 90% of the gap
    /// to the next line (so long instrumental tails don't stretch the sweep).
    static func estimatedSpan(chars: Int, gap: Double) -> Double {
        max(0.4, min(gap * 0.9, Double(chars) * 0.16 + 0.6))
    }

    // MARK: - Per-track timing

    /// Nudges this song's timing (hover card ±). Positive = lyrics earlier.
    func nudgeTrackOffset(_ delta: Double) {
        guard let key = trackKey else { return }
        trackOffset = ((trackOffset + delta) * 10).rounded() / 10
        TrackOffsets.set(trackOffset, for: key)
        tick()
    }

    func resetTrackOffset() {
        guard let key = trackKey else { return }
        trackOffset = 0
        TrackOffsets.set(0, for: key)
        tick()
    }

    // MARK: - Romanization / translation

    private func refreshExtras() {
        extrasTask?.cancel()
        extras = [:]
        extrasNote = nil
        guard case .synced(let l) = state, settings.showLyrics else { return }
        let texts = l.map(\.text)
        let key = trackKey
        switch settings.lyricsExtra {
        case .off:
            return
        case .romanized:
            extrasTask = Task { [weak self] in
                let out = await Task.detached(priority: .utility) { LyricsRomanizer.romanize(texts) }.value
                guard let self, !Task.isCancelled, self.trackKey == key else { return }
                self.extras = out
            }
        case .translated:
            extrasTask = Task { [weak self] in
                let result = await LyricsTranslator.translate(texts)
                guard let self, !Task.isCancelled, self.trackKey == key else { return }
                switch result {
                case .success(let map): self.extras = map
                case .failure(let note): self.extrasNote = note.message
                }
                DebugLog.write("lyrics translation: \(self.extras.count) lines\(self.extrasNote.map { " (\($0))" } ?? "")")
            }
        }
    }
}

/// Per-track lyric timing nudges, keyed by NowPlayingInfo.trackKey.
enum TrackOffsets {
    private static let key = "lyricsTrackOffsets"

    static func get(_ track: String) -> Double {
        (UserDefaults.standard.dictionary(forKey: key)?[track] as? Double) ?? 0
    }

    static func set(_ value: Double, for track: String) {
        var d = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        d[track] = value == 0 ? nil : value
        UserDefaults.standard.set(d, forKey: key)
    }
}

// MARK: - Query cleaning

struct LyricsQuery {
    let title: String
    let artist: String
    let primaryArtist: String
    let album: String
    let duration: Double

    init(info: NowPlayingInfo, source: MediaSourceKind?) {
        var title = Self.cleanTitle(info.title)
        var artist = Self.cleanArtist(info.artist)
        // YouTube uploads often look like "Artist - Song (Official Video)".
        if let r = title.range(of: " - ") ?? title.range(of: " – ") ?? title.range(of: " — ") {
            let left = String(title[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(title[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !left.isEmpty, !right.isEmpty, source != .spotify {
                if artist.isEmpty || source == .youtube
                    || left.localizedCaseInsensitiveContains(artist) || artist.localizedCaseInsensitiveContains(left) {
                    artist = Self.cleanArtist(left)
                    title = Self.cleanTitle(right)
                }
            }
        }
        self.title = title
        self.artist = artist
        self.primaryArtist = Self.primary(artist)
        self.album = info.album
        self.duration = info.duration
    }

    private static let noise = ["official", "video", "audio", "lyric", "visuali", "music video", " mv", "hd", "4k",
                                "remaster", "explicit", "clean", "color coded", "performance", "1080", "720"]

    static func cleanTitle(_ s: String) -> String {
        var t = NotchNotification.clean(s)
        // Drop every (…) / […] / 【…】 group that holds a noise word or a featuring/producer credit.
        let group = try! NSRegularExpression(pattern: #"\s*[\(\[【]([^\)\]】]*)[\)\]】]"#)
        for m in group.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
            guard let whole = Range(m.range, in: t), let innerR = Range(m.range(at: 1), in: t) else { continue }
            let inner = t[innerR].lowercased().trimmingCharacters(in: .whitespaces)
            let isNoise = noise.contains { inner.contains($0) } || inner.hasPrefix("feat") || inner.hasPrefix("ft")
                || inner.hasPrefix("with ") || inner.hasPrefix("prod")
            if isNoise { t.removeSubrange(whole) }
        }
        // Trailing " ft. X" / " feat. X" without brackets.
        if let r = t.range(of: #"\s+(ft\.?|feat\.?|featuring)\s+.*$"#, options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(r)
        }
        t = t.replacingOccurrences(of: #"\s*\|\s*.*$"#, with: "", options: .regularExpression)   // "Song | Channel"
        return t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—").union(.whitespaces))
    }

    static func cleanArtist(_ s: String) -> String {
        var a = NotchNotification.clean(s)
        a = a.replacingOccurrences(of: #"\s*-\s*Topic$"#, with: "", options: [.regularExpression, .caseInsensitive])
        a = a.replacingOccurrences(of: #"\s*VEVO$"#, with: "", options: [.regularExpression, .caseInsensitive])
        a = a.replacingOccurrences(of: #"\s*(Official|Music)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return a.trimmingCharacters(in: .whitespaces)
    }

    static func primary(_ artist: String) -> String {
        let pattern = #"\s*(,|&|\bx\b|\band\b|\bfeat\.?|\bft\.?|\bfeaturing\b|\bwith\b)\s*"#
        if let r = artist.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            return String(artist[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return artist
    }

    var cacheKey: String {
        let raw = "\(title.lowercased())|\(artist.lowercased())|\(Int(duration.rounded()))"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
}

// MARK: - LRCLIB client

enum LRCLibClient {
    private struct Record: Codable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    private struct CacheEntry: Codable {
        let synced: String?
        let plain: String?
        let fetched: Date
    }

    private static let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notch/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.httpAdditionalHeaders = ["User-Agent": "Notch/1.0 (personal macOS notch app)"]
        return URLSession(configuration: c)
    }()

    static func lyrics(for q: LyricsQuery) async -> LyricsState {
        guard !q.title.isEmpty else { return .notFound }
        let file = cacheDir.appendingPathComponent("\(q.cacheKey).json")
        if let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) {
            return state(from: entry)
        }
        do {
            let record = try await find(q)
            let entry = CacheEntry(synced: record?.syncedLyrics, plain: record?.plainLyrics, fetched: Date())
            if let data = try? JSONEncoder().encode(entry) { try? data.write(to: file, options: .atomic) }
            return state(from: entry)
        } catch {
            // Network error: don't cache, so the next play retries.
            DebugLog.write("lyrics fetch failed: \(error.localizedDescription)")
            return .notFound
        }
    }

    private static func state(from e: CacheEntry) -> LyricsState {
        if let s = e.synced, !s.isEmpty {
            let lines = LRCParser.parse(s)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let p = e.plain, !p.isEmpty { return .plainOnly }
        return .notFound
    }

    private static func find(_ q: LyricsQuery) async throws -> Record? {
        var fallback: Record?
        let artists = Array(NSOrderedSet(array: [q.artist, q.primaryArtist].filter { !$0.isEmpty })) as? [String] ?? []
        for artist in artists {
            if let r = try await get(title: q.title, artist: artist, album: q.album, duration: q.duration) {
                if r.syncedLyrics?.isEmpty == false { return r }
                fallback = fallback ?? r
            }
        }
        // Search: prefer synced lyrics with a matching duration and title.
        let term = [q.title, q.primaryArtist].filter { !$0.isEmpty }.joined(separator: " ")
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: term)]
        let (data, resp) = try await session.data(from: comps.url!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return fallback }
        let results = (try? JSONDecoder().decode([Record].self, from: data)) ?? []
        let title = q.title.lowercased()
        let scored = results.compactMap { r -> (Record, Double)? in
            var score = 0.0
            if r.syncedLyrics?.isEmpty == false { score += 4 }
            let name = (r.trackName ?? "").lowercased()
            if name == title { score += 3 } else if name.contains(title) || title.contains(name) { score += 1.5 } else { return nil }
            if q.duration > 0, let d = r.duration {
                let diff = abs(d - q.duration)
                if diff <= 2 { score += 3 } else if diff <= 6 { score += 1 } else if diff > 20 { return nil }
            }
            if let a = r.artistName?.lowercased(), !q.primaryArtist.isEmpty, a.contains(q.primaryArtist.lowercased()) {
                score += 2
            }
            return (r, score)
        }
        if let best = scored.max(by: { $0.1 < $1.1 })?.0 { return best }
        return fallback
    }

    private static func get(title: String, artist: String, album: String, duration: Double) async throws -> Record? {
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        var items = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        comps.queryItems = items
        let (data, resp) = try await session.data(from: comps.url!)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200 else { throw URLError(.badServerResponse) }
        return try? JSONDecoder().decode(Record.self, from: data)
    }
}

// MARK: - LRC

enum LRCParser {
    /// Parses "[mm:ss.xx]text" lines (multiple timestamps per line allowed). Sorted by time.
    static func parse(_ lrc: String) -> [LyricLine] {
        var out: [LyricLine] = []
        var offset = 0.0
        let tag = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)
        for raw in lrc.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("[offset:"),
               let v = Double(line.dropFirst(8).dropLast().trimmingCharacters(in: .whitespaces)) {
                offset = v / 1000
                continue
            }
            let ns = line as NSString
            let matches = tag.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last, matches.first?.range.location == 0 else { continue }
            let rest = ns.substring(from: last.range.location + last.range.length)
            for m in matches {
                let time = max(0, seconds(ns, m) - offset)
                let (text, words) = parseWords(rest, lineTime: time, offset: offset)
                // Word times only make sense for a line with one timestamp.
                out.append(LyricLine(time: time, text: text, words: matches.count == 1 ? words : nil))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    private static func seconds(_ ns: NSString, _ m: NSTextCheckingResult) -> Double {
        let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
        let sec = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
        return min * 60 + sec
    }

    private static let wordTag = try! NSRegularExpression(pattern: #"<(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)>"#)

    /// Splits "<00:12.30>Hello <00:12.80>world" into plain text + word timings. Lines without
    /// (enough) word tags come back as plain text and nil.
    static func parseWords(_ rest: String, lineTime: Double, offset: Double) -> (String, [LyricWord]?) {
        let ns = rest as NSString
        let matches = wordTag.matches(in: rest, range: NSRange(location: 0, length: ns.length))
        func collapse(_ s: String) -> String {
            s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        guard !matches.isEmpty else { return (collapse(rest), nil) }
        var words: [LyricWord] = []
        let lead = ns.substring(to: matches[0].range.location)
        if !collapse(lead).isEmpty { words.append(LyricWord(time: lineTime, text: lead)) }
        for (k, m) in matches.enumerated() {
            let start = m.range.location + m.range.length
            let end = k + 1 < matches.count ? matches[k + 1].range.location : ns.length
            let text = ns.substring(with: NSRange(location: start, length: end - start))
            words.append(LyricWord(time: max(0, seconds(ns, m) - offset), text: collapse(text).isEmpty ? "" : text))
        }
        let plain = collapse(words.map(\.text).joined())
        return (plain, words.filter { !$0.text.isEmpty }.count >= 2 ? words : nil)
    }
}
