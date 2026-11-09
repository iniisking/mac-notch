import AppKit
import Combine

/// Owns the device / Continuity monitors, starts and stops them from Settings, and turns what they
/// report into notch moments.
@MainActor
final class ContinuityHub: ObservableObject {
    let audio = AudioDeviceMonitor()
    let clipboard = ClipboardMonitor()
    let airdrop = AirDropMonitor()
    let focus = FocusMonitor()
    let hotspot = HotspotMonitor()
    let calendar = CalendarMonitor()
    let bridge: DeviceBridge

    /// Moments for the notch to show (each window's view model listens).
    let moments = PassthroughSubject<Moment, Never>()

    private let settings: SettingsStore
    private var cancellables = Set<AnyCancellable>()

    init(settings: SettingsStore) {
        self.settings = settings
        bridge = DeviceBridge(settings: settings)

        bind(settings.$showAudioDevices, audio.start, audio.stop)
        bind(settings.$showUniversalClipboard, clipboard.start, clipboard.stop)
        bind(settings.$showAirDrop, airdrop.start, airdrop.stop)
        bind(settings.$showFocus, focus.start, focus.stop)
        bind(settings.$showHotspot, hotspot.start, hotspot.stop)
        bind(settings.$showCalendar, calendar.start, calendar.stop)

        audio.connected.sink { [weak self] in self?.emit(Self.moment(for: $0)) }.store(in: &cancellables)
        clipboard.received.sink { [weak self] in self?.emit(Self.moment(for: $0)) }.store(in: &cancellables)
        airdrop.received.sink { [weak self] in self?.emit(Self.moment(for: $0)) }.store(in: &cancellables)
        focus.changed.sink { [weak self] in self?.emit(Self.moment(focus: $0.1, was: $0.0)) }.store(in: &cancellables)
        hotspot.changed.sink { [weak self] on in
            guard let self else { return }
            self.emit(Self.hotspotMoment(on: on, name: self.hotspot.networkName))
        }
        .store(in: &cancellables)
        calendar.startingSoon.sink { [weak self] in self?.emit(Self.moment(for: $0)) }.store(in: &cancellables)
        bridge.deviceChanged.sink { [weak self] in
            if let m = Self.moment(device: $0.new, was: $0.old) { self?.emit(m) }
        }
        .store(in: &cancellables)
        bridge.events.sink { [weak self] in self?.emit(Self.moment(for: $0)) }.store(in: &cancellables)
    }

    private func bind(_ pub: Published<Bool>.Publisher, _ start: @escaping () -> Void, _ stop: @escaping () -> Void) {
        pub.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { $0 ? start() : stop() }
            .store(in: &cancellables)
    }

    private func emit(_ m: Moment) { moments.send(m) }

    // MARK: - Moments

    static func moment(for d: AudioDevice) -> Moment {
        let pct = d.headline
        return Moment(kind: .audio,
                      left: .symbol(d.symbol),
                      right: pct.map { .text("\($0)%", ContinuityColors.battery($0)) } ?? .symbol("checkmark.circle.fill", ContinuityColors.green),
                      title: d.name,
                      detail: d.batteryDetail.isEmpty ? "Connected" : d.batteryDetail,
                      duration: 4)
    }

    static func moment(for clip: RemoteClip) -> Moment {
        let left: Moment.Glyph = clip.image.map { .image($0) }
            ?? .symbol(clip.url != nil ? "link" : "doc.on.clipboard", ContinuityColors.blue)
        return Moment(kind: .clipboard, left: left, right: .symbol("iphone"),
                      title: "Copied from your device", detail: clip.preview, duration: 3.5,
                      action: clip.url.map { .open($0) }, actionHint: clip.url != nil ? "Click to open link" : nil)
    }

    static func moment(for batch: AirDropBatch) -> Moment {
        Moment(kind: .airdrop,
               left: batch.thumbnail.map { .image($0) } ?? .symbol("doc.fill"),
               right: .symbol("dot.radiowaves.up.forward", ContinuityColors.blue),
               title: "AirDrop", detail: batch.title, duration: 5,
               action: .reveal(batch.files), actionHint: "Click to show in Finder")
    }

    static func moment(focus new: FocusMode?, was old: FocusMode?) -> Moment {
        if let new {
            return Moment(kind: .focus, left: .symbol(new.symbol, ContinuityColors.purple), right: .text("On", ContinuityColors.purple),
                          title: new.name, detail: "Focus on · all devices", duration: 3)
        }
        return Moment(kind: .focus, left: .symbol(old?.symbol ?? "moon.fill", .white.opacity(0.6)), right: .text("Off", .white.opacity(0.6)),
                      title: old?.name ?? "Focus", detail: "Focus off", duration: 2.5)
    }

    static func hotspotMoment(on: Bool, name: String?) -> Moment {
        Moment(kind: .hotspot,
               left: .symbol("personalhotspot", on ? ContinuityColors.green : .white.opacity(0.6)),
               right: .symbol(on ? "iphone" : "iphone.slash"),
               title: on ? "Personal Hotspot" : "Hotspot disconnected",
               detail: on ? (name.map { "Connected to \($0)" } ?? "Connected") : "",
               duration: 3)
    }

    static func moment(for e: UpcomingEvent) -> Moment {
        let service = e.serviceName.map { " on \($0)" } ?? ""
        return Moment(kind: .calendar, left: .appIcon("com.apple.iCal"), right: .text(e.isNow ? "now" : "1m", ContinuityColors.orange),
                      title: e.title, detail: "Starting \(e.isNow ? "now" : "in 1 min")\(service)", duration: 8,
                      action: e.joinURL.map { .open($0) }, actionHint: "Click to join\(service)")
    }

    /// iPhone (or iPad / Watch) battery: announce charging, full and low; quiet otherwise.
    static func moment(device d: BridgedDevice, was old: BridgedDevice?) -> Moment? {
        guard let pct = d.battery else { return nil }
        let charging = d.charging ?? false
        let wasCharging = old?.charging ?? false
        var detail: String?
        if charging, !wasCharging { detail = pct >= 100 ? "Fully charged" : "Charging" }
        else if !charging, wasCharging, old != nil { detail = "Unplugged" }
        else if charging, pct >= 100, (old?.battery ?? 0) < 100 { detail = "Fully charged" }
        else if !charging, pct <= 20, (old?.battery ?? 100) > 20 || old == nil { detail = "Low battery" }
        else if old == nil { detail = "Connected to Notch" }
        guard let detail else { return nil }
        return Moment(kind: .iphone, left: .symbol(d.symbol), right: .battery(pct, charging: charging),
                      title: "\(d.name) \(pct)%", detail: detail, duration: pct <= 20 && !charging ? 5 : 3.5)
    }

    static func moment(for e: BridgeEvent) -> Moment {
        Moment(kind: .bridge, left: .symbol(e.symbol ?? "iphone"), right: .none, title: e.title, detail: e.body,
               duration: 5, action: e.url.map { .open($0) }, actionHint: e.url != nil ? "Click to open" : nil)
    }

    // MARK: - Debug

    /// `--demo-moment=audio|clipboard|airdrop|focus|hotspot|calendar|iphone|event`
    func debugDemo(_ kind: String) {
        switch kind {
        case "audio": audio.debugDemo()
        case "clipboard": clipboard.debugDemo()
        case "airdrop": airdrop.debugDemo()
        case "focus": focus.debugDemo()
        case "hotspot": hotspot.debugDemo()
        case "calendar": calendar.debugDemo()
        case "iphone": bridge.debugDemo()
        default: emit(Self.moment(for: BridgeEvent(title: "Timer", body: "Pasta is ready", symbol: "timer", url: nil)))
        }
    }
}
