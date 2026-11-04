import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = SettingsStore()
    private lazy var store = NotificationStore(settings: settings)
    private let source = DBNotificationSource()
    private var controllers: [CGDirectDisplayID: NotchWindowController] = [:]
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var onboardingShown = false

    private lazy var settingsWindow = SettingsWindowController { [unowned self] in
        SettingsView(settings: self.settings, store: self.store,
                     sendTest: { [unowned self] in self.store.injectTest() },
                     openFullDiskAccess: { [unowned self] in self.openFullDiskAccess() })
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
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
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

        source.onEvent = { [weak self] event in self?.store.handle(event) }
        source.start()

        // Hidden flags for checking the UI without real notifications.
        let args = CommandLine.arguments
        if args.contains("--demo") {
            for i in 0..<3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i) * 0.3) { [weak self] in
                    self?.store.injectTest()
                }
            }
        }
        if args.contains("--peek") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let vm = self?.controllers.values.first?.viewModel else { return }
                vm.debugPinHover = true
                vm.setHovering(true)
            }
        }
        if args.contains("--expand") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.showHistory() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        source.stop()
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
                let c = NotchWindowController(screen: screen, store: store, settings: settings)
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
}
