import Foundation

enum SourceStatus: Equatable {
    case starting
    case running
    case permissionDenied(String)
    case unavailable(String)

    var needsFullDiskAccess: Bool {
        if case .permissionDenied = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .starting: return "Starting…"
        case .running: return "Reading Notification Center"
        case .permissionDenied: return "Full Disk Access needed"
        case .unavailable(let s): return "Unavailable: \(s)"
        }
    }
}

enum NotificationSourceEvent {
    case status(SourceStatus)
    /// Existing notifications loaded at startup (newest first). Shown in history, never flashed.
    case history([NotchNotification])
    /// Newly delivered notifications (oldest first). `live` ones light up the notch.
    case arrived([NotchNotification], live: Bool)
}

/// Anything that can feed notifications into the notch.
protocol NotificationSource: AnyObject {
    /// Called on the main queue.
    var onEvent: ((NotificationSourceEvent) -> Void)? { get set }
    func start()
    func stop()
}
