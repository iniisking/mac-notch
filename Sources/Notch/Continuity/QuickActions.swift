import AppKit

/// Messages replies, iPhone Mirroring and Shortcuts: one-shot actions offered by the notch.
@MainActor
enum QuickActions {
    // MARK: - Messages reply

    /// The Messages chat a notification came from (`thre`, e.g. "any;-;+15551234567" or
    /// "any;+;chat123…"), if it can be replied to. Alphanumeric short codes (bank / carrier
    /// senders) can't receive replies.
    static func replyTarget(for n: NotchNotification) -> String? {
        guard n.bundleID.lowercased() == "com.apple.mobilesms", !n.isTest,
              let chat = n.threadID, chat.contains(";") else { return nil }
        let parts = chat.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        if parts[1] == "+" { return chat }                       // group chat
        let handle = String(parts[2])
        let isPhone = handle.filter(\.isNumber).count >= 6 && handle.allSatisfy { "+0123456789 -()".contains($0) }
        return (isPhone || handle.contains("@")) ? chat : nil
    }

    /// Sends `text` to the chat through Messages' AppleScript dictionary (macOS asks once for
    /// permission to control Messages). Falls back to the handle on the iMessage, then SMS, service.
    static func sendMessage(_ text: String, chat: String, done: @escaping @MainActor (Bool) -> Void) {
        let body = escape(text)
        let handle = escape(String(chat.split(separator: ";", omittingEmptySubsequences: false).last ?? ""))
        let isGroup = chat.split(separator: ";", omittingEmptySubsequences: false).dropFirst().first == "+"
        let fallback = isGroup ? "error \"no chat\"" : """
            try
                send "\(body)" to participant "\(handle)" of (1st account whose service type = iMessage)
            on error
                send "\(body)" to participant "\(handle)" of (1st account whose service type = SMS)
            end try
        """
        let script = """
        tell application "Messages"
            try
                send "\(body)" to chat id "\(escape(chat))"
            on error
                \(fallback)
            end try
        end tell
        return "ok"
        """
        AppleScriptRunner.run(script, timeout: 15) { out in
            let ok = out?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
            DebugLog.write("messages reply: \(ok ? "sent" : "failed")")
            MainActor.assumeIsolated { done(ok) }
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - iPhone Mirroring

    static let mirroringBundleID = "com.apple.ScreenContinuity"

    static var mirroringURL: URL? {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mirroringBundleID) { return u }
        let path = "/System/Applications/iPhone Mirroring.app"
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    static func openMirroring() {
        guard let url = mirroringURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Shortcuts

    /// Runs a Shortcut by name with the `shortcuts` command-line tool.
    static func runShortcut(_ name: String, done: (@MainActor (Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["run", name]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            var ok = false
            do {
                try p.run()
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            } catch {}
            DebugLog.write("shortcut '\(name)': \(ok ? "ok" : "failed")")
            DispatchQueue.main.async { MainActor.assumeIsolated { done?(ok) } }
        }
    }

    /// Names of the user's Shortcuts (for Settings).
    static func listShortcuts(done: @escaping @MainActor ([String]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["list"]
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var names: [String] = []
            if (try? p.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(names.sorted()) } }
        }
    }
}
