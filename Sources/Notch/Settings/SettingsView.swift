import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var store: NotificationStore
    @ObservedObject var player: NowPlayingService
    @ObservedObject var notifier: SystemTestNotifier
    @ObservedObject var bridge: DeviceBridge
    let openFullDiskAccess: () -> Void
    @State private var newBundleID = ""
    @State private var allShortcuts: [String] = []
    @State private var shortcutToPin = ""
    @State private var copiedBridge = false

    private var appList: [String] {
        let known = Set(store.knownBundleIDs.map { $0.lowercased() })
        let all = known.union(settings.mutedApps)
        return all.sorted { AppInfoProvider.shared.info(for: $0).name.localizedCaseInsensitiveCompare(AppInfoProvider.shared.info(for: $1).name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section("Source") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(store.status.label)
                    }
                }
                if store.status.needsFullDiskAccess {
                    Text("Grant Full Disk Access to Notch.app, then relaunch it.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open Full Disk Access Settings…", action: openFullDiskAccess)
                }
                if case .unavailable(let msg) = store.status {
                    Text(msg).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            TestNotificationsSection(store: store, notifier: notifier)

            Section {
                Toggle("Show now playing in the notch", isOn: $settings.nowPlayingEnabled)
                Toggle("Include other players (generic icon)", isOn: $settings.showOtherPlayers)
                    .disabled(!settings.nowPlayingEnabled)
                LabeledContent("Helper", value: player.status)
                if let info = player.info {
                    LabeledContent("Current", value: "\(info.title) — \(player.source?.displayName ?? "detecting…")")
                }
            } header: {
                Text("Now Playing")
            } footer: {
                Text("Spotify, YouTube Music and YouTube. In a browser, Notch asks the browser for its tab URLs to tell YouTube from YouTube Music (macOS asks for Automation permission once).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show lyrics", isOn: $settings.showLyrics)
                Toggle("Show lyric line under the notch", isOn: $settings.showLyricStrip)
                    .disabled(!settings.showLyrics)
                Toggle("Karaoke highlight", isOn: $settings.lyricsKaraoke)
                    .disabled(!settings.showLyrics)
                Picker("Second line", selection: $settings.lyricsExtra) {
                    ForEach(LyricsExtra.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!settings.showLyrics)
                Toggle("Use the second line in the strip", isOn: $settings.lyricsExtraInStrip)
                    .disabled(!settings.showLyrics || settings.lyricsExtra == .off)
                LabeledContent("Timing offset") {
                    HStack {
                        Stepper(value: $settings.lyricsOffset, in: -5...5, step: 0.1) {
                            Text(String(format: "%+.1fs", settings.lyricsOffset)).monospacedDigit()
                        }
                        Button("Reset") { settings.lyricsOffset = 0 }.disabled(settings.lyricsOffset == 0)
                    }
                }
            } header: {
                Text("Lyrics")
            } footer: {
                Text("Synced lyrics from LRCLIB (lrclib.net), cached on this Mac. Positive offset shows lines earlier; nudge a single song from the hover card. Karaoke uses word timings when LRCLIB has them, otherwise an estimate. Romanization is offline; translation uses Apple Translation (macOS 26+, download languages in System Settings › General › Language & Region).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show a call timer during calls", isOn: $settings.showCalls)
                Toggle("Count any app using the microphone", isOn: $settings.callsAnyApp)
                    .disabled(!settings.showCalls)
                Toggle("Show charging when power connects", isOn: $settings.showCharging)
                Toggle("Low battery alerts (20% and 10%)", isOn: $settings.lowBatteryAlerts)
            } header: {
                Text("Calls & Battery")
            } footer: {
                Text("Calls are detected from which app is recording from the microphone: FaceTime, Phone, Zoom, Teams, Slack, Discord, WhatsApp, Telegram, Signal, Webex and browsers (Meet, Teams and Zoom tabs are named). The hover card's mute button mutes the Mac's input device.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("AirPods & headphones (battery on connect)", isOn: $settings.showAudioDevices)
                Toggle("Universal Clipboard (copied on iPhone / iPad)", isOn: $settings.showUniversalClipboard)
                Toggle("AirDrop received", isOn: $settings.showAirDrop)
                Toggle("Drag files onto the notch to AirDrop them", isOn: $settings.airDropDropZone)
                Toggle("Focus changes (synced from your devices)", isOn: $settings.showFocus)
                Toggle("Personal Hotspot", isOn: $settings.showHotspot)
                Toggle("Up next: calendar + join meeting heads-up", isOn: $settings.showCalendar)
            } header: {
                Text("Devices & Continuity")
            } footer: {
                Text("Headphones need Bluetooth permission and Up next needs Calendar access (macOS asks once). Focus and AirDrop use the Full Disk Access Notch already has. Replying to Messages from the expanded panel asks once to control Messages. Click a moment in the notch to act on it: open the link, show the file, join the meeting.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Accept updates from iPhone Shortcuts", isOn: $settings.bridgeEnabled)
                if settings.bridgeEnabled {
                    LabeledContent("Status", value: bridge.status)
                    if let last = bridge.lastRequest {
                        LabeledContent("Last update", value: last.formatted(date: .omitted, time: .shortened))
                    }
                    LabeledContent("Battery URL") {
                        Text(deviceURL).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                    }
                    HStack {
                        Button(copiedBridge ? "Copied" : "Copy battery URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(deviceURL, forType: .string)
                            copiedBridge = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedBridge = false }
                        }
                        Button("Copy message URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(eventURL, forType: .string)
                        }
                        Spacer()
                        Button("New token") { settings.regenerateBridgeToken() }
                    }
                }
            } header: {
                Text("iPhone bridge")
            } footer: {
                Text("""
                On the iPhone: Shortcuts › Automation › New. Make three automations set to Run Immediately: "Charger › Is Connected", "Charger › Is Disconnected", and "Battery Level › Falls Below 20%". Each runs "Get Battery Level", then "Get Contents of URL" with the battery URL, Method POST, Request Body JSON: name = iPhone, battery = Battery Level, charging = true (connected) or false (the other two). Use the message URL with title / body / symbol fields for anything else, such as a timer or arriving home. Both devices must be on the same network, and macOS may ask to allow incoming connections.
                """)
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(settings.pinnedShortcuts, id: \.self) { name in
                    HStack {
                        Label(name, systemImage: "square.2.layers.3d")
                        Spacer()
                        Button("Remove") { settings.pinnedShortcuts.removeAll { $0 == name } }
                    }
                }
                HStack {
                    Picker("Pin a Shortcut", selection: $shortcutToPin) {
                        Text("Choose…").tag("")
                        ForEach(allShortcuts.filter { !settings.pinnedShortcuts.contains($0) }, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Pin") {
                        settings.pinnedShortcuts.append(shortcutToPin)
                        shortcutToPin = ""
                    }
                    .disabled(shortcutToPin.isEmpty)
                }
            } header: {
                Text("Quick actions")
            } footer: {
                Text("Pinned Shortcuts appear as buttons on the notch's Devices page, next to iPhone Mirroring. Shortcuts synced from your iPhone through iCloud are listed too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onAppear { QuickActions.listShortcuts { allShortcuts = $0 } }

            Section("Display") {
                LabeledContent("Show for") {
                    HStack {
                        Slider(value: $settings.displayDuration, in: 2...10, step: 0.5)
                            .frame(width: 180)
                        Text(String(format: "%.1fs", settings.displayDuration))
                            .monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                Toggle("Show on external displays", isOn: $settings.showOnExternalDisplays)
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }))
                if let err = settings.launchAtLoginError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
            }


            Section {
                if appList.isEmpty {
                    Text("Apps appear here once they've sent a notification.")
                        .foregroundStyle(.secondary)
                }
                ForEach(appList, id: \.self) { bundleID in
                    let info = AppInfoProvider.shared.info(for: bundleID)
                    Toggle(isOn: Binding(
                        get: { settings.isMuted(bundleID) },
                        set: { settings.setMuted(bundleID, $0) })) {
                        HStack(spacing: 8) {
                            Image(nsImage: info.icon).resizable().frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(info.name)
                                Text(bundleID).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                HStack {
                    TextField("Bundle id, e.g. com.apple.mail", text: $newBundleID)
                        .onSubmit(addMute)
                    Button("Mute", action: addMute).disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Muted apps")
            } footer: {
                Text("Muted apps never light up the notch and are hidden from the list.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("History") {
                LabeledContent("Stored", value: "\(store.history.count) notifications")
                Button("Clear History", role: .destructive) { store.clearAll() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 800)
    }

    private var deviceURL: String {
        "\(bridge.baseURL)/v1/device?token=\(settings.bridgeToken)"
    }

    private var eventURL: String {
        "\(bridge.baseURL)/v1/event?token=\(settings.bridgeToken)"
    }

    private var statusColor: Color {
        switch store.status {
        case .running: return .green
        case .starting: return .yellow
        case .permissionDenied: return .orange
        case .unavailable: return .red
        }
    }

    private func addMute() {
        let id = newBundleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        settings.setMuted(id, true)
        newBundleID = ""
    }
}

/// Which Settings tab is showing.
@MainActor
final class SettingsRouter: ObservableObject {
    @Published var tab = "general"
}

/// Tabs: Notch (notifications, media, devices) and Launcher.
struct SettingsRoot: View {
    @ObservedObject var router: SettingsRouter
    let general: SettingsView
    let launcher: LauncherSettingsView
    let shortcuts: CommandShortcutsView

    var body: some View {
        TabView(selection: $router.tab) {
            general
                .tabItem { Label("Notch", systemImage: "rectangle.topthird.inset.filled") }
                .tag("general")
            launcher
                .frame(width: 560, height: 800)
                .tabItem { Label("Launcher", systemImage: "command") }
                .tag("launcher")
            shortcuts
                .frame(width: 560, height: 800)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag("shortcuts")
        }
    }
}

/// Hosts the settings in a normal titled window (the app has no Dock icon).
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let makeView: () -> SettingsRoot
    let router: SettingsRouter

    init(router: SettingsRouter, makeView: @escaping () -> SettingsRoot) {
        self.router = router
        self.makeView = makeView
    }

    func show(tab: String? = nil) {
        if let tab { router.tab = tab }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 840),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Notch Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: makeView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
