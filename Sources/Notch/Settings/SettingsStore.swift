import Foundation
import ServiceManagement

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
