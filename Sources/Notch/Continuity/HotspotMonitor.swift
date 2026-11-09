import Combine
import CoreWLAN
import Foundation
import Network

/// Personal Hotspot: the Mac is online over Wi-Fi that the system marks as expensive, which is
/// what an iPhone / iPad hotspot looks like (USB tethering is also expensive, on a wired interface).
@MainActor
final class HotspotMonitor: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var networkName: String?
    let changed = PassthroughSubject<Bool, Never>()

    private var monitor: NWPathMonitor?
    private var first = true

    func start() {
        guard monitor == nil else { return }
        first = true
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let on = path.status == .satisfied && path.isExpensive
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.update(on) }
            }
        }
        m.start(queue: DispatchQueue(label: "notch.hotspot"))
        monitor = m
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        active = false
    }

    private func update(_ on: Bool) {
        // The SSID needs Location permission on recent macOS; fine if it's nil.
        networkName = on ? CWWiFiClient.shared().interface()?.ssid() : nil
        guard on != active else { first = false; return }
        active = on
        if !first {
            DebugLog.write("hotspot: \(on ? "connected" : "disconnected")")
            changed.send(on)
        }
        first = false
    }

    func debugDemo() {
        active = true
        networkName = "iPhone"
        changed.send(true)
    }
}
