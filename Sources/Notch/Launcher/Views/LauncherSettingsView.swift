import AppKit
import Combine
import SwiftUI

/// Settings › Launcher: hotkeys, permissions, clipboard, snippets, quicklinks, windows, timers.
struct LauncherSettingsView: View {
    @ObservedObject var services: LauncherServices
    @ObservedObject var settings: LauncherSettings
    @ObservedObject var snippets: SnippetStore
    @ObservedObject var quicklinks: QuicklinkStore
    @ObservedObject var clipboard: ClipboardHistory
    @State private var trusted = Keystrokes.isTrusted
    @State private var listening = SnippetExpander.hasPermission
    @State private var newIgnored = ""
    @State private var editingSnippet: Snippet?
    @State private var editingLink: Quicklink?
    private let permTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                LabeledContent("Open launcher") { HotKeyRecorder(combo: $settings.launcherHotKey) }
                LabeledContent("Clipboard history") { HotKeyRecorder(combo: $settings.clipboardHotKey) }
                LabeledContent("Emoji & symbols") { HotKeyRecorder(combo: $settings.emojiHotKey) }
                LabeledContent("Snippets") { HotKeyRecorder(combo: $settings.snippetsHotKey) }
                LabeledContent("Everything else") {
                    Button("Open Shortcuts tab…") { services.openSettings(.shortcuts) }
                }
            } header: {
                Text("Hotkeys")
            } footer: {
                Text("Inside the launcher: ↑↓ to move, ↩ to run, ⌘↩ for the second action, ⌘K for all actions, Esc to go back, ⌘1–9 to pick a row. Type “g cats” for a quicklink, “25m timer”, “5 km to mi”, “100 usd to ngn”, “time in tokyo”, “remind call mum tomorrow 6pm” or “note …”.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                permissionRow("Accessibility", granted: trusted,
                              detail: "Paste into apps, window layouts, snippet expansion.") {
                    Keystrokes.requestTrust()
                    Keystrokes.openAccessibilitySettings()
                }
                permissionRow("Input Monitoring", granted: listening,
                              detail: "Only for expanding snippet keywords as you type.") {
                    CGRequestListenEventAccess()
                    Keystrokes.openInputMonitoringSettings()
                }
                HStack {
                    Text("Screen Recording").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Asked the first time you copy text from the screen.").font(.caption).foregroundStyle(.secondary)
                    Button("Open…") { Keystrokes.openScreenRecordingSettings() }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Without Accessibility, ↩ copies instead of pasting. macOS ties these grants to the app's signature, so they survive rebuilds signed with the same identity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onReceive(permTimer) { _ in
                trusted = Keystrokes.isTrusted
                listening = SnippetExpander.hasPermission
            }

            Section("Search") {
                Toggle("Include files (Spotlight) in launcher results", isOn: $settings.searchFiles)
                Toggle("Offer web searches when nothing matches", isOn: $settings.webFallback)
                Toggle("Currency conversion (daily rates from open.er-api.com)", isOn: $settings.currencyRates)
                Toggle("↩ pastes into the frontmost app (⌘↩ copies)", isOn: $settings.pasteOnEnter)
            }

            Section {
                Toggle("Keep clipboard history", isOn: $settings.clipboardHistory)
                Picker("Keep for", selection: $settings.clipboardDays) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Forever").tag(0)
                }
                Picker("Maximum items", selection: $settings.clipboardLimit) {
                    ForEach([100, 250, 500, 1000, 2000], id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Show “Copied” in the notch when you copy", isOn: $settings.clipboardCopyMoment)
                LabeledContent("Stored", value: "\(clipboard.entries.count) items (\(clipboard.entries.filter(\.pinned).count) pinned)")
                Button("Clear History (keeps pinned)", role: .destructive) { clipboard.clear() }
            } header: {
                Text("Clipboard history")
            } footer: {
                Text("Stored only on this Mac (~/Library/Application Support/Notch/clipboard). Items marked concealed or transient by password managers are never saved; neither is anything copied in the apps below.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Ignored apps") {
                ForEach(settings.clipboardIgnoredApps, id: \.self) { id in
                    HStack(spacing: 8) {
                        AppIconView(bundleID: id, size: 18)
                        Text(AppInfoProvider.shared.info(for: id).name)
                        Text(id).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") { settings.clipboardIgnoredApps.removeAll { $0 == id } }
                    }
                }
                HStack {
                    TextField("Bundle id, e.g. com.apple.keychainaccess", text: $newIgnored).onSubmit(addIgnored)
                    Button("Add", action: addIgnored).disabled(newIgnored.trimmingCharacters(in: .whitespaces).isEmpty)
                    Menu("Running app…") {
                        ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }, id: \.processIdentifier) { app in
                            if let id = app.bundleIdentifier {
                                Button(app.localizedName ?? id) {
                                    if !settings.clipboardIgnoredApps.contains(id) { settings.clipboardIgnoredApps.append(id) }
                                }
                            }
                        }
                    }
                    .fixedSize()
                }
            }

            Section {
                Toggle("Expand keywords as you type, in any app", isOn: $settings.snippetExpansion)
                ForEach(snippets.snippets) { s in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name)
                            Text(NotchNotification.oneLine(s.text)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if !s.keyword.isEmpty {
                            Text(s.keyword).font(.caption.monospaced())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                        }
                        Button("Edit") { editingSnippet = s }
                        Button(role: .destructive) { snippets.snippets.removeAll { $0.id == s.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Snippet…") { editingSnippet = Snippet(name: "", text: "") }
            } header: {
                Text("Snippets")
            } footer: {
                Text("Placeholders: {date} {time} {datetime} {isodate} {day} {clipboard} {uuid}, and {cursor} for where the caret should end up. Expansion needs Input Monitoring and Accessibility; it pastes the snippet and puts your clipboard back.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(quicklinks.links) { l in
                    HStack {
                        Image(systemName: l.symbol).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(l.name)
                            Text(l.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(l.keyword).font(.caption.monospaced())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                        Button("Edit") { editingLink = l }
                        Button(role: .destructive) { quicklinks.links.removeAll { $0.id == l.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add Quicklink…") { editingLink = Quicklink(name: "", keyword: "", url: "https://") }
                    Spacer()
                    Button("Restore Defaults") { quicklinks.links = QuicklinkStore.defaults }
                }
            } header: {
                Text("Quicklinks")
            } footer: {
                Text("Use {query} in the URL for searches. A path (/Users/… or ~/…) opens a file or folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Rectangle-style window shortcuts", isOn: $settings.windowHotKeysEnabled)
                Button("Customize window shortcuts…") { services.openSettings(.shortcuts) }
            } header: {
                Text("Window management")
            } footer: {
                Text("Rectangle-style ⌃⌥ shortcuts for the frontmost window. All layouts are also in the launcher (“left half”, “center”, “next display”). Needs Accessibility.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Timers & Shelf") {
                Stepper("Pomodoro focus: \(settings.pomodoroWork) min", value: $settings.pomodoroWork, in: 5...120, step: 5)
                Stepper("Pomodoro break: \(settings.pomodoroBreak) min", value: $settings.pomodoroBreak, in: 1...60)
                Picker("Timer sound", selection: $settings.timerSound) {
                    ForEach(["Glass", "Hero", "Ping", "Purr", "Submarine", "Funk", "Blow", "Bottle", "Frog", "Pop", "Sosumi", "Tink"], id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: settings.timerSound) { _, new in NSSound(named: NSSound.Name(new))?.play() }
                Toggle("Shelf: drop files on the notch to keep them for later", isOn: $settings.shelfEnabled)
                LabeledContent("Notes file") {
                    HStack {
                        Text((settings.notesFile as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseNotesFile)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingSnippet) { s in
            SnippetEditor(snippet: s) { saved in
                if let i = snippets.snippets.firstIndex(where: { $0.id == saved.id }) { snippets.snippets[i] = saved }
                else { snippets.snippets.append(saved) }
            }
        }
        .sheet(item: $editingLink) { l in
            QuicklinkEditor(link: l) { saved in
                if let i = quicklinks.links.firstIndex(where: { $0.id == saved.id }) { quicklinks.links[i] = saved }
                else { quicklinks.links.append(saved) }
            }
        }
    }

    private func permissionRow(_ title: String, granted: Bool, detail: String, request: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Grant…", action: request) } else { Text("Granted").foregroundStyle(.secondary) }
        }
    }

    private func addIgnored() {
        let id = newIgnored.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !settings.clipboardIgnoredApps.contains(id) else { return }
        settings.clipboardIgnoredApps.append(id)
        newIgnored = ""
    }

    private func chooseNotesFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (settings.notesFile as NSString).lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: (settings.notesFile as NSString).deletingLastPathComponent)
        panel.allowedContentTypes = [.init(filenameExtension: "md")!, .plainText]
        if panel.runModal() == .OK, let url = panel.url { settings.notesFile = url.path }
    }
}

private struct SnippetEditor: View {
    @State var snippet: Snippet
    let save: (Snippet) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(snippet.name.isEmpty ? "New Snippet" : "Edit Snippet").font(.headline)
            TextField("Name", text: $snippet.name)
            TextField("Keyword (optional, e.g. ;addr)", text: $snippet.keyword)
            TextEditor(text: $snippet.text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
            Text("{date} {time} {datetime} {isodate} {day} {clipboard} {uuid} {cursor}")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(snippet); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(snippet.name.trimmingCharacters(in: .whitespaces).isEmpty || snippet.text.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 440)
    }
}

private struct QuicklinkEditor: View {
    @State var link: Quicklink
    let save: (Quicklink) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(link.name.isEmpty ? "New Quicklink" : "Edit Quicklink").font(.headline)
            TextField("Name", text: $link.name)
            TextField("Keyword (e.g. gh)", text: $link.keyword)
            TextField("URL with {query}, or a path", text: $link.url)
            TextField("SF Symbol name", text: $link.symbol)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(link); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(link.name.isEmpty || link.url.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}
