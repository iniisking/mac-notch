import AppKit
import SwiftUI

/// Settings › Shortcuts: a hotkey and an alias for every command, app, quicklink, snippet,
/// Shortcut and window layout (like Raycast's Extensions settings).
struct CommandShortcutsView: View {
    @ObservedObject var services: LauncherServices
    @ObservedObject var settings: LauncherSettings
    @State private var search = ""
    @State private var onlyAssigned = false
    @State private var catalog: [LauncherItem] = []

    private static let sectionOrder = ["Commands", "Applications", "Window Management", "Quicklinks", "Snippets", "Shortcuts"]

    private var filtered: [(String, [LauncherItem])] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let items = catalog.filter { item in
            if onlyAssigned, settings.commandHotKeys[item.id] == nil, settings.aliases[item.id] == nil { return false }
            guard !q.isEmpty else { return true }
            return FuzzyMatch.best(q, title: item.title, keywords: [settings.aliases[item.id] ?? "", item.subtitle ?? ""]) >= 40
        }
        let groups = Dictionary(grouping: items, by: \.section)
        return Self.sectionOrder.compactMap { name in
            guard let list = groups[name], !list.isEmpty else { return nil }
            return (name, list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search commands, apps, quicklinks…", text: $search)
                    .textFieldStyle(.plain)
                Toggle("Assigned only", isOn: $onlyAssigned).toggleStyle(.checkbox)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            Form {
                if search.isEmpty && !onlyAssigned {
                    Section {
                        LabeledContent("Open Launcher") { HotKeyRecorder(combo: $settings.launcherHotKey) }
                        LabeledContent("Clipboard History") { HotKeyRecorder(combo: $settings.clipboardHotKey) }
                        LabeledContent("Emoji & Symbols") { HotKeyRecorder(combo: $settings.emojiHotKey) }
                        LabeledContent("Snippets") { HotKeyRecorder(combo: $settings.snippetsHotKey) }
                        Toggle("Rectangle-style window shortcuts (⌃⌥ arrows, ⌃⌥↩, ⌃⌥C …)", isOn: $settings.windowHotKeysEnabled)
                    } header: {
                        Text("Launcher")
                    } footer: {
                        Text("Every command below can have its own global hotkey and an alias. You can also set them from the launcher: select something, press ⌘K › Set Hotkey (⇧⌘K) or Set Alias (⇧⌘A). A shortcut can only belong to one command; assigning it again moves it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(filtered, id: \.0) { name, items in
                    Section(name) {
                        ForEach(items) { item in
                            CommandShortcutRow(item: item, settings: settings)
                        }
                    }
                }
                if filtered.isEmpty {
                    Text(catalog.isEmpty ? "Loading…" : "Nothing matches").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .onAppear(perform: reload)
        .onReceive(services.$shortcuts) { _ in reload() }
    }

    private func reload() {
        catalog = services.catalog()
        // Apps are scanned in the background the first time: pick them up when ready.
        if !catalog.contains(where: { $0.id.hasPrefix("app:") }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { catalog = services.catalog() }
        }
    }
}

private struct CommandShortcutRow: View {
    let item: LauncherItem
    @ObservedObject var settings: LauncherSettings
    @State private var alias = ""

    var body: some View {
        HStack(spacing: 10) {
            LauncherIconView(icon: item.icon, size: 22)
                .environment(\.colorScheme, .dark)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if let sub = item.subtitle, !sub.isEmpty, !item.id.hasPrefix("snippet:") {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            TextField("Alias", text: $alias)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .onSubmit { settings.setAlias(alias, for: item.id) }
                .onChange(of: alias) { _, new in
                    // Save as you type (lower-cased, spaces trimmed).
                    if new != (settings.aliases[item.id] ?? "") { settings.setAlias(new, for: item.id) }
                }
            HotKeyRecorder(combo: Binding(
                get: { settings.commandHotKeys[item.id] },
                set: { settings.setHotKey($0, for: item.id) }))
        }
        .onAppear { alias = settings.aliases[item.id] ?? "" }
        .onChange(of: settings.aliases[item.id]) { _, new in if (new ?? "") != alias.lowercased() { alias = new ?? "" } }
    }
}
