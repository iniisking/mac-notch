import Foundation
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
        launchAtLogin = SMAppService.mainApp.status == .enabled
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
