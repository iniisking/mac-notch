import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Posting keystrokes into other apps (⌘V paste-back, snippet expansion, the cursor placeholder).
/// macOS requires Accessibility permission for this.
enum Keystrokes {
    /// Marks events we post so the snippet expander's event tap ignores them.
    static let marker: Int64 = 0x4E544348

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow Accessibility" prompt (once; afterwards System Settings must be used).
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    static func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    static func post(key: Int, flags: CGEventFlags = [], count: Int = 1) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down) else { continue }
                e.flags = flags
                e.setIntegerValueField(.eventSourceUserData, value: marker)
                e.post(tap: .cghidEventTap)
            }
        }
    }

    /// ⌘V into whatever app is frontmost.
    static func pasteCommand() {
        post(key: kVK_ANSI_V, flags: .maskCommand)
    }
}

/// Writes something to the clipboard and pastes it into the app that was frontmost before the
/// launcher opened. The launcher is a non-activating panel, so that app never lost "frontmost";
/// once the panel is gone, ⌘V lands there.
@MainActor
enum PasteBack {
    /// Called before Notch writes the pasteboard (clipboard history uses it to skip the "Copied" moment).
    static var willWrite: () -> Void = {}

    /// - Returns: false when only copying was possible (no Accessibility permission).
    @discardableResult
    static func paste(cursorOffset: Int = 0, _ write: (NSPasteboard) -> Void) -> Bool {
        let pb = NSPasteboard.general
        willWrite()
        pb.clearContents()
        write(pb)
        guard Keystrokes.isTrusted else {
            Keystrokes.requestTrust()
            return false
        }
        whenOtherAppIsFrontmost {
            Keystrokes.pasteCommand()
            if cursorOffset > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    Keystrokes.post(key: kVK_LeftArrow, count: cursorOffset)
                }
            }
        }
        return true
    }

    /// ⌘V must land in the target app: wait (up to ~1 s) until Notch isn't frontmost, plus a beat
    /// for the launcher panel to be gone.
    private static func whenOtherAppIsFrontmost(tries: Int = 0, _ then: @escaping @MainActor () -> Void) {
        let me = ProcessInfo.processInfo.processIdentifier
        let ready = NSWorkspace.shared.frontmostApplication?.processIdentifier != me
        if ready || tries > 30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 0 ? 0.1 : 0.15)) { then() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { whenOtherAppIsFrontmost(tries: tries + 1, then) }
        }
    }

    static func copy(_ write: (NSPasteboard) -> Void) {
        let pb = NSPasteboard.general
        willWrite()
        pb.clearContents()
        write(pb)
    }

    static func copy(text: String) {
        copy { $0.setString(text, forType: .string) }
    }

    static func paste(text: String) -> Bool {
        paste { $0.setString(text, forType: .string) }
    }
}
