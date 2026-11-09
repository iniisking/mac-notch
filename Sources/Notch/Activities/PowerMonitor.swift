import Combine
import Foundation
import IOKit.ps

struct PowerState: Equatable {
    var percent: Int
    var onAC: Bool
    var charging: Bool
    var charged: Bool
    /// Minutes, nil while macOS is still estimating.
    var minutesToFull: Int?
    var minutesToEmpty: Int?
}

enum PowerEvent: Equatable {
    case pluggedIn
    case low(Int)          // threshold crossed: 20 or 10
}

/// Watches the internal battery through IOKit power-source notifications (no permission needed).
/// Emits an event when power is connected and when the battery drops past 20% / 10%.
@MainActor
final class PowerMonitor: ObservableObject {
    @Published private(set) var state: PowerState?
    let events = PassthroughSubject<PowerEvent, Never>()

    static let lowThresholds = [20, 10]
    private var warned = Set<Int>()
    private var runLoopSource: CFRunLoopSource?

    init() {
        state = Self.read()
        // Don't warn on launch about a level we're already below.
        if let s = state, !s.onAC { warned = Set(Self.lowThresholds.filter { s.percent <= $0 }) }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.refresh() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = src
        }
    }

    var hasBattery: Bool { state != nil }

    private func refresh() {
        let old = state
        guard let new = Self.read() else { state = nil; return }
        state = new
        if new.onAC {
            warned.removeAll()
            if let old, !old.onAC { events.send(.pluggedIn) }
            return
        }
        // Lowest threshold crossed that we haven't warned about yet.
        if let t = Self.lowThresholds.sorted().first(where: { new.percent <= $0 && !warned.contains($0) }) {
            Self.lowThresholds.filter { $0 >= t }.forEach { warned.insert($0) }
            events.send(.low(t))
        }
    }

    private static func read() -> PowerState? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  d[kIOPSIsPresentKey] as? Bool ?? true else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let pct = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            let ttf = d[kIOPSTimeToFullChargeKey] as? Int ?? -1
            let tte = d[kIOPSTimeToEmptyKey] as? Int ?? -1
            return PowerState(percent: Swift.min(100, Swift.max(0, pct)),
                              onAC: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                              charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                              charged: d[kIOPSIsChargedKey] as? Bool ?? false,
                              minutesToFull: ttf > 0 ? ttf : nil,
                              minutesToEmpty: tte > 0 ? tte : nil)
        }
        return nil
    }

    // MARK: - Debug

    /// `--demo-charge` / `--demo-lowbattery`: fake state + event for checking the UI.
    func debugDemo(low: Bool) {
        state = low ? PowerState(percent: 10, onAC: false, charging: false, charged: false, minutesToFull: nil, minutesToEmpty: 34)
                    : PowerState(percent: 67, onAC: true, charging: true, charged: false, minutesToFull: 48, minutesToEmpty: nil)
        events.send(low ? .low(10) : .pluggedIn)
    }
}

extension Int {
    /// 95 -> "1h 35m", 40 -> "40m".
    var hoursMinutes: String {
        self >= 60 ? "\(self / 60)h \(self % 60)m" : "\(self)m"
    }
}
