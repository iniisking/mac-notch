import Foundation
import Security
import ServiceManagement

/// Second line under lyrics.
enum LyricsExtra: String, CaseIterable, Identifiable {
    case off, romanized, translated
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .romanized: return "Romanization"
        case .translated: return "Translation"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Lower-cased bundle ids that never light up the notch and are hidden from history.
    @Published var mutedApps: Set<String> {
        didSet { defaults.set(Array(mutedApps).sorted(), forKey: "mutedApps") }
    }
    /// Seconds the compact "light up" state stays visible.
    @Published var displayDuration: Double {
        didSet { defaults.set(displayDuration, forKey: "displayDuration") }
    }
    @Published var showOnExternalDisplays: Bool {
        didSet { defaults.set(showOnExternalDisplays, forKey: "showOnExternalDisplays") }
    }
    /// Show Spotify / YouTube Music / YouTube playback in the notch.
    @Published var nowPlayingEnabled: Bool {
        didSet { defaults.set(nowPlayingEnabled, forKey: "nowPlayingEnabled") }
    }
    /// Also show players other than Spotify / YouTube Music / YouTube (with a generic icon).
    @Published var showOtherPlayers: Bool {
        didSet { defaults.set(showOtherPlayers, forKey: "showOtherPlayers") }
    }
    @Published var showLyrics: Bool {
        didSet { defaults.set(showLyrics, forKey: "showLyrics") }
    }
    /// Current lyric line in a slim strip under the compact notch.
    @Published var showLyricStrip: Bool {
        didSet { defaults.set(showLyricStrip, forKey: "showLyricStrip") }
    }
    /// Seconds added to the playback position for lyric timing (positive = lyrics earlier).
    @Published var lyricsOffset: Double {
        didSet { defaults.set(lyricsOffset, forKey: "lyricsOffset") }
    }
    /// Sweep the sung part of the line (word timings when available, otherwise estimated).
    @Published var lyricsKaraoke: Bool {
        didSet { defaults.set(lyricsKaraoke, forKey: "lyricsKaraoke") }
    }
    @Published var lyricsExtra: LyricsExtra {
        didSet { defaults.set(lyricsExtra.rawValue, forKey: "lyricsExtra") }
    }
    /// Show the romanization / translation in the strip instead of the original line.
    @Published var lyricsExtraInStrip: Bool {
        didSet { defaults.set(lyricsExtraInStrip, forKey: "lyricsExtraInStrip") }
    }
    /// Brief "Charging 87%" moment when power is connected.
    @Published var showCharging: Bool {
        didSet { defaults.set(showCharging, forKey: "showCharging") }
    }
    /// Warn at 20% and 10% while on battery.
    @Published var lowBatteryAlerts: Bool {
        didSet { defaults.set(lowBatteryAlerts, forKey: "lowBatteryAlerts") }
    }
    /// Call timer while a call app uses the microphone.
    @Published var showCalls: Bool {
        didSet { defaults.set(showCalls, forKey: "showCalls") }
    }
    /// Treat any app using the microphone as a call (not just known call apps and browsers).
    @Published var callsAnyApp: Bool {
        didSet { defaults.set(callsAnyApp, forKey: "callsAnyApp") }
    }
    /// AirPods / headphones connecting, with battery.
    @Published var showAudioDevices: Bool {
        didSet { defaults.set(showAudioDevices, forKey: "showAudioDevices") }
    }
    /// "Copied from your device" when Universal Clipboard brings something over.
    @Published var showUniversalClipboard: Bool {
        didSet { defaults.set(showUniversalClipboard, forKey: "showUniversalClipboard") }
    }
    /// Files received over AirDrop.
    @Published var showAirDrop: Bool {
        didSet { defaults.set(showAirDrop, forKey: "showAirDrop") }
    }
    /// Dragging files onto the notch offers to AirDrop them.
    @Published var airDropDropZone: Bool {
        didSet { defaults.set(airDropDropZone, forKey: "airDropDropZone") }
    }
    /// Focus changes (synced from iPhone / iPad).
    @Published var showFocus: Bool {
        didSet { defaults.set(showFocus, forKey: "showFocus") }
    }
    /// Personal Hotspot connecting / disconnecting.
    @Published var showHotspot: Bool {
        didSet { defaults.set(showHotspot, forKey: "showHotspot") }
    }
    /// Next calendar event and a heads-up before meetings with a join link.
    @Published var showCalendar: Bool {
        didSet { defaults.set(showCalendar, forKey: "showCalendar") }
    }
    /// Local HTTP endpoint for iPhone Shortcuts automations.
    @Published var bridgeEnabled: Bool {
        didSet { defaults.set(bridgeEnabled, forKey: "bridgeEnabled") }
    }
    @Published private(set) var bridgeToken: String
    /// Shortcuts shown as buttons on the Devices page.
    @Published var pinnedShortcuts: [String] {
        didSet { defaults.set(pinnedShortcuts, forKey: "pinnedShortcuts") }
    }
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginError: String?

    init() {
        mutedApps = Set((defaults.stringArray(forKey: "mutedApps") ?? []).map { $0.lowercased() })
        let d = defaults.double(forKey: "displayDuration")
        displayDuration = d > 0 ? d : 4
        showOnExternalDisplays = defaults.bool(forKey: "showOnExternalDisplays")
        nowPlayingEnabled = defaults.object(forKey: "nowPlayingEnabled") as? Bool ?? true
        showOtherPlayers = defaults.bool(forKey: "showOtherPlayers")
        showLyrics = defaults.object(forKey: "showLyrics") as? Bool ?? true
        showLyricStrip = defaults.object(forKey: "showLyricStrip") as? Bool ?? true
        lyricsOffset = defaults.double(forKey: "lyricsOffset")
        lyricsKaraoke = defaults.object(forKey: "lyricsKaraoke") as? Bool ?? true
        lyricsExtra = LyricsExtra(rawValue: defaults.string(forKey: "lyricsExtra") ?? "") ?? .off
        lyricsExtraInStrip = defaults.bool(forKey: "lyricsExtraInStrip")
        showCharging = defaults.object(forKey: "showCharging") as? Bool ?? true
        lowBatteryAlerts = defaults.object(forKey: "lowBatteryAlerts") as? Bool ?? true
        showCalls = defaults.object(forKey: "showCalls") as? Bool ?? true
        callsAnyApp = defaults.bool(forKey: "callsAnyApp")
        showAudioDevices = defaults.object(forKey: "showAudioDevices") as? Bool ?? true
        showUniversalClipboard = defaults.object(forKey: "showUniversalClipboard") as? Bool ?? true
        showAirDrop = defaults.object(forKey: "showAirDrop") as? Bool ?? true
        airDropDropZone = defaults.object(forKey: "airDropDropZone") as? Bool ?? true
        showFocus = defaults.object(forKey: "showFocus") as? Bool ?? true
        showHotspot = defaults.object(forKey: "showHotspot") as? Bool ?? true
        showCalendar = defaults.object(forKey: "showCalendar") as? Bool ?? true
        bridgeEnabled = defaults.bool(forKey: "bridgeEnabled")
        let token = defaults.string(forKey: "bridgeToken").flatMap { $0.isEmpty ? nil : $0 } ?? Self.makeToken()
        defaults.set(token, forKey: "bridgeToken")
        bridgeToken = token
        pinnedShortcuts = defaults.stringArray(forKey: "pinnedShortcuts") ?? []
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func regenerateBridgeToken() {
        bridgeToken = Self.makeToken()
        defaults.set(bridgeToken, forKey: "bridgeToken")
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func isMuted(_ bundleID: String) -> Bool { mutedApps.contains(bundleID.lowercased()) }

    func setMuted(_ bundleID: String, _ muted: Bool) {
        let key = bundleID.lowercased()
        if muted { mutedApps.insert(key) } else { mutedApps.remove(key) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            launchAtLoginError = "Approve Notch in System Settings › General › Login Items."
        }
    }
}
