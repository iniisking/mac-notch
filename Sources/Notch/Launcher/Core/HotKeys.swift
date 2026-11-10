import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key plus modifiers, stored as the Carbon virtual key code and Cocoa modifier flags.
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt   // NSEvent.ModifierFlags raw value (device independent bits only)

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = modifiers.intersection(.deviceIndependentFlagsMask).intersection([.command, .option, .control, .shift]).rawValue
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// "⌃⌥⌘←"
    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + Self.keyName(Int(keyCode))
    }

    static func keyName(_ code: Int) -> String {
        switch code {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: break
        }
        // Ask the current keyboard layout what the key types.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Global hotkeys through Carbon's RegisterEventHotKey: no permission needed and they work while
/// any app is frontmost. Each registration is keyed by a name so Settings can rebind it.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private struct Entry {
        var combo: KeyCombo
        var ref: EventHotKeyRef?
        var action: @MainActor () -> Void
    }

    private var entries: [UInt32: Entry] = [:]
    private var idsByName: [String: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    private var suspended = false
    private static let signature: OSType = 0x4E544348   // 'NTCH'

    private init() {}

    /// Registers (or replaces) the hotkey called `name`. Passing nil removes it.
    func set(_ name: String, combo: KeyCombo?, action: @escaping @MainActor () -> Void) {
        remove(name)
        guard let combo else { return }
        installHandler()
        let id = nextID
        nextID += 1
        idsByName[name] = id
        entries[id] = Entry(combo: combo, ref: nil, action: action)
        if !suspended { register(id) }
    }

    func remove(_ name: String) {
        guard let id = idsByName.removeValue(forKey: name) else { return }
        if let ref = entries[id]?.ref { UnregisterEventHotKey(ref) }
        entries[id] = nil
    }

    /// Removes every hotkey whose name starts with `prefix` (e.g. all window layouts).
    func removeAll(prefix: String) {
        for name in idsByName.keys where name.hasPrefix(prefix) { remove(name) }
    }

    /// While recording a new shortcut in Settings, the old ones must not swallow the keys.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        for (id, e) in entries {
            if let ref = e.ref { UnregisterEventHotKey(ref) }
            entries[id]?.ref = nil
        }
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        for id in entries.keys { register(id) }
    }

    /// Name of the hotkey already using this combo, if any (Settings warns about clashes).
    func owner(of combo: KeyCombo) -> String? {
        for (name, id) in idsByName where entries[id]?.combo == combo { return name }
        return nil
    }

    private func register(_ id: UInt32) {
        guard let e = entries[id] else { return }
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(e.combo.keyCode, e.combo.carbonModifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            entries[id]?.ref = ref
        } else {
            DebugLog.write("hotkey \(e.combo.display) could not be registered (\(status)); another app may own it")
        }
    }

    fileprivate func fire(_ id: UInt32) {
        entries[id]?.action()
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard status == noErr else { return status }
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - Recorder

/// Settings control: click, then press the new shortcut. Esc cancels, ⌫ clears.
struct HotKeyRecorder: View {
    @Binding var combo: KeyCombo?
    var allowsClear = true
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Type shortcut…" : (combo?.display ?? "Record shortcut"))
                    .font(.system(size: 12, weight: .medium).monospaced())
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if allowsClear, combo != nil, !recording {
                Button { combo = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove shortcut")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch Int(event.keyCode) {
            case kVK_Escape where mods.isEmpty:
                stop()
            case kVK_Delete where mods.isEmpty:
                if allowsClear { combo = nil }
                stop()
            default:
                // Require a modifier, except for function keys.
                let fKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                       kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
                let isF = fKeys.contains(Int(event.keyCode))
                guard !mods.isEmpty || isF else { NSSound.beep(); return nil }
                combo = KeyCombo(keyCode: Int(event.keyCode), modifiers: mods)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if recording { HotKeyCenter.shared.resume() }
        recording = false
    }
}
