import Foundation

struct NotchNotification: Identifiable, Hashable, Codable {
    let id: String
    let recID: Int64?
    let bundleID: String
    let title: String
    let subtitle: String
    let body: String
    let threadID: String?
    let date: Date
    var isTest: Bool = false

    /// One-line text for the compact state: sender/title, falling back to the body.
    var summary: String {
        if !title.isEmpty { return title }
        if !subtitle.isEmpty { return subtitle }
        return body.replacingOccurrences(of: "\n", with: " ")
    }

    /// Everything as plain text, for "Copy".
    var fullText: String {
        [title, subtitle, body].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

extension NotchNotification {
    static func test(index: Int = Int.random(in: 0..<100)) -> NotchNotification {
        let samples: [(String, String, String, String)] = [
            ("com.apple.MobileSMS", "Ada Lovelace", "", "Are we still on for 7pm? I booked the table by the window. Bring the notes from yesterday if you can."),
            ("com.apple.mail", "GitHub", "[cadence-bible] PR #42 ready for review", "theajstars requested your review on “Add rate limiting to the scripture search endpoint”. 3 files changed, 120 additions."),
            ("com.apple.Notes", "Release checklist", "Shared by Grace Hopper", "Pushed the new notch animations, take a look when you get a chance 🎉"),
            ("com.apple.iCal", "Standup in 5 minutes", "Today 10:00 – 10:15", "Zoom link in the event notes."),
            ("com.apple.reminders", "Reminder", "", "Water the plants"),
        ]
        let s = samples[index % samples.count]
        return NotchNotification(id: "test-\(UUID().uuidString)", recID: nil, bundleID: s.0,
                                 title: s.1, subtitle: s.2, body: s.3, threadID: nil,
                                 date: Date(), isTest: true)
    }
}
