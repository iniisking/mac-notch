import AppKit
import Carbon.HIToolbox
import Combine

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Typed anywhere to expand (when expansion is on), e.g. ";addr".
    var keyword: String = ""
    var text: String
}

/// Saved text snippets with placeholders:
/// {date} {time} {datetime} {day} {clipboard} {uuid} {cursor} (caret ends up there).
@MainActor
final class SnippetStore: ObservableObject {
    @Published var snippets: [Snippet] { didSet { JSONFile.save(snippets, to: Self.file) } }
    private static let file = LauncherSettings.supportDirectory.appendingPathComponent("snippets.json")

    init() {
        snippets = JSONFile.load([Snippet].self, from: Self.file) ?? [
            Snippet(name: "Today's date", keyword: ";date", text: "{date}"),
            Snippet(name: "Shrug", keyword: ";shrug", text: "¯\\_(ツ)_/¯"),
            Snippet(name: "Email sign-off", keyword: ";thx", text: "Thanks,\n{cursor}"),
        ]
    }

    /// Text with placeholders filled, and how many characters the caret must move back for {cursor}.
    static func expand(_ s: Snippet) -> (text: String, cursorBack: Int) {
        let now = Date()
        func fmt(_ date: DateFormatter.Style, _ time: DateFormatter.Style) -> String {
            DateFormatter.localizedString(from: now, dateStyle: date, timeStyle: time)
        }
        var t = s.text
        let replacements: [(String, () -> String)] = [
            ("{datetime}", { fmt(.medium, .short) }),
            ("{date}", { fmt(.medium, .none) }),
            ("{time}", { fmt(.none, .short) }),
            ("{isodate}", { ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate]) }),
            ("{day}", { now.formatted(.dateTime.weekday(.wide)) }),
            ("{clipboard}", { NSPasteboard.general.string(forType: .string) ?? "" }),
            ("{uuid}", { UUID().uuidString }),
        ]
        for (key, value) in replacements where t.contains(key) {
            t = t.replacingOccurrences(of: key, with: value())
        }
        var back = 0
        if let r = t.range(of: "{cursor}") {
            back = t[r.upperBound...].count
            t.removeSubrange(r)
        }
        return (t, back)
    }

    func items(query: String) -> [LauncherItem] {
        snippets.compactMap { s in
            let score = FuzzyMatch.best(query, title: s.name, keywords: [s.keyword, s.text])
            guard score > 0 else { return nil }
            var item = LauncherItem(
                id: "snippet:\(s.id)", title: s.name, subtitle: NotchNotification.oneLine(s.text),
                icon: .symbol("text.quote", LauncherColors.indigo), accessory: s.keyword.isEmpty ? "Snippet" : s.keyword,
                section: "Snippets", actions: Self.actions(for: s), preview: .text(s.text), learnKey: "snippet:\(s.id)")
            item.score = score
            return item
        }
    }

    static func actions(for s: Snippet) -> [LauncherAction] {
        [
            LauncherAction(title: "Paste Snippet", symbol: "doc.on.clipboard") { m in
                let (text, back) = expand(s)
                m.paste(text: text, cursorBack: back)
            },
            LauncherAction(title: "Copy Snippet", symbol: "doc.on.doc", shortcut: "⌘↩") { m in
                PasteBack.copy(text: expand(s).text); m.hide(toast: "Snippet copied")
            },
            LauncherAction(title: "Edit Snippets…", symbol: "pencil") { m in
                m.hide(); m.services.openSettings(.snippets)
            },
            LauncherAction(title: "Delete Snippet", symbol: "trash", destructive: true) { m in
                m.services.snippets.snippets.removeAll { $0.id == s.id }; m.refresh()
            },
        ]
    }
}

/// Expands snippet keywords as you type, in any app. A listen-only event tap watches key presses
/// (Input Monitoring permission), keeps the last few typed characters, and when they end with a
/// keyword, deletes it with backspaces and pastes the snippet (the clipboard is restored afterwards).
@MainActor
final class SnippetExpander {
    private let store: SnippetStore
    private let clipboard: ClipboardHistory
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var buffer = ""
    private(set) var isRunning = false

    init(store: SnippetStore, clipboard: ClipboardHistory) {
        self.store = store
        self.clipboard = clipboard
    }

    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    func start() {
        guard tap == nil else { return }
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
            DebugLog.write("snippet expansion: waiting for Input Monitoring permission")
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<SnippetExpander>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                DispatchQueue.main.async { MainActor.assumeIsolated { me.reenable() } }
                return Unmanaged.passUnretained(event)
            }
            guard event.getIntegerValueField(.eventSourceUserData) != Keystrokes.marker else {
                return Unmanaged.passUnretained(event)
            }
            if type != .keyDown {
                DispatchQueue.main.async { MainActor.assumeIsolated { me.buffer = "" } }
                return Unmanaged.passUnretained(event)
            }
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            var length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
            let typed = String(utf16CodeUnits: chars, count: length)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { me.handle(keyCode: keyCode, flags: flags, typed: typed) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: CGEventMask(mask), callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            DebugLog.write("snippet expansion: event tap unavailable (Input Monitoring not granted)")
            return
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        isRunning = true
        DebugLog.write("snippet expansion: on")
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
        buffer = ""
        isRunning = false
    }

    private func reenable() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
    }

    private func handle(keyCode: Int, flags: CGEventFlags, typed: String) {
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            buffer = ""
            return
        }
        switch keyCode {
        case kVK_Delete:
            if !buffer.isEmpty { buffer.removeLast() }
            return
        case kVK_Return, kVK_Tab, kVK_Escape, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ANSI_KeypadEnter:
            buffer = ""
            return
        default:
            break
        }
        guard !typed.isEmpty, typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return }
        buffer += typed
        if buffer.count > 48 { buffer = String(buffer.suffix(48)) }
        guard let s = store.snippets.first(where: { !$0.keyword.isEmpty && buffer.hasSuffix($0.keyword) }) else { return }
        buffer = ""
        expand(s)
    }

    private func expand(_ s: Snippet) {
        guard Keystrokes.isTrusted else {
            Keystrokes.requestTrust()
            return
        }
        let (text, back) = SnippetStore.expand(s)
        let pb = NSPasteboard.general
        // Keep what was on the clipboard and put it back afterwards.
        let saved = pb.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        } ?? []
        Keystrokes.post(key: kVK_Delete, count: s.keyword.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.clipboard.noteOwnWrite()
            pb.clearContents()
            pb.setString(text, forType: .string)
            Keystrokes.pasteCommand()
            if back > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Keystrokes.post(key: kVK_LeftArrow, count: back) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.clipboard.noteOwnWrite()
                pb.clearContents()
                let items = saved.map { dict -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (t, v) in dict { item.setData(v, forType: t) }
                    return item
                }
                if !items.isEmpty { pb.writeObjects(items) }
            }
        }
    }
}
