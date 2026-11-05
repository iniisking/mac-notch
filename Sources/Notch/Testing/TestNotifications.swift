import AppKit
@preconcurrency import UserNotifications

/// Fake notifications for checking the UI. They behave like real ones (compact, strip, hover,
/// expanded, open/copy/dismiss) but are never written to the persisted history.
enum TestPreset: String, CaseIterable, Identifiable {
    case whatsapp, longMessage, mail, calendar, longSender

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whatsapp: return "WhatsApp message"
        case .longMessage: return "Messages (long body)"
        case .mail: return "Mail"
        case .calendar: return "Calendar event"
        case .longSender: return "Very long sender"
        }
    }

    func make() -> NotchNotification {
        let (bundle, title, subtitle, body): (String, String, String, String)
        switch self {
        case .whatsapp:
            (bundle, title, subtitle, body) = ("net.whatsapp.WhatsApp", "Itunu", "", "On my way 🚗")
        case .longMessage:
            (bundle, title, subtitle, body) = ("com.apple.MobileSMS", "Ada Lovelace", "",
                """
                Are we still on for 7pm? I booked the table by the window like you asked.
                Bring the notes from yesterday if you can, I want to go through the second half of the \
                analytical engine draft again because I think the loop section needs another pass.
                Also: parking is terrible there after 6, so maybe take a cab. Let me know either way! 🙂
                """)
        case .mail:
            (bundle, title, subtitle, body) = ("com.apple.mail", "GitHub", "[cadence-bible] PR #42: Add rate limiting",
                "theajstars requested your review on “Add rate limiting to the scripture search endpoint”. "
                + "3 files changed, 120 additions, 14 deletions. CI is green. The change adds a token bucket per API key "
                + "and returns 429 with a Retry-After header when the bucket is empty.")
        case .calendar:
            (bundle, title, subtitle, body) = ("com.apple.iCal", "Design review", "Today 15:00 – 15:30", "Room 4 · Zoom link in notes")
        case .longSender:
            (bundle, title, subtitle, body) = ("ru.keepcoder.Telegram",
                "Bartholomew Montgomery-Fitzgerald III (Product Design Guild)", "",
                "Testing how a really long sender name scrolls in the strip under the notch.")
        }
        return TestPreset.item(bundle: bundle, title: title, subtitle: subtitle, body: body)
    }

    static func item(bundle: String, title: String, subtitle: String, body: String) -> NotchNotification {
        NotchNotification(id: "test-\(UUID().uuidString)", recID: nil, bundleID: bundle,
                          title: title, subtitle: subtitle, body: body, threadID: nil,
                          date: Date(), isTest: true)
    }

    /// Apps offered in the custom form (only those installed are shown).
    static let customApps: [(name: String, bundleID: String)] = [
        ("WhatsApp", "net.whatsapp.WhatsApp"), ("Messages", "com.apple.MobileSMS"), ("Mail", "com.apple.mail"),
        ("Calendar", "com.apple.iCal"), ("Telegram", "ru.keepcoder.Telegram"), ("Slack", "com.tinyspeck.slackmacgap"),
        ("Notes", "com.apple.Notes"), ("Reminders", "com.apple.reminders"), ("Spotify", "com.spotify.client"),
    ]

    static var installedCustomApps: [(name: String, bundleID: String)] {
        customApps.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }
}

/// Posts a real macOS notification from Notch itself, so it travels the full path:
/// Notification Center → usernoted DB → DBNotificationSource → notch (works with Focus on).
/// It isn't injected locally, so it can't appear twice.
@MainActor
final class SystemTestNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var status = ""

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func send() {
        status = "Requesting permission…"
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    status = "Not allowed. Turn on notifications for Notch in System Settings › Notifications."
                    DebugLog.write("system test notification: permission denied")
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = "Notch test"
                content.subtitle = "Real system notification"
                content.body = "Sent at \(Date().formatted(date: .omitted, time: .standard)) through Notification Center."
                try await center.add(UNNotificationRequest(identifier: "notch-test-\(UUID().uuidString)",
                                                           content: content, trigger: nil))
                status = "Sent. It should appear in the notch in a second or two."
            } catch {
                status = "Failed: \(error.localizedDescription)"
            }
            DebugLog.write("system test notification: \(status)")
        }
    }

    /// Make sure it's recorded in Notification Center even though Notch is the "active" app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.list, .banner])
    }
}
