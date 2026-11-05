import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var store: NotificationStore
    @ObservedObject var player: NowPlayingService
    @ObservedObject var notifier: SystemTestNotifier
    let openFullDiskAccess: () -> Void
    @State private var newBundleID = ""

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
                Text("Synced lyrics from LRCLIB (lrclib.net), cached on this Mac. Positive offset shows lines earlier.")
                    .font(.caption).foregroundStyle(.secondary)
            }

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
        .frame(width: 480, height: 760)
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

/// Hosts SettingsView in a normal titled window (the app has no Dock icon).
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let makeView: () -> SettingsView

    init(makeView: @escaping () -> SettingsView) { self.makeView = makeView }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 760),
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
