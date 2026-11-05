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
        let t = Self.clean(title)
        if !t.isEmpty { return t }
        if !subtitle.isEmpty { return Self.clean(subtitle) }
        return Self.clean(body).replacingOccurrences(of: "\n", with: " ")
    }

    /// Short compact label: the sender (Messages/WhatsApp/Telegram/Slack…: `titl`), the event (Calendar:
    /// `titl`), the sender (Mail: `titl`, subject is `subt`); otherwise the title, or the first words of
    /// the body. Never the app name. Bidi/zero-width marks (WhatsApp prefixes U+200E) are stripped.
    var shortLabel: String {
        let t = Self.clean(title)
        if !t.isEmpty { return t }
        let words = Self.clean(body).split(whereSeparator: { $0.isWhitespace }).prefix(4)
        if !words.isEmpty { return words.joined(separator: " ") }
        return Self.clean(subtitle)
    }

    /// Strip under the notch: "Sender - preview".
    /// Chats/others: title - body. Mail: sender - subject (or body). Calendar: event - body (or subtitle).
    var stripParts: (primary: String, secondary: String) {
        let id = bundleID.lowercased()
        let t = Self.oneLine(title), sub = Self.oneLine(subtitle), b = Self.oneLine(body)
        let isMail = ["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail-mac", "com.superhuman.electron",
                      "com.google.gmail", "it.bloop.airmail2"].contains(id)
        let isCalendar = ["com.apple.ical", "com.flexibits.fantastical2.mac", "com.microsoft.outlook.calendar"].contains(id)
        var primary = t
        var secondary: String
        if isMail { secondary = sub.isEmpty ? b : sub }
        else if isCalendar { secondary = b.isEmpty ? sub : b }
        else { secondary = b.isEmpty ? sub : b }
        if primary.isEmpty { primary = secondary; secondary = "" }
        if primary == secondary { secondary = "" }
        return (primary, secondary)
    }

    /// Single line: invisible marks stripped, newlines/tabs collapsed to single spaces.
    static func oneLine(_ s: String) -> String {
        clean(s).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func clean(_ s: String) -> String {
        let invisible: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
                                              "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
                                              "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{FEFF}"]
        let scalars = s.unicodeScalars.filter { !invisible.contains($0) }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
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
