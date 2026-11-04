import Foundation
import Combine

/// Shared state: notification history (survives rows vanishing from the DB), source status,
/// and a stream of new arrivals for the notch windows to light up.
@MainActor
final class NotificationStore: ObservableObject {
    @Published private(set) var history: [NotchNotification] = []   // newest first
    @Published private(set) var status: SourceStatus = .starting

    /// Live, un-muted arrivals. Each notch window queues these for the compact state.
    let arrivals = PassthroughSubject<NotchNotification, Never>()

    private let settings: SettingsStore
    private let maxHistory = 100
    private let historyURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()
    private var saveWork: DispatchWorkItem?

    init(settings: SettingsStore) {
        self.settings = settings
        load()
    }

    func handle(_ event: NotificationSourceEvent) {
        switch event {
        case .status(let s):
            status = s
        case .history(let items):
            merge(items)
        case .arrived(let items, let live):
            for item in items {
                let isNew = !history.contains { $0.id == item.id }
                insert(item)
                if live, isNew, !settings.isMuted(item.bundleID) { arrivals.send(item) }
            }
        }
    }

    /// Injects a fake notification so the UI can be checked without real notifications.
    func injectTest() {
        let item = NotchNotification.test()
        insert(item)
        arrivals.send(item)
    }

    func dismiss(_ id: NotchNotification.ID) {
        history.removeAll { $0.id == id }
        scheduleSave()
    }

    func clearAll() {
        history.removeAll()
        scheduleSave()
    }

    /// Visible history, with muted apps filtered out.
    var visibleHistory: [NotchNotification] {
        history.filter { !settings.isMuted($0.bundleID) }
    }

    /// Bundle ids we've seen, for the mute list.
    var knownBundleIDs: [String] {
        Array(Set(history.map(\.bundleID))).sorted()
    }

    // MARK: - Private

    private func insert(_ item: NotchNotification) {
        history.removeAll { $0.id == item.id }
        history.insert(item, at: 0)
        history.sort { $0.date > $1.date }
        if history.count > maxHistory { history.removeLast(history.count - maxHistory) }
        scheduleSave()
    }

    private func merge(_ items: [NotchNotification]) {
        var byID = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for item in items { byID[item.id] = item }
        history = Array(byID.values).sorted { $0.date > $1.date }.prefix(maxHistory).map { $0 }
        scheduleSave()
    }

    private func load() {
        guard let data = try? Data(contentsOf: historyURL),
              let items = try? JSONDecoder().decode([NotchNotification].self, from: data) else { return }
        history = items.filter { !$0.isTest }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = history.filter { !$0.isTest }
        let url = historyURL
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }
}
