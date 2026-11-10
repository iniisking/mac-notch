import AppKit
import Carbon.HIToolbox
import Combine

/// Settings for the launcher, clipboard history, emoji, snippets, window layouts and the shelf.
@MainActor
final class LauncherSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    // Hotkeys
    @Published var launcherHotKey: KeyCombo? { didSet { save(launcherHotKey, "hk.launcher") } }
    @Published var clipboardHotKey: KeyCombo? { didSet { save(clipboardHotKey, "hk.clipboard") } }
    @Published var emojiHotKey: KeyCombo? { didSet { save(emojiHotKey, "hk.emoji") } }
    @Published var snippetsHotKey: KeyCombo? { didSet { save(snippetsHotKey, "hk.snippets") } }
    /// "Rectangle-style defaults": turning it on assigns the ⌃⌥ layout shortcuts, off removes them.
    @Published var windowHotKeysEnabled: Bool {
        didSet {
            defaults.set(windowHotKeysEnabled, forKey: "windowHotKeys")
            if windowHotKeysEnabled != oldValue { applyWindowDefaults(windowHotKeysEnabled) }
        }
    }
    /// Global hotkey per command (item id → combo), like Raycast's per-command hotkeys.
    @Published private(set) var commandHotKeys: [String: KeyCombo] {
        didSet { if let d = try? JSONEncoder().encode(commandHotKeys) { defaults.set(d, forKey: "commandHotKeys") } }
    }
    /// Alias per command (item id → text): typing it ranks that command first.
    @Published private(set) var aliases: [String: String] {
        didSet { defaults.set(aliases, forKey: "commandAliases") }
    }

    // Search
    @Published var searchFiles: Bool { didSet { defaults.set(searchFiles, forKey: "launcherSearchFiles") } }
    @Published var webFallback: Bool { didSet { defaults.set(webFallback, forKey: "launcherWebFallback") } }
    /// Currency conversions fetch daily rates from open.er-api.com.
    @Published var currencyRates: Bool { didSet { defaults.set(currencyRates, forKey: "launcherCurrency") } }

    // Clipboard history
    @Published var clipboardHistory: Bool { didSet { defaults.set(clipboardHistory, forKey: "clipHistory") } }
    @Published var clipboardLimit: Int { didSet { defaults.set(clipboardLimit, forKey: "clipLimit") } }
    /// 0 = keep forever.
    @Published var clipboardDays: Int { didSet { defaults.set(clipboardDays, forKey: "clipDays") } }
    @Published var clipboardIgnoredApps: [String] { didSet { defaults.set(clipboardIgnoredApps, forKey: "clipIgnored") } }
    @Published var clipboardCopyMoment: Bool { didSet { defaults.set(clipboardCopyMoment, forKey: "clipCopyMoment") } }
    /// ↩ pastes into the frontmost app (otherwise it only copies).
    @Published var pasteOnEnter: Bool { didSet { defaults.set(pasteOnEnter, forKey: "pasteOnEnter") } }

    // Emoji
    /// 0 = default yellow, 1…5 = light … dark.
    @Published var emojiSkinTone: Int { didSet { defaults.set(emojiSkinTone, forKey: "emojiTone") } }

    // Snippets
    @Published var snippetExpansion: Bool { didSet { defaults.set(snippetExpansion, forKey: "snippetExpansion") } }

    // Shelf
    @Published var shelfEnabled: Bool { didSet { defaults.set(shelfEnabled, forKey: "shelfEnabled") } }

    // Quick capture
    @Published var notesFile: String { didSet { defaults.set(notesFile, forKey: "notesFile") } }

    // Timer
    @Published var timerSound: String { didSet { defaults.set(timerSound, forKey: "timerSound") } }
    @Published var pomodoroWork: Int { didSet { defaults.set(pomodoroWork, forKey: "pomodoroWork") } }
    @Published var pomodoroBreak: Int { didSet { defaults.set(pomodoroBreak, forKey: "pomodoroBreak") } }

    static let defaultIgnoredApps = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.dashlane.dashlanephonefinal",
        "com.lastpass.lastpassmacdesktop", "in.sinew.Enpass-Desktop", "org.keepassxc.keepassxc",
    ]

    init() {
        launcherHotKey = Self.load("hk.launcher", default: KeyCombo(keyCode: kVK_Space, modifiers: .option))
        clipboardHotKey = Self.load("hk.clipboard", default: KeyCombo(keyCode: kVK_ANSI_V, modifiers: [.option, .command]))
        emojiHotKey = Self.load("hk.emoji", default: KeyCombo(keyCode: kVK_ANSI_E, modifiers: [.option, .command]))
        snippetsHotKey = Self.load("hk.snippets", default: nil)
        windowHotKeysEnabled = defaults.bool(forKey: "windowHotKeys")
        commandHotKeys = defaults.data(forKey: "commandHotKeys").flatMap { try? JSONDecoder().decode([String: KeyCombo].self, from: $0) } ?? [:]
        aliases = (defaults.dictionary(forKey: "commandAliases") as? [String: String]) ?? [:]
        searchFiles = defaults.object(forKey: "launcherSearchFiles") as? Bool ?? true
        webFallback = defaults.object(forKey: "launcherWebFallback") as? Bool ?? true
        currencyRates = defaults.object(forKey: "launcherCurrency") as? Bool ?? true
        clipboardHistory = defaults.object(forKey: "clipHistory") as? Bool ?? true
        let limit = defaults.integer(forKey: "clipLimit")
        clipboardLimit = limit > 0 ? limit : 500
        clipboardDays = defaults.object(forKey: "clipDays") as? Int ?? 30
        clipboardIgnoredApps = defaults.stringArray(forKey: "clipIgnored") ?? Self.defaultIgnoredApps
        clipboardCopyMoment = defaults.bool(forKey: "clipCopyMoment")
        pasteOnEnter = defaults.object(forKey: "pasteOnEnter") as? Bool ?? true
        emojiSkinTone = defaults.integer(forKey: "emojiTone")
        snippetExpansion = defaults.bool(forKey: "snippetExpansion")
        shelfEnabled = defaults.object(forKey: "shelfEnabled") as? Bool ?? true
        notesFile = defaults.string(forKey: "notesFile")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Notch Notes.md").path
        timerSound = defaults.string(forKey: "timerSound") ?? "Glass"
        let w = defaults.integer(forKey: "pomodoroWork"), b = defaults.integer(forKey: "pomodoroBreak")
        pomodoroWork = w > 0 ? w : 25
        pomodoroBreak = b > 0 ? b : 5
        // Older versions registered the window defaults directly: carry them over once.
        if windowHotKeysEnabled, !commandHotKeys.keys.contains(where: { $0.hasPrefix("window:") }) {
            applyWindowDefaults(true)
        }
    }

    private func save(_ combo: KeyCombo?, _ key: String) {
        if let combo, let data = try? JSONEncoder().encode(combo) {
            defaults.set(data, forKey: key)
        } else {
            defaults.set(Data(), forKey: key)   // explicitly cleared
        }
    }

    private static func load(_ key: String, default value: KeyCombo?) -> KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return value }
        if data.isEmpty { return nil }
        return (try? JSONDecoder().decode(KeyCombo.self, from: data)) ?? value
    }

    // MARK: Per-command hotkeys and aliases

    /// Assigns (or clears) a command's hotkey. A combo can only belong to one thing: it is taken
    /// away from any other command or launcher hotkey that had it.
    func setHotKey(_ combo: KeyCombo?, for id: String) {
        var map = commandHotKeys
        if let combo {
            for (other, c) in map where c == combo && other != id { map[other] = nil }
            if launcherHotKey == combo { launcherHotKey = nil }
            if clipboardHotKey == combo { clipboardHotKey = nil }
            if emojiHotKey == combo { emojiHotKey = nil }
            if snippetsHotKey == combo { snippetsHotKey = nil }
        }
        map[id] = combo
        commandHotKeys = map
    }

    func setAlias(_ alias: String?, for id: String) {
        let a = alias?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var map = aliases
        if a.isEmpty { map[id] = nil } else {
            for (other, v) in map where v == a && other != id { map[other] = nil }
            map[id] = a
        }
        aliases = map
    }

    /// Which command (or launcher hotkey) uses a combo, for conflict hints.
    func owner(of combo: KeyCombo) -> String? {
        if launcherHotKey == combo { return "launcher" }
        if clipboardHotKey == combo { return "clipboard" }
        if emojiHotKey == combo { return "emoji" }
        if snippetsHotKey == combo { return "snippets" }
        return commandHotKeys.first { $0.value == combo }?.key
    }

    private func applyWindowDefaults(_ on: Bool) {
        var map = commandHotKeys
        for layout in WindowManager.Layout.allCases {
            let id = "window:\(layout.rawValue)"
            guard let d = layout.defaultHotKey else { continue }
            if on {
                if map[id] == nil, !map.values.contains(d) { map[id] = d }
            } else if map[id] == d {
                map[id] = nil
            }
        }
        commandHotKeys = map
    }

    func isIgnored(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return clipboardIgnoredApps.contains { $0.lowercased() == id }
    }

    static var supportDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Small JSON-file persistence used by the launcher stores.
enum JSONFile {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.iso.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
