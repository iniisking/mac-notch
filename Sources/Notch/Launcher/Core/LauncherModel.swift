import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

enum LauncherMode: Equatable {
    case root, clipboard, emoji, kaomoji, snippets, files, running, shortcuts, windows

    enum Layout { case list, listWithPreview, grid }

    var layout: Layout {
        switch self {
        case .clipboard, .snippets: return .listWithPreview
        case .emoji: return .grid
        default: return .list
        }
    }

    var title: String {
        switch self {
        case .root: return "Notch"
        case .clipboard: return "Clipboard History"
        case .emoji: return "Emoji & Symbols"
        case .kaomoji: return "Kaomoji"
        case .snippets: return "Snippets"
        case .files: return "Files"
        case .running: return "Quit Applications"
        case .shortcuts: return "Shortcuts"
        case .windows: return "Window Management"
        }
    }

    var placeholder: String {
        switch self {
        case .root: return "Search apps, commands, files, or calculate…"
        case .clipboard: return "Search clipboard history…"
        case .emoji: return "Search emoji and symbols…"
        case .kaomoji: return "Search kaomoji…"
        case .snippets: return "Search snippets…"
        case .files: return "Search files by name…"
        case .running: return "Search running apps…"
        case .shortcuts: return "Search Shortcuts…"
        case .windows: return "Search window layouts…"
        }
    }

    var symbol: String {
        switch self {
        case .root: return "magnifyingglass"
        case .clipboard: return "doc.on.clipboard"
        case .emoji: return "face.smiling"
        case .kaomoji: return "face.smiling.inverse"
        case .snippets: return "text.quote"
        case .files: return "doc.text.magnifyingglass"
        case .running: return "xmark.app"
        case .shortcuts: return "square.2.layers.3d"
        case .windows: return "macwindow"
        }
    }
}

enum ClipFilter: String, CaseIterable {
    case all = "All", text = "Text", images = "Images", files = "Files", links = "Links", colors = "Colors"

    func matches(_ e: ClipEntry) -> Bool {
        switch self {
        case .all: return true
        case .text: return e.kind == .text
        case .images: return e.kind == .image
        case .files: return e.kind == .files
        case .links: return e.kind == .link
        case .colors: return e.kind == .color
        }
    }
}

/// State of the launcher panel: mode stack, query, results, selection, keyboard handling.
@MainActor
final class LauncherModel: ObservableObject {
    let services: LauncherServices
    @Published private(set) var mode: LauncherMode = .root
    @Published var query = "" { didSet { if query != oldValue { queryChanged() } } }
    @Published private(set) var items: [LauncherItem] = []
    @Published var selection = 0 { didSet { if selection != oldValue { confirmID = nil } } }
    @Published private(set) var emojiSections: [EmojiStore.Section] = []
    @Published private(set) var emojiCells: [EmojiStore.GridCell] = []
    @Published var showActions = false
    @Published var actionSelection = 0
    @Published private(set) var confirmID: String?
    @Published private(set) var confirmMessage: String?
    @Published var clipFilter: ClipFilter = .all
    /// Assigning a hotkey or alias to an item from inside the launcher (⌘K › Set Hotkey / Set Alias).
    enum Editing { case hotkey(LauncherItem), alias(LauncherItem, savedQuery: String) }
    @Published private(set) var editing: Editing?
    @Published var isOpen = false
    @Published var geometry: NotchGeometry?
    private var stack: [LauncherMode] = []
    private(set) var lastKeyboardNav = Date.distantPast
    var hideHandler: () -> Void = {}
    private var cancellables = Set<AnyCancellable>()

    static let emojiColumns = 13
    static let size = CGSize(width: 720, height: 440)

    init(services: LauncherServices) {
        self.services = services
        services.files.$results
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isOpen, [.root, .files].contains(self.mode) else { return }
                self.refresh(keepSelection: true)
            }
            .store(in: &cancellables)
        services.clipboard.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isOpen, self.mode == .clipboard else { return }
                DispatchQueue.main.async { self.refresh(keepSelection: true) }
            }
            .store(in: &cancellables)
        services.$shortcuts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isOpen, [.root, .shortcuts].contains(self.mode) else { return }
                DispatchQueue.main.async { self.refresh(keepSelection: true) }
            }
            .store(in: &cancellables)
        services.calculator.currency.onUpdate = { [weak self] in
            guard let self, self.isOpen, self.mode == .root else { return }
            self.refresh(keepSelection: true)
        }
    }

    var selectedItem: LauncherItem? { items.indices.contains(selection) ? items[selection] : nil }
    var selectedCell: EmojiStore.GridCell? { emojiCells.indices.contains(selection) ? emojiCells[selection] : nil }

    // MARK: - Opening / modes

    func prepare(_ mode: LauncherMode) {
        stack = mode == .root ? [] : [.root]
        self.mode = mode
        showActions = false
        confirmID = nil
        clipFilter = .all
        if query.isEmpty { refresh() } else { query = "" }
        services.apps.refreshIfNeeded()
        services.refreshShortcuts()
        services.shelf.prune()
    }

    func push(_ m: LauncherMode) {
        stack.append(mode)
        mode = m
        showActions = false
        clipFilter = .all
        if query.isEmpty { refresh() } else { query = "" }
    }

    func pop() {
        guard let prev = stack.popLast() else { hide(); return }
        mode = prev
        showActions = false
        if query.isEmpty { refresh() } else { query = "" }
    }

    func setQuery(_ q: String) {
        query = q
    }

    func hide(toast: String? = nil) {
        if editing != nil { endEditing() }
        showActions = false
        hideHandler()
        if let toast {
            services.emit(Moment(kind: .launcher, left: .symbol("checkmark.circle.fill", ContinuityColors.green), right: .none,
                                 title: toast, detail: "", duration: 1.8))
        }
    }

    /// For destructive commands: the first ↩ arms it, the second runs it.
    func confirmPending(_ id: String, message: String) -> Bool {
        if confirmID == id {
            confirmID = nil
            confirmMessage = nil
            return true
        }
        confirmID = id
        confirmMessage = message
        return false
    }

    // MARK: - Paste helpers

    func paste(text: String, cursorBack: Int = 0) {
        services.clipboard.noteOwnWrite()
        hide()
        let ok = PasteBack.paste(cursorOffset: cursorBack) { $0.setString(text, forType: .string) }
        if !ok { pasteFallbackToast() }
    }

    func paste(entry: ClipEntry, plain: Bool = false) {
        services.clipboard.markUsed(entry.id)
        hide()
        let ok = PasteBack.paste { services.clipboard.write(entry, plain: plain, to: $0) }
        if !ok { pasteFallbackToast() }
    }

    private func pasteFallbackToast() {
        services.emit(Moment(kind: .launcher, left: .symbol("doc.on.clipboard", .white), right: .symbol("lock.fill", ContinuityColors.orange),
                             title: "Copied", detail: "Allow Notch in Accessibility to paste directly", duration: 4,
                             action: .run { Keystrokes.openAccessibilitySettings() }, actionHint: "Click to open Accessibility settings"))
    }

    func quickLook(_ url: URL) {
        hide()
        QuickLookSource.shared.show([url])
    }

    // MARK: - Results

    private func queryChanged() {
        if case .alias = editing { return }   // typing the alias, not searching
        confirmID = nil
        confirmMessage = nil
        showActions = false
        refresh()
    }

    func refresh(keepSelection: Bool = false) {
        let previousID = keepSelection ? (mode == .emoji ? selectedCell?.id : selectedItem?.id) : nil
        let q = query.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .root: items = rootItems(q)
        case .clipboard: items = clipboardItems(q)
        case .emoji:
            emojiSections = services.emoji.sections(query: q, tone: services.settings.emojiSkinTone)
            emojiCells = emojiSections.flatMap(\.items)
            items = []
        case .kaomoji: items = kaomojiItems(q)
        case .snippets: items = snippetItems(q)
        case .files:
            services.files.search(q)
            items = services.files.results.map { FileSearch.item(for: $0, query: q) }
        case .running: items = AppIndex.runningItems(query: q)
        case .shortcuts: items = services.shortcutItems(query: q)
        case .windows: items = WindowManager.items(query: q).map { var i = $0; i.score = 1; return i }
        }
        decorate()
        if let previousID {
            let idx = mode == .emoji ? emojiCells.firstIndex { $0.id == previousID } : items.firstIndex { $0.id == previousID }
            selection = idx ?? min(selection, max(0, count - 1))
        } else {
            selection = 0
        }
    }

    /// Number of selectable things in the current mode.
    var count: Int { mode == .emoji ? emojiCells.count : items.count }

    private func rootItems(_ q: String) -> [LauncherItem] {
        let s = services
        if q.isEmpty {
            // Recently used things, then the main commands.
            var pool = s.apps.items(query: "") + SystemCommands.items(s, query: "") + s.quicklinks.items(query: "")
                + s.snippets.items(query: "") + s.shortcutItems(query: "")
            pool = pool.filter { Frecency.shared.bonus($0.learnKey ?? "") > 0 }
            pool.sort { Frecency.shared.bonus($0.learnKey ?? "") > Frecency.shared.bonus($1.learnKey ?? "") }
            var out = pool.prefix(8).map { item -> LauncherItem in
                var i = item
                i.section = "Recent"
                return i
            }
            let seen = Set(out.map(\.id))
            let featured = ["cmd:mode.clipboard", "cmd:mode.emoji", "cmd:mode.snippets", "cmd:mode.files", "cmd:notch.shelf",
                            "cmd:util.ocr", "cmd:util.colorpicker", "cmd:timer.pomodoro", "cmd:mode.windows", "cmd:caffeinate.on",
                            "cmd:caffeinate.off", "cmd:timer.stop", "cmd:mode.kaomoji", "cmd:mode.running"]
            let cmds = SystemCommands.items(s, query: "")
            for id in featured where !seen.contains(id) {
                if var c = cmds.first(where: { $0.id == id }) {
                    c.section = "Commands"
                    out.append(c)
                }
            }
            return out
        }

        var all: [LauncherItem] = []
        if let a = s.calculator.answer(q) { all.append(s.calculator.item(for: a, query: q)) }
        all += s.capture.items(query: q) { [weak s] in s?.emit($0) }
        all += timerItems(q)
        all += s.quicklinks.items(query: q)
        all += s.apps.items(query: q)
        all += SystemCommands.items(s, query: q)
        all += s.snippets.items(query: q).map { var i = $0; i.score *= 0.8; return i }
        all += s.shortcutItems(query: q)
        all += WindowManager.items(query: q)
        // Weak fuzzy matches are noise once there are good ones.
        // Aliases: an exact alias wins outright, a partial one ranks high.
        let lowerQ = q.lowercased()
        let aliasIDs = s.settings.aliases.filter { $0.value.hasPrefix(lowerQ) }
        if !aliasIDs.isEmpty {
            let catalog = s.catalog()
            for (id, alias) in aliasIDs {
                guard var item = catalog.first(where: { $0.id == id }) else { continue }
                all.removeAll { $0.id == id }
                item.score = 100
                item.boost = alias == lowerQ ? 250 : 60
                all.append(item)
            }
        }
        let best = all.map(\.score).max() ?? 0
        all = all.filter { $0.boost > 0 || $0.score >= min(30, best * 0.4) }
        for i in all.indices {
            all[i].score += all[i].boost + Frecency.shared.bonus(all[i].learnKey ?? "")
        }
        var sections = grouped(all, limits: ["Applications": 8, "Commands": 8, "Snippets": 4, "Shortcuts": 4,
                                             "Window Management": 4, "Quicklinks": 4, "Running Applications": 4])
        if s.settings.searchFiles, q.count >= 3 {
            s.files.search(q)
            sections += s.files.results.prefix(6).map { FileSearch.item(for: $0, query: q) }
        } else {
            s.files.search("")
        }
        if s.settings.webFallback { sections += s.quicklinks.fallbacks(query: q) }
        return sections
    }

    /// Sections ordered by their best item; items by score; each section capped.
    private func grouped(_ items: [LauncherItem], limits: [String: Int]) -> [LauncherItem] {
        var bySection: [String: [LauncherItem]] = [:]
        for i in items { bySection[i.section, default: []].append(i) }
        let ordered = bySection.map { (key: $0.key, items: $0.value.sorted { $0.score > $1.score }) }
            .sorted { ($0.items.first?.score ?? 0) > ($1.items.first?.score ?? 0) }
        return ordered.flatMap { Array($0.items.prefix(limits[$0.key] ?? 6)) }
    }

    private func timerItems(_ q: String) -> [LauncherItem] {
        let lower = q.lowercased()
        var arg: String?
        for p in ["timer ", "countdown ", "t "] where lower.hasPrefix(p) { arg = String(lower.dropFirst(p.count)) }
        if arg == nil, lower.hasSuffix(" timer") { arg = String(lower.dropLast(6)) }
        guard let a = arg, let secs = TimerService.parseDuration(a) else { return [] }
        let svc = services.timers
        return [LauncherItem(
            id: "timer:start", title: "Start \(secs.hm) timer", subtitle: "Counts down in the notch",
            icon: .symbol("timer", LauncherColors.orange), accessory: "Timer", section: "Timer",
            actions: [LauncherAction(title: "Start Timer", symbol: "play.fill") { m in svc.startCountdown(secs); m.hide() }],
            boost: 170, score: 100)]
    }

    private func clipboardItems(_ q: String) -> [LauncherItem] {
        let clip = services.clipboard
        let pasteFirst = services.settings.pasteOnEnter
        return clip.entries.compactMap { e -> LauncherItem? in
            guard clipFilter.matches(e) else { return nil }
            if !q.isEmpty {
                let hay = (e.text ?? "") + " " + (e.files ?? []).joined(separator: " ")
                guard hay.localizedCaseInsensitiveContains(q) || FuzzyMatch.score(q, e.title) >= 45 else { return nil }
            }
            let icon: LauncherIcon
            let preview: LauncherPreview
            switch e.kind {
            case .image:
                let img = clip.image(for: e)
                icon = img.map { .image($0) } ?? .symbol("photo", LauncherColors.purple)
                preview = img.map { .image($0) } ?? .text("Image unavailable")
            case .files:
                let urls = (e.files ?? []).map { URL(fileURLWithPath: $0) }
                icon = urls.first.map { .file($0) } ?? .symbol("doc", LauncherColors.blue)
                preview = .files(urls)
            case .color:
                let c = ColorParser.parse(e.text ?? "") ?? .white
                icon = .color(c)
                preview = .color(c, e.text ?? "")
            case .link:
                icon = .symbol("link", LauncherColors.blue)
                preview = .text(e.text ?? "")
            case .text:
                icon = e.app.map { .bundle($0) } ?? .symbol("text.alignleft", LauncherColors.gray)
                preview = .text(e.text ?? "", monospaced: Self.looksLikeCode(e.text ?? ""))
            }
            var actions: [LauncherAction] = []
            let paste = LauncherAction(title: "Paste", symbol: "doc.on.clipboard", shortcut: pasteFirst ? nil : "⌘↩") { m in m.paste(entry: e) }
            let copy = LauncherAction(title: "Copy to Clipboard", symbol: "doc.on.doc", shortcut: pasteFirst ? "⌘↩" : nil) { m in
                clip.markUsed(e.id)
                PasteBack.copy { clip.write(e, to: $0) }
                m.hide(toast: "Copied")
            }
            actions += pasteFirst ? [paste, copy] : [copy, paste]
            if e.kind != .image {
                actions.append(LauncherAction(title: "Paste as Plain Text", symbol: "textformat", shortcut: "⇧↩") { m in m.paste(entry: e, plain: true) })
            }
            if e.kind == .link, let u = e.text.flatMap(URL.init(string:)) {
                actions.append(LauncherAction(title: "Open Link", symbol: "safari", shortcut: "⌘O") { m in NSWorkspace.shared.open(u); m.hide() })
            }
            if e.kind == .files {
                let urls = (e.files ?? []).map { URL(fileURLWithPath: $0) }
                actions.append(LauncherAction(title: "Show in Finder", symbol: "folder", shortcut: "⌘O") { m in
                    NSWorkspace.shared.activateFileViewerSelecting(urls); m.hide()
                })
                actions.append(LauncherAction(title: "Add to Shelf", symbol: "tray.and.arrow.down") { m in
                    m.services.shelf.add(urls); m.hide(toast: "Added to Shelf")
                })
            }
            if e.kind == .image, let f = e.imageFile {
                let url = ClipboardHistory.imagesDir.appendingPathComponent(f)
                actions.append(LauncherAction(title: "Quick Look", symbol: "eye", shortcut: "⌘Y") { m in m.quickLook(url) })
                actions.append(LauncherAction(title: "Save to Downloads", symbol: "square.and.arrow.down") { m in
                    let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Clipboard \(Int(Date().timeIntervalSince1970)).png")
                    try? FileManager.default.copyItem(at: url, to: dest)
                    NSWorkspace.shared.activateFileViewerSelecting([dest]); m.hide()
                })
            }
            if e.kind == .color, let c = ColorParser.parse(e.text ?? "") {
                for (label, value) in [("Hex", ColorParser.hex(c)), ("RGB", ColorParser.rgb(c)), ("HSL", ColorParser.hsl(c))] {
                    actions.append(LauncherAction(title: "Copy as \(label)", symbol: "paintpalette") { m in
                        PasteBack.copy(text: value); m.hide(toast: "Copied \(value)")
                    })
                }
            }
            actions.append(LauncherAction(title: e.pinned ? "Unpin" : "Pin", symbol: e.pinned ? "pin.slash" : "pin", shortcut: "⌘P") { m in
                clip.togglePin(e.id); m.refresh(keepSelection: true)
            })
            actions.append(LauncherAction(title: "Delete", symbol: "trash", shortcut: "⌘⌫", destructive: true) { m in
                clip.delete(e.id); m.refresh(keepSelection: false)
            })
            actions.append(LauncherAction(title: "Clear All History…", symbol: "trash.slash", destructive: true) { m in
                if m.confirmPending("clip.clear", message: "Press ↩ again to delete all unpinned history") == false {
                    m.showActions = false
                    return
                }
                clip.clear(); m.refresh()
            })
            var item = LauncherItem(id: "clip:\(e.id)", title: e.title, subtitle: nil, icon: icon,
                                    accessory: e.date.notchRelative, section: e.pinned ? "Pinned" : "Recent",
                                    actions: actions, preview: preview)
            item.keywords = [e.app ?? ""]
            return item
        }
        .sorted { ($0.section == "Pinned" ? 0 : 1) < ($1.section == "Pinned" ? 0 : 1) }
    }

    static func looksLikeCode(_ s: String) -> Bool {
        let markers = ["{", "}", ";", "=>", "func ", "def ", "const ", "import ", "</", "$ "]
        return s.contains("\n") && markers.filter { s.contains($0) }.count >= 2
    }

    private func kaomojiItems(_ q: String) -> [LauncherItem] {
        EmojiStore.kaomoji.compactMap { face, name in
            let s = FuzzyMatch.score(q, name)
            guard s > 0 else { return nil }
            var item = LauncherItem(
                id: "kaomoji:\(face)", title: face, subtitle: name, icon: .symbol("face.smiling", LauncherColors.pink),
                section: "Kaomoji",
                actions: [
                    LauncherAction(title: "Paste", symbol: "doc.on.clipboard") { m in m.paste(text: face) },
                    LauncherAction(title: "Copy", symbol: "doc.on.doc", shortcut: "⌘↩") { m in
                        PasteBack.copy(text: face); m.hide(toast: "Copied \(face)")
                    },
                ],
                learnKey: "kaomoji:\(face)")
            item.score = s + Frecency.shared.bonus("kaomoji:\(face)")
            return item
        }
        .sorted { q.isEmpty ? Frecency.shared.bonus($0.learnKey!) > Frecency.shared.bonus($1.learnKey!) : $0.score > $1.score }
    }

    private func snippetItems(_ q: String) -> [LauncherItem] {
        var out = services.snippets.items(query: q).sorted { $0.score > $1.score }
        out.append(LauncherItem(
            id: "snippet:new", title: "Create Snippet…", subtitle: "Opens Settings › Snippets",
            icon: .symbol("plus", LauncherColors.gray), section: "Manage",
            actions: [LauncherAction(title: "Create Snippet", symbol: "plus") { m in m.hide(); m.services.openSettings(.snippets) }],
            preview: .text("Snippets support placeholders:\n\n{date}  {time}  {datetime}  {isodate}  {day}\n{clipboard}  {uuid}\n{cursor} — where the caret ends up")))
        return out
    }

    /// Shows each item's own hotkey and alias in its row.
    private func decorate() {
        let hk = services.settings.commandHotKeys, al = services.settings.aliases
        guard !hk.isEmpty || !al.isEmpty else { return }
        for i in items.indices {
            items[i].hotkey = hk[items[i].id]?.display
            items[i].alias = al[items[i].id]
        }
    }

    /// The item's actions plus Set Hotkey / Set Alias for anything that can carry them.
    func allActions(for item: LauncherItem) -> [LauncherAction] {
        guard LauncherServices.isAssignable(item.id) else { return item.actions }
        let id = item.id
        let current = services.settings.commandHotKeys[id]
        var extra = [
            LauncherAction(title: current == nil ? "Set Hotkey…" : "Change Hotkey (\(current!.display))…", symbol: "keyboard",
                           shortcut: "⇧⌘K") { m in m.beginEditing(.hotkey(item)) },
            LauncherAction(title: services.settings.aliases[id] == nil ? "Set Alias…" : "Change Alias (\(services.settings.aliases[id]!))…",
                           symbol: "character.cursor.ibeam", shortcut: "⇧⌘A") { m in m.beginEditing(.alias(item, savedQuery: m.query)) },
        ]
        if current != nil {
            extra.append(LauncherAction(title: "Remove Hotkey", symbol: "keyboard.badge.ellipsis", destructive: true) { m in
                m.services.settings.setHotKey(nil, for: id); m.refresh(keepSelection: true)
            })
        }
        return item.actions + extra
    }

    private func beginEditing(_ e: Editing) {
        showActions = false
        editing = e
        switch e {
        case .hotkey: HotKeyCenter.shared.suspend()
        case .alias(let item, _): query = services.settings.aliases[item.id] ?? ""
        }
    }

    func cancelEditing() { if editing != nil { endEditing() } }

    private func endEditing() {
        guard let e = editing else { return }
        editing = nil
        switch e {
        case .hotkey: HotKeyCenter.shared.resume()
        case .alias(_, let saved): query = saved; refresh(keepSelection: true)
        }
    }

    /// Footer prompt while assigning.
    var editingPrompt: String? {
        switch editing {
        case .hotkey(let item): return "Press a shortcut for “\(item.title)” · ⌫ removes · Esc cancels"
        case .alias(let item, _): return "Type an alias for “\(item.title)”, then ↩ (empty removes) · Esc cancels"
        case nil: return nil
        }
    }

    private func handleEditingKey(_ event: NSEvent) -> Bool {
        let code = Int(event.keyCode)
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch editing {
        case .hotkey(let item):
            if code == kVK_Escape, mods.isEmpty { endEditing(); return true }
            if code == kVK_Delete, mods.isEmpty {
                services.settings.setHotKey(nil, for: item.id)
                endEditing(); refresh(keepSelection: true); return true
            }
            let fKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                   kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
            guard !mods.isEmpty || fKeys.contains(code) else { NSSound.beep(); return true }
            // Ignore lone modifier presses (they don't arrive as keyDown anyway).
            services.settings.setHotKey(KeyCombo(keyCode: code, modifiers: mods), for: item.id)
            endEditing()
            refresh(keepSelection: true)
            announceAssigned(item)
            return true
        case .alias(let item, _):
            if code == kVK_Escape { endEditing(); return true }
            if code == kVK_Return || code == kVK_ANSI_KeypadEnter {
                services.settings.setAlias(query, for: item.id)
                endEditing()
                return true
            }
            return false   // typing goes to the field
        case nil:
            return false
        }
    }

    private func announceAssigned(_ item: LauncherItem) {
        guard let combo = services.settings.commandHotKeys[item.id]?.display else { return }
        services.emit(Moment(kind: .launcher, left: .symbol("keyboard", .white), right: .none,
                             title: item.title, detail: "Hotkey \(combo)", duration: 2))
    }

    // MARK: - Running actions

    func run(_ action: LauncherAction, of item: LauncherItem?) {
        if let key = item?.learnKey { Frecency.shared.bump(key) }
        showActions = false
        action.run(self)
    }

    func activateSelection(modifiers: NSEvent.ModifierFlags = []) {
        if mode == .emoji {
            guard let cell = selectedCell else { return }
            Frecency.shared.bump("emoji:\(cell.base)")
            if modifiers.contains(.command) {
                PasteBack.copy(text: cell.glyph)
                hide(toast: "Copied \(cell.glyph)")
            } else {
                paste(text: cell.glyph)
            }
            return
        }
        guard let item = selectedItem, let first = item.actions.first else { return }
        if modifiers.contains(.command), item.actions.count > 1 {
            run(item.actions.first { $0.shortcut == "⌘↩" } ?? item.actions[1], of: item)
        } else {
            run(first, of: item)
        }
    }

    // MARK: - Keyboard

    /// Returns true when the key was handled (the search field doesn't get it).
    func handleKey(_ event: NSEvent) -> Bool {
        let code = Int(event.keyCode)
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let ctrlOnly = mods == .control

        if editing != nil { return handleEditingKey(event) }
        if showActions { return handleActionKey(code, mods: mods, event: event) }

        switch code {
        case kVK_Escape:
            if confirmID != nil { confirmID = nil; confirmMessage = nil }
            else if !query.isEmpty { query = "" }
            else if mode != .root, !stack.isEmpty { pop() }
            else { hide() }
            return true
        case kVK_DownArrow:
            move(mode == .emoji ? Self.emojiColumns : 1, row: mode == .emoji)
            return true
        case kVK_UpArrow:
            move(mode == .emoji ? -Self.emojiColumns : -1, row: mode == .emoji)
            return true
        case kVK_ANSI_N where ctrlOnly:
            move(mode == .emoji ? Self.emojiColumns : 1, row: mode == .emoji); return true
        case kVK_ANSI_P where ctrlOnly:
            move(mode == .emoji ? -Self.emojiColumns : -1, row: mode == .emoji); return true
        case kVK_LeftArrow where mode == .emoji && mods.isEmpty:
            move(-1); return true
        case kVK_RightArrow where mode == .emoji && mods.isEmpty:
            move(1); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let action = shortcutAction(code: code, mods: mods) {
                run(action, of: selectedItem)
            } else {
                activateSelection(modifiers: mods)
            }
            return true
        case kVK_ANSI_K where mods == .command:
            if mode != .emoji, let item = selectedItem, !allActions(for: item).isEmpty {
                showActions = true
                actionSelection = 0
            }
            return true
        case kVK_Tab:
            if mode == .clipboard {
                let all = ClipFilter.allCases
                let i = all.firstIndex(of: clipFilter) ?? 0
                clipFilter = all[(i + (mods.contains(.shift) ? all.count - 1 : 1)) % all.count]
                refresh()
            } else if mode == .emoji {
                services.settings.emojiSkinTone = (services.settings.emojiSkinTone + 1) % 6
                refresh(keepSelection: true)
            } else if let item = selectedItem, item.id.hasPrefix("ql:"),
                      let link = services.quicklinks.links.first(where: { "ql:\($0.id)" == item.id }), link.takesQuery {
                query = "\(link.keyword) "
            }
            return true
        case kVK_Delete where query.isEmpty && mods.isEmpty && mode != .root:
            pop(); return true
        case kVK_ANSI_Comma where mods == .command:
            hide(); services.openSettings(mode == .clipboard ? .clipboard : mode == .snippets ? .snippets : .launcher)
            return true
        case kVK_ANSI_W where mods == .command:
            hide(); return true
        default:
            break
        }
        // Text editing in the search field (an accessory app has no Edit menu to route these).
        if mods == .command || mods == [.command, .shift] {
            let editing: [Int: Selector] = [
                kVK_ANSI_V: #selector(NSText.paste(_:)), kVK_ANSI_C: #selector(NSText.copy(_:)),
                kVK_ANSI_X: #selector(NSText.cut(_:)), kVK_ANSI_A: #selector(NSText.selectAll(_:)),
            ]
            if mods == .command, let sel = editing[code] {
                NSApp.sendAction(sel, to: nil, from: nil)
                return true
            }
            if code == kVK_ANSI_Z {
                let undo = mods.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
                NSApp.sendAction(undo, to: nil, from: nil)
                return true
            }
        }
        // ⌘1…⌘9 pick a row directly.
        if mods == .command, let n = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(n) {
            if n - 1 < count { selection = n - 1; activateSelection() }
            return true
        }
        if !mods.isEmpty, let action = shortcutAction(code: code, mods: mods) {
            run(action, of: selectedItem)
            return true
        }
        return false
    }

    private func shortcutAction(code: Int, mods: NSEvent.ModifierFlags) -> LauncherAction? {
        guard mode != .emoji, let item = selectedItem else { return nil }
        let pressed = KeyCombo(keyCode: code == kVK_ANSI_KeypadEnter ? kVK_Return : code, modifiers: mods).display
        if pressed == "↩" { return nil }
        return allActions(for: item).first { $0.shortcut == pressed }
    }

    private func handleActionKey(_ code: Int, mods: NSEvent.ModifierFlags, event: NSEvent) -> Bool {
        let actions = selectedItem.map { allActions(for: $0) } ?? []
        switch code {
        case kVK_Escape:
            showActions = false
        case kVK_ANSI_K where mods == .command:
            showActions = false
        case kVK_DownArrow:
            actionSelection = min(actions.count - 1, actionSelection + 1)
        case kVK_UpArrow:
            actionSelection = max(0, actionSelection - 1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if actions.indices.contains(actionSelection) { run(actions[actionSelection], of: selectedItem) }
        default:
            if let a = shortcutAction(code: code, mods: mods) { run(a, of: selectedItem) }
        }
        return true
    }

    private func move(_ delta: Int, row: Bool = false) {
        guard count > 0 else { return }
        lastKeyboardNav = Date()
        if mode == .emoji, row {
            selection = emojiRowMove(delta > 0 ? 1 : -1)
            return
        }
        selection = min(max(0, selection + delta), count - 1)
    }

    /// Up/down in the emoji grid, where every section starts on a new row.
    private func emojiRowMove(_ dir: Int) -> Int {
        var rows: [[Int]] = []
        var idx = 0
        for s in emojiSections {
            let n = s.items.count
            var start = 0
            while start < n {
                rows.append(Array((idx + start)..<(idx + min(n, start + Self.emojiColumns))))
                start += Self.emojiColumns
            }
            idx += n
        }
        guard let r = rows.firstIndex(where: { $0.contains(selection) }) else { return 0 }
        let col = rows[r].firstIndex(of: selection) ?? 0
        let target = r + dir
        guard rows.indices.contains(target) else { return selection }
        return rows[target][min(col, rows[target].count - 1)]
    }

    func hover(_ index: Int) {
        guard Date().timeIntervalSince(lastKeyboardNav) > 0.4 else { return }
        selection = index
    }
}
