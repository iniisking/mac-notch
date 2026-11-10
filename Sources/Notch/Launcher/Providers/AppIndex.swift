import AppKit

/// Installed applications, rescanned when the launcher opens (at most once a minute) and when
/// the Applications folders change.
@MainActor
final class AppIndex {
    struct App: Hashable {
        let url: URL
        let name: String
        let bundleID: String?
    }

    private(set) var apps: [App] = []
    private var lastScan = Date.distantPast
    private var scanning = false

    nonisolated private static var roots: [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return [
            "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
            "/System/Library/CoreServices/Applications",
        ].map { URL(fileURLWithPath: $0) } + [
            home.appendingPathComponent("Applications"),
            home.appendingPathComponent("Applications/Chrome Apps.localized"),
        ]
    }

    func refreshIfNeeded() {
        guard !scanning, Date().timeIntervalSince(lastScan) > 60 else { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Self.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.apps = found
                    self.lastScan = Date()
                    self.scanning = false
                }
            }
        }
    }

    nonisolated private static func scan() -> [App] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [App] = []
        func add(_ url: URL) {
            let bundle = Bundle(url: url)
            let id = bundle?.bundleIdentifier
            let key = id?.lowercased() ?? url.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            let name = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            out.append(App(url: url, name: name, bundleID: id))
        }
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for url in items {
                if url.pathExtension == "app" {
                    add(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let inner = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    // One level of folders (e.g. "/Applications/Microsoft Office").
                    inner.filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func isRunning(_ bundleID: String?) -> NSRunningApplication? {
        guard let bundleID else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    func items(query: String) -> [LauncherItem] {
        apps.compactMap { app in
            let s = FuzzyMatch.best(query, title: app.name, keywords: app.bundleID.map { [$0.split(separator: ".").last.map(String.init) ?? $0] } ?? [])
            guard s > 0 else { return nil }
            var item = LauncherItem(
                id: "app:\(app.url.path)", title: app.name, subtitle: nil, icon: .app(app.url),
                accessory: "Application", section: "Applications",
                actions: Self.actions(for: app), learnKey: "app:\(app.url.path)")
            item.score = s
            return item
        }
    }

    static func actions(for app: App) -> [LauncherAction] {
        var actions: [LauncherAction] = [
            LauncherAction(title: "Open", symbol: "arrow.up.forward.app") { m in
                NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
                m.hide()
            },
            LauncherAction(title: "Show in Finder", symbol: "folder", shortcut: "⌘↩") { m in
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
                m.hide()
            },
        ]
        if let running = isRunning(app.bundleID) {
            actions.append(LauncherAction(title: "Hide", symbol: "eye.slash") { m in running.hide(); m.hide() })
            actions.append(LauncherAction(title: "Quit", symbol: "xmark.circle", shortcut: "⌘Q") { m in
                running.terminate()
                m.hide()
            })
            actions.append(LauncherAction(title: "Force Quit", symbol: "xmark.octagon", destructive: true) { m in
                running.forceTerminate()
                m.hide()
            })
        }
        actions.append(LauncherAction(title: "Copy Path", symbol: "doc.on.doc") { m in
            PasteBack.copy(text: app.url.path)
            m.hide(toast: "Path copied")
        })
        if let id = app.bundleID {
            actions.append(LauncherAction(title: "Copy Bundle Identifier", symbol: "number") { m in
                PasteBack.copy(text: id)
                m.hide(toast: "Bundle identifier copied")
            })
        }
        return actions
    }

    /// Running regular apps (for "Quit Application").
    static func runningItems(query: String) -> [LauncherItem] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in
                let name = app.localizedName ?? app.bundleIdentifier ?? "App"
                let s = FuzzyMatch.score(query, name)
                guard s > 0 else { return nil }
                var item = LauncherItem(
                    id: "running:\(app.processIdentifier)", title: name,
                    subtitle: app.isHidden ? "Hidden" : app.isActive ? "Frontmost" : nil,
                    icon: app.bundleURL.map { .app($0) } ?? .symbol("app", LauncherColors.gray),
                    accessory: "Running", section: "Running Applications",
                    actions: [
                        LauncherAction(title: "Quit", symbol: "xmark.circle") { m in app.terminate(); m.refresh() },
                        LauncherAction(title: "Force Quit", symbol: "xmark.octagon", shortcut: "⌘↩", destructive: true) { m in
                            app.forceTerminate(); m.refresh()
                        },
                        LauncherAction(title: app.isHidden ? "Unhide" : "Hide", symbol: "eye.slash") { m in
                            _ = app.isHidden ? app.unhide() : app.hide(); m.refresh()
                        },
                        LauncherAction(title: "Switch To", symbol: "arrow.up.forward.app") { m in
                            app.activate(); m.hide()
                        },
                    ])
                item.score = s
                return item
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
