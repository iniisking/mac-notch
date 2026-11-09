import Combine
import Foundation
import IOBluetooth

/// A connected Bluetooth headset / speaker and its battery levels (any may be nil).
struct AudioDevice: Equatable, Identifiable {
    var id: String          // Bluetooth address
    var name: String
    var symbol: String      // SF Symbol: airpodspro, airpodsmax, beats.headphones, headphones, …
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var single: Int?

    /// Lowest bud (or the single battery) — what the wing shows.
    var headline: Int? {
        let buds = [left, right].compactMap { $0 }
        return buds.min() ?? single
    }

    var batteryDetail: String {
        var parts: [String] = []
        if let l = left { parts.append("L \(l)%") }
        if let r = right { parts.append("R \(r)%") }
        if let c = caseLevel { parts.append("Case \(c)%") }
        if parts.isEmpty, let s = single { parts.append("\(s)%") }
        return parts.joined(separator: " · ")
    }
}

/// Watches Bluetooth audio devices (AirPods, Beats, other headphones) connecting and disconnecting.
/// Connect notifications are public IOBluetooth; per-bud and case battery come from IOBluetoothDevice
/// selectors that aren't in the headers (`batteryPercentLeft/Right/Case/Single`), read only when the
/// object responds to them. Needs Bluetooth permission (macOS asks once).
@MainActor
final class AudioDeviceMonitor: NSObject, ObservableObject {
    @Published private(set) var devices: [AudioDevice] = []
    /// A device just connected (after its battery had a moment to report).
    let connected = PassthroughSubject<AudioDevice, Never>()

    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    private var started = Date()
    private var refreshTimer: Timer?
    private var enabled = false

    func start() {
        guard !enabled else { return }
        enabled = true
        started = Date()
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        // Battery levels change slowly; refresh the visible list once a minute.
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
        refreshAll()
    }

    func stop() {
        enabled = false
        connectNote?.unregister()
        connectNote = nil
        disconnectNotes.values.forEach { $0.unregister() }
        disconnectNotes.removeAll()
        refreshTimer?.invalidate()
        refreshTimer = nil
        devices = []
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        MainActor.assumeIsolated { handleConnect(device) }
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        MainActor.assumeIsolated {
            let id = device.addressString ?? ""
            disconnectNotes.removeValue(forKey: id)?.unregister()
            devices.removeAll { $0.id == id }
            DebugLog.write("bluetooth: disconnected \(device.name ?? id)")
        }
    }

    private func handleConnect(_ device: IOBluetoothDevice) {
        guard enabled, Self.isAudio(device), let id = device.addressString else { return }
        if disconnectNotes[id] == nil {
            disconnectNotes[id] = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        }
        // IOBluetooth replays devices that were already connected when we registered: list them quietly.
        let isLaunch = Date().timeIntervalSince(started) < 3
        upsert(Self.read(device))
        guard !isLaunch else { return }
        DebugLog.write("bluetooth: connected \(device.name ?? id)")
        // Battery levels arrive a second or two after the connection.
        var announced = false
        for delay in [1.2, 2.5, 4.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !announced, device.isConnected() else { return }
                let d = Self.read(device)
                self.upsert(d)
                if d.headline != nil || delay >= 4.5 {
                    announced = true
                    self.connected.send(d)
                }
            }
        }
    }

    private func upsert(_ d: AudioDevice) {
        if let i = devices.firstIndex(where: { $0.id == d.id }) {
            if devices[i] != d { devices[i] = d }
        } else {
            devices.append(d)
        }
    }

    private func refreshAll() {
        guard enabled else { return }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let live = paired.filter { $0.isConnected() && Self.isAudio($0) }
        for dev in live {
            if let id = dev.addressString, disconnectNotes[id] == nil {
                disconnectNotes[id] = dev.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
            }
        }
        let fresh = live.map(Self.read)
        if fresh != devices { devices = fresh }
    }

    // MARK: - Reading

    private static func isAudio(_ d: IOBluetoothDevice) -> Bool {
        if d.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio) { return true }
        let n = (d.name ?? "").lowercased()
        return n.contains("airpods") || n.contains("beats") || n.contains("buds")
    }

    private static func battery(_ d: IOBluetoothDevice, _ key: String) -> Int? {
        guard d.responds(to: NSSelectorFromString(key)),
              let v = (d.value(forKey: key) as? NSNumber)?.intValue, v > 0, v <= 100 else { return nil }
        return v
    }

    static func read(_ d: IOBluetoothDevice) -> AudioDevice {
        AudioDevice(id: d.addressString ?? UUID().uuidString,
                    name: d.name ?? "Headphones",
                    symbol: symbol(for: d),
                    left: battery(d, "batteryPercentLeft"),
                    right: battery(d, "batteryPercentRight"),
                    caseLevel: battery(d, "batteryPercentCase"),
                    single: battery(d, "batteryPercentSingle") ?? battery(d, "batteryPercentCombined"))
    }

    private static func symbol(for d: IOBluetoothDevice) -> String {
        let n = (d.name ?? "").lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        if n.contains("buds") { return "earbuds" }
        // Minor class 0x06 = headphones, 0x01 = wearable headset; speakers otherwise.
        switch d.deviceClassMinor {
        case 0x01, 0x06: return "headphones"
        default: return "hifispeaker.fill"
        }
    }

    // MARK: - Debug

    func debugDemo() {
        let d = AudioDevice(id: "demo", name: "AirPods Pro", symbol: "airpodspro", left: 82, right: 79, caseLevel: 54)
        upsert(d)
        connected.send(d)
    }
}
