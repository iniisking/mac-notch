import AppKit
import Combine
import Network

/// Latest state an iPhone / iPad / Watch reported through the bridge.
struct BridgedDevice: Equatable, Identifiable {
    var name: String
    var battery: Int?
    var charging: Bool?
    var lowPower: Bool?
    var updated: Date
    var id: String { name.lowercased() }

    var symbol: String {
        let n = name.lowercased()
        if n.contains("ipad") { return "ipad" }
        if n.contains("watch") { return "applewatch" }
        return "iphone"
    }
}

/// A free-form event pushed from a Shortcut ("Timer done", "Arrived home", …).
struct BridgeEvent: Equatable {
    var title: String
    var body: String
    var symbol: String?
    var url: URL?
}

/// Tiny HTTP endpoint on the local network so iPhone Shortcuts automations can push state to the
/// notch: battery level / charging (Shortcuts "When battery level…" / "When charger connected"),
/// or any message. Off by default. Every request needs the token (query `?token=` or
/// `Authorization: Bearer`). Advertised over Bonjour as `_notch._tcp`.
///
///     POST http://<mac>.local:7766/v1/device?token=…   {"name":"iPhone","battery":54,"charging":true}
///     POST http://<mac>.local:7766/v1/event?token=…    {"title":"Timer","body":"Pasta is ready","symbol":"timer"}
///     GET  http://<mac>.local:7766/v1/ping?token=…
@MainActor
final class DeviceBridge: ObservableObject {
    static let port: UInt16 = 7766

    @Published private(set) var devices: [BridgedDevice] = []
    @Published private(set) var status = "Off"
    @Published private(set) var lastRequest: Date?
    let deviceChanged = PassthroughSubject<(old: BridgedDevice?, new: BridgedDevice), Never>()
    let events = PassthroughSubject<BridgeEvent, Never>()

    private let settings: SettingsStore
    private var listener: NWListener?
    private var cancellables = Set<AnyCancellable>()

    init(settings: SettingsStore) {
        self.settings = settings
        settings.$bridgeEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in on ? self?.start() : self?.stop() }
            .store(in: &cancellables)
    }

    /// `http://Name.local:7766`
    var baseURL: String {
        let host = (Host.current().name ?? ProcessInfo.processInfo.hostName)
        let local = host.hasSuffix(".local") ? host : (host.split(separator: ".").first.map(String.init) ?? host) + ".local"
        return "http://\(local):\(Self.port)"
    }

    private func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.service = NWListener.Service(name: "Notch", type: "_notch._tcp")
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch state {
                        case .ready: self?.status = "Listening on port \(Self.port)"
                        case .failed(let e): self?.status = "Failed: \(e.localizedDescription)"; self?.listener = nil
                        case .cancelled: self?.status = "Off"
                        default: break
                        }
                    }
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.accept(conn) } }
            }
            l.start(queue: .main)
            listener = l
            DebugLog.write("bridge: listening on \(Self.port)")
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        status = "Off"
    }

    // MARK: - HTTP

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, buffer: Data())
        // Drop idle / slow connections.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { conn.cancel() }
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    var buf = buffer
                    if let data { buf.append(data) }
                    if buf.count > 256 * 1024 { conn.cancel(); return }
                    if let req = HTTPRequest(buf) {
                        let (code, body) = self.handle(req)
                        self.respond(conn, code: code, json: body)
                    } else if done || error != nil {
                        conn.cancel()
                    } else {
                        self.receive(conn, buffer: buf)
                    }
                }
            }
        }
    }

    private func respond(_ conn: NWConnection, code: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][code] ?? "OK"
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func handle(_ req: HTTPRequest) -> (Int, [String: Any]) {
        let token = req.query["token"] ?? req.headers["authorization"].map {
            $0.replacingOccurrences(of: "Bearer ", with: "", options: [.caseInsensitive, .anchored])
        }
        guard let token, !settings.bridgeToken.isEmpty, token == settings.bridgeToken else {
            DebugLog.write("bridge: rejected request without a valid token")
            return (401, ["ok": false, "error": "bad token"])
        }
        lastRequest = Date()
        let json = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
        // Shortcuts can also send form fields / query items instead of JSON.
        var fields = req.query.merging(req.form) { a, _ in a }
        for (k, v) in json { fields[k] = "\(v)" }

        switch req.path {
        case "/v1/ping":
            return (200, ["ok": true, "name": "Notch"])
        case "/v1/device":
            let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? "iPhone"
            let battery = fields["battery"].flatMap(Self.percent)
            let device = BridgedDevice(name: name, battery: battery,
                                       charging: fields["charging"].flatMap(Self.bool),
                                       lowPower: fields["lowpower"].flatMap(Self.bool) ?? fields["lowPower"].flatMap(Self.bool),
                                       updated: Date())
            let old = devices.first { $0.id == device.id }
            devices.removeAll { $0.id == device.id }
            devices.insert(device, at: 0)
            DebugLog.write("bridge: \(name) battery=\(battery.map(String.init) ?? "-") charging=\(device.charging.map { "\($0)" } ?? "-")")
            deviceChanged.send((old, device))
            return (200, ["ok": true])
        case "/v1/event":
            let title = fields["title"] ?? ""
            let body = fields["body"] ?? fields["text"] ?? ""
            guard !title.isEmpty || !body.isEmpty else { return (400, ["ok": false, "error": "title or body required"]) }
            events.send(BridgeEvent(title: title.isEmpty ? body : title, body: title.isEmpty ? "" : body,
                                    symbol: fields["symbol"], url: fields["url"].flatMap(URL.init(string:))))
            return (200, ["ok": true])
        default:
            return (404, ["ok": false, "error": "unknown path"])
        }
    }

    /// "54", "54%", "0.54" (Shortcuts' battery level is 0–100, but be lenient).
    private static func percent(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "% "))
        guard let v = Double(t.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let pct = v <= 1 && t.contains(".") ? v * 100 : v
        return max(0, min(100, Int(pct.rounded())))
    }

    private static func bool(_ s: String) -> Bool? {
        switch s.lowercased().trimmingCharacters(in: .whitespaces) {
        case "1", "true", "yes", "on", "charging", "connected": return true
        case "0", "false", "no", "off", "unplugged", "disconnected": return false
        default: return nil
        }
    }

    // MARK: - Debug

    func debugDemo() {
        let d = BridgedDevice(name: "iPhone", battery: 18, charging: false, updated: Date())
        let old = devices.first
        devices = [d]
        deviceChanged.send((old, d))
    }
}

/// Just enough HTTP/1.1 parsing for small Shortcuts requests. Returns nil until the whole body
/// (per Content-Length) has arrived.
private struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    var form: [String: String] {
        guard headers["content-type"]?.contains("application/x-www-form-urlencoded") == true,
              let s = String(data: body, encoding: .utf8) else { return [:] }
        return Self.parseQuery(s)
    }

    init?(_ data: Data) {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        method = String(first[0])
        var hs: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let c = line.firstIndex(of: ":") else { continue }
            hs[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        headers = hs
        let target = String(first[1])
        let comps = URLComponents(string: target)
        path = comps?.path ?? target
        var q: [String: String] = [:]
        comps?.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
        query = q
        let length = Int(hs["content-length"] ?? "0") ?? 0
        let bodyStart = sep.upperBound
        guard data.count - bodyStart >= length else { return nil }
        body = data.subdata(in: bodyStart..<(bodyStart + length))
    }

    static func parseQuery(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            if let k = kv.first { out[k] = kv.count > 1 ? kv[1] : "" }
        }
        return out
    }
}
