import AppKit
import EventKit

/// "remind call mum tomorrow 6pm" → Reminders (date found with NSDataDetector);
/// "note buy milk" → appended to a Markdown file.
@MainActor
final class QuickCapture {
    private let settings: LauncherSettings
    private let store = EKEventStore()

    init(settings: LauncherSettings) {
        self.settings = settings
    }

    func items(query: String, emit: @escaping (Moment) -> Void) -> [LauncherItem] {
        let lower = query.lowercased()
        var out: [LauncherItem] = []
        for prefix in ["remind me to ", "remind me ", "remind ", "todo ", "reminder "] where lower.hasPrefix(prefix) {
            let body = String(query.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { break }
            let (title, due) = Self.split(body)
            let when = due.map { " · \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            out.append(LauncherItem(
                id: "capture:reminder", title: "Remind: \(title)", subtitle: "Add to Reminders\(when)",
                icon: .bundle("com.apple.reminders"), accessory: "Reminder", section: "Quick Capture",
                actions: [LauncherAction(title: "Add Reminder", symbol: "checklist") { [weak self] m in
                    m.hide()
                    self?.addReminder(title, due: due, emit: emit)
                }],
                boost: 180, score: 100))
            break
        }
        for prefix in ["note ", "jot "] where lower.hasPrefix(prefix) {
            let body = String(query.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { break }
            let file = settings.notesFile
            out.append(LauncherItem(
                id: "capture:note", title: "Note: \(body)", subtitle: "Append to \((file as NSString).abbreviatingWithTildeInPath)",
                icon: .symbol("square.and.pencil", LauncherColors.yellow), accessory: "Note", section: "Quick Capture",
                actions: [
                    LauncherAction(title: "Append Note", symbol: "square.and.pencil") { m in
                        Self.append(body, to: file)
                        m.hide(toast: "Note saved")
                    },
                    LauncherAction(title: "Open Notes File", symbol: "doc.text", shortcut: "⌘↩") { m in
                        Self.append(body, to: file)
                        NSWorkspace.shared.open(URL(fileURLWithPath: file)); m.hide()
                    },
                ],
                boost: 180, score: 100))
            break
        }
        return out
    }

    /// Pulls a date ("tomorrow 6pm", "on friday", "in 2 hours") out of the text.
    static func split(_ text: String) -> (String, Date?) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let date = match.date, let r = Range(match.range, in: text) else { return (text, nil) }
        var title = text
        title.removeSubrange(r)
        title = title.replacingOccurrences(of: #"\s+(at|on|by)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return (title.isEmpty ? text : title, date)
    }

    private func addReminder(_ title: String, due: Date?, emit: @escaping (Moment) -> Void) {
        let save = { [store] in
            let r = EKReminder(eventStore: store)
            r.title = title
            r.calendar = store.defaultCalendarForNewReminders()
            if let due {
                r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                r.addAlarm(EKAlarm(absoluteDate: due))
            }
            do {
                try store.save(r, commit: true)
                emit(Moment(kind: .launcher, left: .appIcon("com.apple.reminders"), right: .symbol("checkmark", ContinuityColors.green),
                            title: "Reminder added", detail: title, duration: 3))
            } catch {
                DebugLog.write("reminder save failed: \(error.localizedDescription)")
                emit(Moment(kind: .launcher, left: .appIcon("com.apple.reminders"), right: .symbol("xmark", ContinuityColors.red),
                            title: "Couldn't add reminder", detail: error.localizedDescription, duration: 4))
            }
        }
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            save()
            return
        }
        store.requestFullAccessToReminders { granted, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if granted { save() } else {
                        emit(Moment(kind: .launcher, left: .appIcon("com.apple.reminders"), right: .symbol("lock.fill", ContinuityColors.red),
                                    title: "Reminders access needed", detail: "System Settings › Privacy & Security › Reminders", duration: 5))
                    }
                }
            }
        }
    }

    static func append(_ text: String, to path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        let line = "- \(text) _(\(stamp))_\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(("# Notes\n\n" + line).utf8).write(to: url)
        }
    }
}
