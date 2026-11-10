import AppKit
import Combine
import IOKit.pwr_mgt

/// A countdown, stopwatch or Pomodoro shown live in the notch wings.
struct NotchTimer: Equatable {
    enum Kind: Equatable {
        case countdown(TimeInterval)
        case stopwatch
        case pomodoro(work: Bool, length: TimeInterval, round: Int)
    }

    var kind: Kind
    var name: String
    /// Start of the current run (shifted forward by paused time).
    var started: Date
    var pausedAt: Date?

    var isPaused: Bool { pausedAt != nil }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        max(0, (pausedAt ?? now).timeIntervalSince(started))
    }

    var length: TimeInterval? {
        switch kind {
        case .countdown(let t): return t
        case .pomodoro(_, let t, _): return t
        case .stopwatch: return nil
        }
    }

    func remaining(at now: Date = Date()) -> TimeInterval? {
        length.map { max(0, $0 - elapsed(at: now)) }
    }

    /// What the right wing shows: time left, or elapsed for a stopwatch.
    func display(at now: Date = Date()) -> String {
        (remaining(at: now) ?? elapsed(at: now)).mmss
    }

    var symbol: String {
        switch kind {
        case .countdown: return "timer"
        case .stopwatch: return "stopwatch"
        case .pomodoro(let work, _, _): return work ? "brain.head.profile" : "cup.and.saucer.fill"
        }
    }
}

/// Owns the timer and Caffeinate (keep-awake) state.
@MainActor
final class TimerService: ObservableObject {
    @Published private(set) var timer: NotchTimer?
    @Published private(set) var caffeinatedUntil: Date?
    @Published private(set) var isCaffeinated = false
    /// Moments to show in the notch (finished, phase changes).
    let moments = PassthroughSubject<Moment, Never>()

    private let settings: LauncherSettings
    private var tick: Timer?
    private var assertion: IOPMAssertionID = 0
    private var caffeineWork: DispatchWorkItem?

    init(settings: LauncherSettings) {
        self.settings = settings
    }

    // MARK: Timer

    func startCountdown(_ seconds: TimeInterval, name: String? = nil) {
        timer = NotchTimer(kind: .countdown(seconds), name: name ?? "Timer", started: Date())
        startTicking()
    }

    func startStopwatch() {
        timer = NotchTimer(kind: .stopwatch, name: "Stopwatch", started: Date())
        startTicking()
    }

    func startPomodoro() {
        timer = NotchTimer(kind: .pomodoro(work: true, length: Double(settings.pomodoroWork) * 60, round: 1),
                           name: "Focus", started: Date())
        startTicking()
    }

    func togglePause() {
        guard var t = timer else { return }
        if let p = t.pausedAt {
            t.started = t.started.addingTimeInterval(Date().timeIntervalSince(p))
            t.pausedAt = nil
        } else {
            t.pausedAt = Date()
        }
        timer = t
    }

    func addMinute() {
        guard var t = timer else { return }
        switch t.kind {
        case .countdown(let len): t.kind = .countdown(len + 60)
        case .pomodoro(let w, let len, let r): t.kind = .pomodoro(work: w, length: len + 60, round: r)
        case .stopwatch: return
        }
        timer = t
    }

    func stop() {
        timer = nil
        tick?.invalidate()
        tick = nil
    }

    private func startTicking() {
        tick?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    private func check() {
        guard let t = timer, !t.isPaused, let left = t.remaining(), left <= 0 else { return }
        NSSound(named: NSSound.Name(settings.timerSound))?.play()
        switch t.kind {
        case .countdown(let len):
            moments.send(Moment(kind: .timer, left: .symbol("timer", ContinuityColors.orange), right: .symbol("bell.fill", ContinuityColors.orange),
                                title: "\(t.name) done", detail: len.mmss, duration: 8))
            stop()
        case .pomodoro(let work, _, let round):
            let next = NotchTimer(kind: .pomodoro(work: !work, length: Double(work ? settings.pomodoroBreak : settings.pomodoroWork) * 60,
                                                  round: work ? round : round + 1),
                                  name: work ? "Break" : "Focus", started: Date())
            timer = next
            moments.send(Moment(kind: .timer, left: .symbol(next.symbol, ContinuityColors.orange), right: .text(next.display(), ContinuityColors.orange),
                                title: work ? "Time for a break" : "Back to focus", detail: work ? "Round \(round) done" : "Round \(round + 1)", duration: 6))
        case .stopwatch:
            break
        }
    }

    // MARK: Caffeinate

    /// Keeps the Mac (and display) awake. nil duration = until turned off.
    func caffeinate(for duration: TimeInterval?) {
        releaseAssertion()
        let reason = "Notch: Caffeinate" as CFString
        let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion)
        guard ok == kIOReturnSuccess else { return }
        isCaffeinated = true
        caffeinatedUntil = duration.map { Date().addingTimeInterval($0) }
        caffeineWork?.cancel()
        if let duration {
            let work = DispatchWorkItem { [weak self] in self?.decaffeinate() }
            caffeineWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
        moments.send(Moment(kind: .caffeinate, left: .symbol("cup.and.saucer.fill", ContinuityColors.orange), right: .text("On", ContinuityColors.orange),
                            title: "Caffeinate", detail: duration.map { "Awake for \($0.hm)" } ?? "Awake until turned off", duration: 2.5))
    }

    func decaffeinate() {
        guard isCaffeinated else { return }
        releaseAssertion()
        caffeineWork?.cancel()
        isCaffeinated = false
        caffeinatedUntil = nil
        moments.send(Moment(kind: .caffeinate, left: .symbol("cup.and.saucer", .white.opacity(0.6)), right: .text("Off", .white.opacity(0.6)),
                            title: "Caffeinate", detail: "Sleep allowed again", duration: 2))
    }

    private func releaseAssertion() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }

    // MARK: Parsing "25m", "1h30", "90s", "5"

    static func parseDuration(_ s: String) -> TimeInterval? {
        let t = s.lowercased().replacingOccurrences(of: " ", with: "")
        guard !t.isEmpty else { return nil }
        if let mins = Double(t) { return mins * 60 }   // bare number = minutes
        if t.contains(":") {
            let parts = t.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2 { return parts[0] * 60 + parts[1] }
            if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
            return nil
        }
        guard let re = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)(h|hr|hrs|hours?|m|min|mins|minutes?|s|sec|secs|seconds?)"#) else { return nil }
        var total: TimeInterval = 0
        var matched = 0
        for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            guard let nr = Range(m.range(at: 1), in: t), let ur = Range(m.range(at: 2), in: t), let n = Double(t[nr]) else { continue }
            matched += m.range.length
            switch t[ur].first {
            case "h": total += n * 3600
            case "m": total += n * 60
            default: total += n
            }
        }
        // "1h30" → trailing bare number counts as minutes.
        if matched < t.count, let tail = t.split(whereSeparator: { $0.isLetter }).last, let n = Double(tail), t.hasSuffix(String(tail)) {
            total += n * 60
        }
        return total > 0 ? total : nil
    }
}

extension TimeInterval {
    /// "1h 30m", "45m", "30s"
    var hm: String {
        let s = Int(self)
        if s >= 3600 { return s % 3600 / 60 > 0 ? "\(s / 3600)h \(s % 3600 / 60)m" : "\(s / 3600)h" }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }
}
