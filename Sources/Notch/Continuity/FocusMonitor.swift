import Combine
import Foundation

struct FocusMode: Equatable {
    var identifier: String
    var name: String
    var symbol: String
}

/// Current Focus, which iCloud syncs between iPhone, iPad and Mac, so turning on Driving or Sleep
/// on the phone shows up here. Read from `~/Library/DoNotDisturb/DB` (needs Full Disk Access;
/// undocumented JSON, parsed loosely): `Assertions.json` holds manually enabled modes and
/// `ModeConfigurations.json` their names and symbols. Scheduled Focus without a manual toggle
/// isn't listed there and isn't detected.
@MainActor
final class FocusMonitor: ObservableObject {
    @Published private(set) var active: FocusMode?
    /// (old, new) after a change, nil meaning off.
    let changed = PassthroughSubject<(FocusMode?, FocusMode?), Never>()

    private let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB")
    private var timer: Timer?
    private var lastStamp: Date?
    private var modes: [String: FocusMode] = [:]
    private var first = true

    func start() {
        guard timer == nil else { return }
        first = true
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        active = nil
        lastStamp = nil
    }

    private func poll() {
        let assertions = dir.appendingPathComponent("Assertions.json")
        let stamp = (try? assertions.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard stamp != lastStamp || first else { return }
        lastStamp = stamp
        guard let data = try? Data(contentsOf: assertions),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            if first { DebugLog.write("focus: can't read Assertions.json (Full Disk Access?)") }
            first = false
            return
        }
        loadModes()
        var ids: [String] = []
        Self.collect(json, key: "assertionDetailsModeIdentifier", into: &ids)
        let new = ids.first.map { id in
            modes[id] ?? FocusMode(identifier: id, name: Self.fallbackName(id), symbol: "moon.fill")
        }
        let old = active
        if new != old {
            active = new
            if !first {
                DebugLog.write("focus: \(old?.name ?? "off") -> \(new?.name ?? "off")")
                changed.send((old, new))
            }
        }
        first = false
    }

    private func loadModes() {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("ModeConfigurations.json")),
              let json = try? JSONSerialization.jsonObject(with: data) else { return }
        var found: [[String: Any]] = []
        Self.collectDicts(json, having: "modeIdentifier", into: &found)
        for d in found {
            guard let id = d["modeIdentifier"] as? String else { continue }
            let name = (d["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.fallbackName(id)
            let symbol = (d["symbolImageName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "moon.fill"
            modes[id] = FocusMode(identifier: id, name: name, symbol: symbol)
        }
    }

    private static func fallbackName(_ id: String) -> String {
        switch id {
        case "com.apple.donotdisturb.mode.default": return "Do Not Disturb"
        case "com.apple.sleep.sleep-mode": return "Sleep"
        case "com.apple.donotdisturb.mode.driving": return "Driving"
        case "com.apple.focus.work": return "Work"
        case "com.apple.focus.personal-time": return "Personal"
        case "com.apple.focus.reduce-interruptions": return "Reduce Interruptions"
        default: return id.split(separator: ".").last.map { String($0).capitalized } ?? "Focus"
        }
    }

    private static func collect(_ obj: Any, key: String, into out: inout [String]) {
        if let d = obj as? [String: Any] {
            if let v = d[key] as? String { out.append(v) }
            d.values.forEach { collect($0, key: key, into: &out) }
        } else if let a = obj as? [Any] {
            a.forEach { collect($0, key: key, into: &out) }
        }
    }

    private static func collectDicts(_ obj: Any, having key: String, into out: inout [[String: Any]]) {
        if let d = obj as? [String: Any] {
            if d[key] != nil { out.append(d) }
            d.values.forEach { collectDicts($0, having: key, into: &out) }
        } else if let a = obj as? [Any] {
            a.forEach { collectDicts($0, having: key, into: &out) }
        }
    }

    func debugDemo() {
        let old = active
        let new = FocusMode(identifier: "com.apple.donotdisturb.mode.driving", name: "Driving", symbol: "car.fill")
        active = new
        changed.send((old, new))
    }
}
