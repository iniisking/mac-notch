import AppKit
import Combine
import SwiftUI

/// Settings pages the launcher can open.
enum SettingsPage: String {
    case general, launcher, clipboard, snippets, quicklinks, windows, shortcuts
}

/// Owns everything behind the launcher (stores, monitors, hotkeys) and connects it to the rest of Notch.
@MainActor
final class LauncherServices: ObservableObject {
    let settings: LauncherSettings
    let apps = AppIndex()
    let files = FileSearch()
    let calculator = Calculator()
    let clipboard: ClipboardHistory
    let emoji = EmojiStore()
    let snippets = SnippetStore()
    let expander: SnippetExpander
    let quicklinks = QuicklinkStore()
    let timers: TimerService
    let capture: QuickCapture
    let shelf = ShelfStore()
    private let hub: ContinuityHub
    @Published private(set) var shortcuts: [String] = []
    private var shortcutsLoaded = Date.distantPast

    // Hooks into the app (set by AppDelegate).
    var openSettingsHandler: (SettingsPage) -> Void = { _ in }
    var showShelfHandler: () -> Void = {}
    var showNotificationsHandler: () -> Void = {}

    private(set) lazy var controller = LauncherController(services: self)
    private var cancellables = Set<AnyCancellable>()

    init(hub: ContinuityHub) {
        self.hub = hub
        let settings = LauncherSettings()
        self.settings = settings
        clipboard = ClipboardHistory(settings: settings)
        expander = SnippetExpander(store: snippets, clipboard: clipboard)
        timers = TimerService(settings: settings)
        capture = QuickCapture(settings: settings)
        calculator.currency.enabled = settings.currencyRates
        PasteBack.willWrite = { [weak clipboard] in clipboard?.noteOwnWrite() }

        settings.$clipboardHistory.removeDuplicates().sink { [weak self] on in
            on ? self?.clipboard.start() : self?.clipboard.stop()
        }.store(in: &cancellables)
        settings.$snippetExpansion.removeDuplicates().sink { [weak self] on in
            on ? self?.expander.start() : self?.expander.stop()
        }.store(in: &cancellables)
        settings.$currencyRates.sink { [weak self] in self?.calculator.currency.enabled = $0 }.store(in: &cancellables)

        // Hotkeys follow their settings.
        settings.$launcherHotKey.sink { [weak self] c in
            HotKeyCenter.shared.set("launcher", combo: c) { self?.controller.toggle(.root) }
        }.store(in: &cancellables)
        settings.$clipboardHotKey.sink { [weak self] c in
            HotKeyCenter.shared.set("clipboard", combo: c) { self?.controller.toggle(.clipboard) }
        }.store(in: &cancellables)
        settings.$emojiHotKey.sink { [weak self] c in
            HotKeyCenter.shared.set("emoji", combo: c) { self?.controller.toggle(.emoji) }
        }.store(in: &cancellables)
        settings.$snippetsHotKey.sink { [weak self] c in
            HotKeyCenter.shared.set("snippets", combo: c) { self?.controller.toggle(.snippets) }
        }.store(in: &cancellables)
        // Per-command hotkeys (apps, commands, quicklinks, snippets, Shortcuts, window layouts).
        settings.$commandHotKeys.sink { [weak self] map in
            HotKeyCenter.shared.removeAll(prefix: "cmd/")
            for (id, combo) in map {
                HotKeyCenter.shared.set("cmd/\(id)", combo: combo) { self?.runCommand(id) }
            }
        }.store(in: &cancellables)

        // Optional "Copied" moment for local copies.
        clipboard.copied.sink { [weak self] e in
            guard let self, self.settings.clipboardCopyMoment else { return }
            let left: Moment.Glyph = {
                switch e.kind {
                case .image: return self.clipboard.image(for: e).map { .image($0) } ?? .symbol("photo")
                case .color: return .symbol("circle.fill", Color(nsColor: ColorParser.parse(e.text ?? "") ?? .white))
                case .files: return .symbol("doc.on.doc.fill", ContinuityColors.blue)
                case .link: return .symbol("link", ContinuityColors.blue)
                case .text: return .symbol("doc.on.clipboard", .white)
                }
            }()
            self.emit(Moment(kind: .clipboard, left: left, right: .symbol("checkmark", ContinuityColors.green),
                             title: "Copied", detail: e.title, duration: 1.8))
        }.store(in: &cancellables)

        timers.moments.sink { [weak self] in self?.emit($0) }.store(in: &cancellables)
        apps.refreshIfNeeded()
    }

    func emit(_ m: Moment) { hub.moments.send(m) }

    // MARK: - Command catalog (everything that can take a hotkey or alias)

    static let assignablePrefixes = ["app:", "cmd:", "ql:", "snippet:", "shortcut:", "window:"]

    static func isAssignable(_ id: String) -> Bool {
        id != "snippet:new" && assignablePrefixes.contains { id.hasPrefix($0) }
    }

    /// Every command with a stable id, sorted by kind then name.
    func catalog() -> [LauncherItem] {
        apps.refreshIfNeeded()
        refreshShortcuts()
        var all = apps.items(query: "")
        all += SystemCommands.items(self, query: "", everything: true)
        all += quicklinks.items(query: "").filter { !$0.id.hasPrefix("ql-run") }
        all += snippets.items(query: "")
        all += shortcutItems(query: "")
        all += WindowManager.items(query: "")
        return all
    }

    /// A command's hotkey was pressed: run it without opening the launcher, unless it needs it.
    func runCommand(_ id: String) {
        guard let item = catalog().first(where: { $0.id == id }), let action = item.actions.first else {
            DebugLog.write("hotkey: command \(id) not found")
            NSSound.beep()
            return
        }
        Frecency.shared.bump(item.learnKey ?? id)
        let model = controller.model
        guard item.needsPanel else {
            action.run(model)
            return
        }
        // Open the launcher on this item, then run it (switches mode / prefills / arms the confirmation).
        controller.show(.root)
        model.query = item.title
        if let i = model.items.firstIndex(where: { $0.id == id }) { model.selection = i }
        let selected = model.selectedItem?.id == id ? model.selectedItem : item
        (selected?.actions.first ?? action).run(model)
    }

    func openSettings(_ page: SettingsPage) { openSettingsHandler(page) }
    func showShelf() { showShelfHandler() }
    func showNotifications() { showNotificationsHandler() }

    func refreshShortcuts() {
        guard Date().timeIntervalSince(shortcutsLoaded) > 120 else { return }
        shortcutsLoaded = Date()
        QuickActions.listShortcuts { [weak self] in self?.shortcuts = $0 }
    }

    func shortcutItems(query: String, boost: Double = 0) -> [LauncherItem] {
        shortcuts.compactMap { name in
            let s = FuzzyMatch.score(query, name)
            guard s > 0 else { return nil }
            var item = LauncherItem(
                id: "shortcut:\(name)", title: name, subtitle: nil, icon: .bundle("com.apple.shortcuts"),
                accessory: "Shortcut", section: "Shortcuts",
                actions: [
                    LauncherAction(title: "Run Shortcut", symbol: "play.fill") { [weak self] m in
                        m.hide()
                        QuickActions.runShortcut(name) { ok in
                            if !ok {
                                self?.emit(Moment(kind: .launcher, left: .appIcon("com.apple.shortcuts"), right: .symbol("xmark", ContinuityColors.red),
                                                  title: name, detail: "Shortcut failed", duration: 3))
                            }
                        }
                    },
                    LauncherAction(title: "Edit in Shortcuts", symbol: "pencil", shortcut: "⌘↩") { m in
                        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
                        if let u = URL(string: "shortcuts://open-shortcut?name=\(enc)") { NSWorkspace.shared.open(u) }
                        m.hide()
                    },
                ],
                learnKey: "shortcut:\(name)")
            item.score = s * 0.85 + boost
            return item
        }
    }
}
