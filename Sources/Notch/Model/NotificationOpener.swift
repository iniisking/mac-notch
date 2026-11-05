import AppKit

/// Opens the exact conversation a notification belongs to, when we can.
/// Order: the app's own default-action URL (Messages: `durl`) → WhatsApp chat link built from the
/// sender's number (1:1 chats only, never with text, so nothing is sent) → the app itself.
@MainActor
enum NotificationOpener {
    /// A URL that lands in the exact conversation, or nil if we only know the app.
    static func deepLink(for n: NotchNotification) -> URL? {
        if let s = n.defaultURL, let url = URL(string: s), url.scheme != nil,
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            return url
        }
        if n.bundleID.lowercased() == "net.whatsapp.whatsapp" {
            let jid = n.chatJID ?? n.threadID ?? ""
            var digits: String?
            if jid.hasSuffix("@s.whatsapp.net") {
                digits = String(jid.prefix { $0.isNumber })
            } else if !jid.hasSuffix("@g.us"), let phone = n.senderPhone {
                // "@lid" ids aren't phone numbers; for 1:1 chats the sender's handle is.
                digits = phone.filter(\.isNumber)
            }
            if let d = digits, (7...15).contains(d.count), let url = URL(string: "whatsapp://send?phone=\(d)") {
                return url
            }
        }
        return nil
    }

    static func open(_ n: NotchNotification) {
        if let url = deepLink(for: n) {
            DebugLog.write("open conversation: \(n.bundleID) via \(url.scheme ?? "?")://")
            NSWorkspace.shared.open(url)
            return
        }
        DebugLog.write("open conversation: \(n.bundleID) → app (no exact link)")
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: n.bundleID) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
