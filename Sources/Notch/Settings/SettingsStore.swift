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
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginError: String?

    init() {
        mutedApps = Set((defaults.stringArray(forKey: "mutedApps") ?? []).map { $0.lowercased() })
        let d = defaults.double(forKey: "displayDuration")
        displayDuration = d > 0 ? d : 4
        showOnExternalDisplays = defaults.bool(forKey: "showOnExternalDisplays")
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
