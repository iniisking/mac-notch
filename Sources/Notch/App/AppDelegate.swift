import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = SettingsStore()
    private lazy var store = NotificationStore(settings: settings)
    private lazy var player = NowPlayingService(settings: settings)
    private let testNotifier = SystemTestNotifier()
    private lazy var lyrics = LyricsService(player: player, settings: settings)
    private lazy var calls = CallMonitor(settings: settings)
    private let power = PowerMonitor()
    private lazy var hub = ContinuityHub(settings: settings)
    private lazy var launcher = LauncherServices(hub: hub)
    private let source = DBNotificationSource()
    private var controllers: [CGDirectDisplayID: NotchWindowController] = [:]
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var onboardingShown = false

    private let settingsRouter = SettingsRouter()
    private lazy var settingsWindow = SettingsWindowController(router: settingsRouter) { [unowned self] in
        SettingsRoot(
            router: self.settingsRouter,
            general: SettingsView(settings: self.settings, store: self.store, player: self.player,
                                  notifier: self.testNotifier, bridge: self.hub.bridge,
                                  openFullDiskAccess: { [unowned self] in self.openFullDiskAccess() }),
            launcher: LauncherSettingsView(services: self.launcher, settings: self.launcher.settings,
                                           snippets: self.launcher.snippets, quicklinks: self.launcher.quicklinks,
                                           clipboard: self.launcher.clipboard),
            shortcuts: CommandShortcutsView(services: self.launcher, settings: self.launcher.settings))
    }
    private lazy var onboarding = OnboardingWindowController(
        store: store,
        openSettings: { [unowned self] in self.openFullDiskAccess() },
        relaunch: { [unowned self] in self.relaunch() })

    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        rebuildWindows()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildWindows() }
            .store(in: &cancellables)
        settings.$showOnExternalDisplays
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildWindows() }
            .store(in: &cancellables)

        store.$status
            .removeDuplicates()
            .sink { [weak self] status in self?.statusChanged(status) }
            .store(in: &cancellables)

        _ = player   // starts the now-playing helper when enabled
        _ = lyrics
        _ = calls   // starts the microphone watcher when calls are enabled
        _ = hub     // AirPods, Universal Clipboard, AirDrop, Focus, hotspot, calendar, iPhone bridge
        setupLauncher()
        source.onEvent = { [weak self] event in self?.store.handle(event) }
        source.start()

        // Hidden flags for checking the UI without real notifications.
        let args = CommandLine.arguments
        if args.contains("--demo") {
            for i in 0..<3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i) * 0.3) { [weak self] in
                    self?.store.injectTest(index: i)
                }
            }
        }
        // `--demo-label=Some Name`: one test notification with exactly that label (layout checks).
        if let arg = args.first(where: { $0.hasPrefix("--demo-label=") }) {
            let label = String(arg.dropFirst("--demo-label=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.store.injectTest(label: label)
            }
        }
        // `--test-preset=whatsapp|longMessage|mail|calendar|longSender|burst`, `--test-system`:
        // the same actions as Settings › Test notifications (for scripted checks).
        if let arg = args.first(where: { $0.hasPrefix("--test-preset=") }) {
            let name = String(arg.dropFirst("--test-preset=".count))
            let delay = args.first(where: { $0.hasPrefix("--test-delay=") })
                .flatMap { Double($0.dropFirst("--test-delay=".count)) } ?? 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                if name == "burst" {
                    for (i, p) in [TestPreset.whatsapp, .mail, .calendar].enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.25) { self.store.injectTest(p.make()) }
                    }
                } else if let p = TestPreset(rawValue: name) {
                    self.store.injectTest(p.make())
                }
            }
        }
        // `--dump-records`: write the decoded plist structure of recent chat/mail rows to
        // ~/Library/Application Support/Notch/record-dump.txt (local only, for deep-link research).
        if args.contains("--dump-records") {
            DispatchQueue.global().async { RecordDumper.dump() }
        }
        // `--open-latest=<bundle id>`: run the double-click opener on the newest real notification
        // from that app (after the DB history has loaded). Logs what it chose to debug.log.
        if let arg = args.first(where: { $0.hasPrefix("--open-latest=") }) {
            let bundle = String(arg.dropFirst("--open-latest=".count)).lowercased()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                guard let n = self.store.history.first(where: { $0.bundleID.lowercased() == bundle && !$0.isTest && ($0.chatJID != nil || $0.defaultURL != nil) }) else {
                    DebugLog.write("open-latest: no \(bundle) notification in history"); return
                }
                DebugLog.write("open-latest: \(bundle) rec=\(n.recID ?? -1) durl=\(n.defaultURL != nil) jid=\(n.chatJID?.split(separator: "@").last ?? "-") phone=\(n.senderPhone != nil)")
                NotificationOpener.open(n)
            }
        }
        if args.contains("--test-system") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.testNotifier.send() }
        }
        if args.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.settingsWindow.show() }
        }
        if let demo = args.first(where: { $0.hasPrefix("--demo-music") }) {
            let kind = demo.split(separator: "=").dropFirst().first.map(String.init) ?? "spotify"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.player.debugDemo(kind) }
        }
        if args.contains("--media-selftest") { runMediaSelfTest() }
        // `--demo-call[=zoom|facetime|meet]`, `--demo-charge`, `--demo-lowbattery`: activity UI checks.
        if let demo = args.first(where: { $0.hasPrefix("--demo-call") }) {
            let kind = demo.split(separator: "=").dropFirst().first.map(String.init) ?? "zoom"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.calls.debugDemo(kind) }
        }
        if args.contains("--demo-charge") || args.contains("--demo-lowbattery") {
            let low = args.contains("--demo-lowbattery")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.power.debugDemo(low: low) }
        }
        // `--demo-moment=audio|clipboard|airdrop|focus|hotspot|calendar|iphone|event`: device moment UI checks.
        if let demo = args.first(where: { $0.hasPrefix("--demo-moment") }) {
            let kind = demo.split(separator: "=").dropFirst().first.map(String.init) ?? "audio"
            let delay = args.first(where: { $0.hasPrefix("--demo-delay=") })
                .flatMap { Double($0.dropFirst("--demo-delay=".count)) } ?? 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.hub.debugDemo(kind) }
        }
        // `--demo-drop`: show the AirDrop drop zone as if files were dragged onto the notch.
        if args.contains("--demo-drop") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let vm = self?.controllers.values.first?.viewModel else { return }
                vm.setDraggingFiles(true)
                vm.debugPinHover = true
                vm.setHovering(true)
            }
        }
        if args.contains("--peek") {
            // `--peek-delay=<s>`: pin the hover later (e.g. after a demo call or the track auto-peek).
            let peekDelay = args.first(where: { $0.hasPrefix("--peek-delay=") })
                .flatMap { Double($0.dropFirst("--peek-delay=".count)) } ?? 2.0
            DispatchQueue.main.asyncAfter(deadline: .now() + peekDelay) { [weak self] in
                guard let vm = self?.controllers.values.first?.viewModel else { return }
                vm.debugPinHover = true
                vm.setHovering(true)
            }
        }
        // `--launcher[=root|clipboard|emoji|snippets|kaomoji|files|running|windows]` (+ `--launcher-query=…`):
        // open the launcher on start (UI checks).
        if let arg = args.first(where: { $0.hasPrefix("--launcher") && !$0.hasPrefix("--launcher-query") }) {
            let name = arg.split(separator: "=").dropFirst().first.map(String.init) ?? "root"
            let mode: LauncherMode = switch name {
            case "clipboard": .clipboard
            case "emoji": .emoji
            case "snippets": .snippets
            case "kaomoji": .kaomoji
            case "files": .files
            case "running": .running
            case "windows": .windows
            default: .root
            }
            let q = args.first(where: { $0.hasPrefix("--launcher-query=") }).map { String($0.dropFirst("--launcher-query=".count)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.launcher.controller.show(mode)
                if let q { self.launcher.controller.model.query = q }
                if args.contains("--snapshot") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.launcher.controller.snapshot(name + (q.map { "-" + $0.replacingOccurrences(of: " ", with: "_") } ?? ""))
                    }
                }
            }
        }
        // `--demo-timer[=seconds]`: start a countdown (timer wings / hover card checks).
        if let arg = args.first(where: { $0.hasPrefix("--demo-timer") }) {
            let secs = arg.split(separator: "=").dropFirst().first.flatMap { Double($0) } ?? 300
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.launcher.timers.startCountdown(secs) }
        }
        if args.contains("--expand") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.showHistory() }
        }
        // `--expand-tab=home|devices|notifications`: open the expanded panel on that page.
        if let arg = args.first(where: { $0.hasPrefix("--expand-tab=") }) {
            let tab: NotchViewModel.ExpandedTab = switch String(arg.dropFirst("--expand-tab=".count)) {
            case "devices": .devices
            case "shelf": .shelf
            case "notifications": .notifications
            default: .home
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let vm = self?.controllers.values.first?.viewModel else { return }
                vm.debugPinHover = true
                vm.expand(tab: tab)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        launcher.expander.stop()
        launcher.timers.decaffeinate()
        source.stop()
        calls.restoreMute()
    }

    /// Debug: drives the real command path (play/pause, next, previous) and logs whether the
    /// player's state actually changed each time. Leaves playback paused at the end.
    private func runMediaSelfTest() {
        let steps: [(MediaCommand, Double)] = [(.togglePlayPause, 4), (.togglePlayPause, 4), (.next, 5), (.previous, 5), (.pause, 3)]
        func describe() -> String {
            guard let i = player.info else { return "nothing playing" }
            return "\(i.isPlaying ? "playing" : "paused") '\(i.title)' source=\(player.source.map { "\($0)" } ?? "?")"
        }
        var delay = 3.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { DebugLog.write("selftest start: \(describe())") }
        for (cmd, wait) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                DebugLog.write("selftest send \(cmd) (before: \(describe()))")
                self?.player.send(cmd)
            }
            delay += wait
            DispatchQueue.main.asyncAfter(deadline: .now() + delay - 0.1) { DebugLog.write("selftest after \(cmd): \(describe())") }
        }
    }

    // MARK: - Windows per screen

    private func targetScreens() -> [NSScreen] {
        if settings.showOnExternalDisplays { return NSScreen.screens }
        if let builtIn = NSScreen.screens.first(where: { $0.isBuiltIn }) { return [builtIn] }
        return [NSScreen.main ?? NSScreen.screens.first].compactMap { $0 }
    }

    private func rebuildWindows() {
        var keep: [CGDirectDisplayID: NotchWindowController] = [:]
        for screen in targetScreens() {
            guard let id = screen.displayID else { continue }
            if let existing = controllers.removeValue(forKey: id) {
                existing.update(screen: screen)
                keep[id] = existing
            } else {
                let c = NotchWindowController(screen: screen, store: store, settings: settings, player: player,
                                              lyrics: lyrics, calls: calls, power: power, hub: hub, launcher: launcher)
                c.viewModel.openSettings = { [weak self] in self?.settingsWindow.show() }
                c.viewModel.openFullDiskAccess = { [weak self] in self?.openFullDiskAccess() }
                keep[id] = c
            }
        }
        controllers.values.forEach { $0.close() }
        controllers = keep
    }

    // MARK: - Status / onboarding

    private func statusChanged(_ status: SourceStatus) {
        DebugLog.write("notification source: \(status.label) (\(Bundle.main.bundlePath))")
        switch status {
        case .permissionDenied:
            if !onboardingShown {
                onboardingShown = true
                onboarding.show()
            }
        case .running:
            if onboardingShown {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.onboarding.hide() }
            }
        default:
            break
        }
        statusItem?.button?.image = NSImage(
            systemSymbolName: status.needsFullDiskAccess ? "bell.slash" : "bell.badge",
            accessibilityDescription: "Notch")
    }

    private func openFullDiskAccess() {
        NSWorkspace.shared.open(Self.fullDiskAccessURL)
        source.retryNow()
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func setupLauncher() {
        launcher.openSettingsHandler = { [weak self] page in
            self?.settingsWindow.show(tab: page == .general ? "general" : page == .shortcuts ? "shortcuts" : "launcher")
        }
        launcher.showShelfHandler = { [weak self] in self?.mainViewModel?.expand(tab: .shelf) }
        launcher.showNotificationsHandler = { [weak self] in self?.showHistory() }
    }

    /// The notch on the main target screen (built-in display first).
    private var mainViewModel: NotchViewModel? {
        let c = targetScreens().first.flatMap { $0.displayID }.flatMap { controllers[$0] } ?? controllers.values.first
        return c?.viewModel
    }

    private func showHistory() {
        let c = targetScreens().first.flatMap { $0.displayID }.flatMap { controllers[$0] } ?? controllers.values.first
        c?.viewModel.showExpanded()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "Notch")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: store.status.label, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if store.status.needsFullDiskAccess {
            menu.addItem(withTitle: "Grant Full Disk Access…", action: #selector(menuGrantAccess), keyEquivalent: "")
                .target = self
            menu.addItem(withTitle: "Relaunch Notch", action: #selector(menuRelaunch), keyEquivalent: "")
                .target = self
        }
        menu.addItem(.separator())
        let open = menu.addItem(withTitle: "Open Launcher", action: #selector(menuLauncher), keyEquivalent: "")
        open.target = self
        if let k = launcher.settings.launcherHotKey { open.title += "    \(k.display)" }
        let clip = menu.addItem(withTitle: "Clipboard History", action: #selector(menuClipboard), keyEquivalent: "")
        clip.target = self
        if let k = launcher.settings.clipboardHotKey { clip.title += "    \(k.display)" }
        menu.addItem(withTitle: "Emoji & Symbols", action: #selector(menuEmoji), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Shelf", action: #selector(menuShelf), keyEquivalent: "").target = self
        if let t = launcher.timers.timer {
            menu.addItem(withTitle: "Stop \(t.name) (\(t.display()))", action: #selector(menuStopTimer), keyEquivalent: "").target = self
        }
        if launcher.timers.isCaffeinated {
            menu.addItem(withTitle: "Turn Off Caffeinate", action: #selector(menuDecaf), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Notifications", action: #selector(menuShowHistory), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Send Test Notification", action: #selector(menuTest), keyEquivalent: "t").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func menuGrantAccess() { onboarding.show(); openFullDiskAccess() }
    @objc private func menuRelaunch() { relaunch() }
    @objc private func menuShowHistory() { showHistory() }
    @objc private func menuTest() { store.injectTest() }
    @objc private func menuSettings() { settingsWindow.show() }
    // Menus close before the launcher opens, so the previously active app is still frontmost.
    @objc private func menuLauncher() { DispatchQueue.main.async { self.launcher.controller.show(.root) } }
    @objc private func menuClipboard() { DispatchQueue.main.async { self.launcher.controller.show(.clipboard) } }
    @objc private func menuEmoji() { DispatchQueue.main.async { self.launcher.controller.show(.emoji) } }
    @objc private func menuShelf() { mainViewModel?.expand(tab: .shelf) }
    @objc private func menuStopTimer() { launcher.timers.stop() }
    @objc private func menuDecaf() { launcher.timers.decaffeinate() }
}
