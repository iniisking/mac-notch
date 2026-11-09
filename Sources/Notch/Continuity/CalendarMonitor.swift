import AppKit
import Combine
import EventKit

struct UpcomingEvent: Equatable, Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var calendarColor: NSColor?
    var location: String?
    /// Meet / Zoom / Teams / Webex / FaceTime link found in the event.
    var joinURL: URL?

    var isNow: Bool { start <= Date() && end > Date() }

    /// "in 12m", "now", "at 14:30".
    var whenText: String {
        let now = Date()
        if isNow { return "now" }
        let mins = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if mins < 60 { return "in \(max(1, mins))m" }
        if Calendar.current.isDateInToday(start) { return "at " + start.formatted(date: .omitted, time: .shortened) }
        return start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    var serviceName: String? {
        guard let host = joinURL?.host?.lowercased() else { return nil }
        if host.contains("meet.google") { return "Meet" }
        if host.contains("zoom") { return "Zoom" }
        if host.contains("teams") { return "Teams" }
        if host.contains("webex") { return "Webex" }
        if host.contains("facetime") { return "FaceTime" }
        return nil
    }
}

/// Calendars synced from iPhone (iCloud, Google, Exchange) through EventKit. Keeps the next
/// timed event in the coming 12 hours (or the one in progress), and announces a minute before a
/// meeting with a join link starts. Needs Calendar access (macOS asks once).
@MainActor
final class CalendarMonitor: ObservableObject {
    @Published private(set) var next: UpcomingEvent?
    @Published private(set) var authorized = false
    @Published private(set) var denied = false
    /// A meeting with a link starts in about a minute.
    let startingSoon = PassthroughSubject<UpcomingEvent, Never>()

    private let store = EKEventStore()
    private var timer: Timer?
    private var announced = Set<String>()
    private var changeObserver: NSObjectProtocol?

    func start() {
        guard timer == nil else { return }
        requestAccess()
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let o = changeObserver { NotificationCenter.default.removeObserver(o) }
        changeObserver = nil
        next = nil
    }

    private func requestAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .authorized:
            authorized = true
            refresh()
        case .denied, .restricted, .writeOnly:
            denied = true
        default:
            store.requestFullAccessToEvents { [weak self] granted, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.authorized = granted
                        self?.denied = !granted
                        DebugLog.write("calendar: access \(granted ? "granted" : "denied")")
                        if granted { self?.refresh() }
                    }
                }
            }
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    private func refresh() {
        guard authorized else { return }
        let now = Date()
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600),
                                            end: now.addingTimeInterval(12 * 3600), calendars: nil)
        let events = store.events(matching: pred)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled && !Self.declined($0) }
            .sorted { $0.startDate < $1.startDate }
        // Prefer an upcoming meeting over one that's nearly over.
        let pick = events.first { $0.startDate > now } .flatMap { upcoming -> EKEvent? in
            if let current = events.first(where: { $0.startDate <= now }),
               current.endDate.timeIntervalSince(now) > 10 * 60 || upcoming.startDate.timeIntervalSince(now) > 15 * 60 {
                return current
            }
            return upcoming
        } ?? events.first
        let ev = pick.map(Self.make)
        if ev != next { next = ev }

        // One-minute heads-up for meetings with a join link.
        for e in events where e.startDate > now && e.startDate.timeIntervalSince(now) <= 70 {
            let up = Self.make(e)
            guard up.joinURL != nil, !announced.contains(up.id) else { continue }
            announced.insert(up.id)
            startingSoon.send(up)
        }
    }

    private static func declined(_ e: EKEvent) -> Bool {
        e.attendees?.first(where: { $0.isCurrentUser })?.participantStatus == .declined
    }

    private static func make(_ e: EKEvent) -> UpcomingEvent {
        UpcomingEvent(id: (e.eventIdentifier ?? UUID().uuidString) + "@\(e.startDate.timeIntervalSince1970)",
                      title: e.title?.isEmpty == false ? e.title! : "Event",
                      start: e.startDate, end: e.endDate,
                      calendarColor: e.calendar?.color,
                      location: e.location?.isEmpty == false ? e.location : nil,
                      joinURL: joinLink(in: [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }))
    }

    private static let linkPattern = try! NSRegularExpression(
        pattern: #"https?://[^\s<>"']*(meet\.google\.com|zoom\.us|zoomgov\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|facetime\.apple\.com|whereby\.com|meet\.jit\.si)[^\s<>"']*"#,
        options: [.caseInsensitive])

    static func joinLink(in texts: [String]) -> URL? {
        for t in texts {
            let range = NSRange(t.startIndex..., in: t)
            if let m = linkPattern.firstMatch(in: t, range: range), let r = Range(m.range, in: t) {
                let s = String(t[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)>]"))
                if let u = URL(string: s) { return u }
            }
        }
        return nil
    }

    func debugDemo() {
        let e = UpcomingEvent(id: "demo", title: "Design review", start: Date().addingTimeInterval(60),
                              end: Date().addingTimeInterval(1860), calendarColor: .systemPurple,
                              location: nil, joinURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        next = e
        startingSoon.send(e)
    }
}
