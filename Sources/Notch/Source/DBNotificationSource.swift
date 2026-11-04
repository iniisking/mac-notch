import Foundation

/// Reads the Notification Center SQLite DB (read-only) and reports new rows.
/// Works with Focus mode on, because usernoted still records silenced notifications.
final class DBNotificationSource: NotificationSource {
    var onEvent: ((NotificationSourceEvent) -> Void)?

    private let queue = DispatchQueue(label: "com.theajstars.notch.db", qos: .utility)
    private let dbURL: URL
    private var db: NCDatabase?
    private var cursor: Int64 = 0
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var pollTimer: DispatchSourceTimer?
    private var retryTimer: DispatchSourceTimer?
    private var checkScheduled = false
    private var running = false
    private var lastStatus: SourceStatus?

    private static let cursorKey = "DBNotificationSource.lastSeenRecID"
    private let pollInterval: TimeInterval = 1.5
    private let historySeed = 40

    init(url: URL = NCDatabase.defaultURL) {
        self.dbURL = url
    }

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.emit(.status(.starting))
            self.connect()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.teardown()
        }
    }

    /// Forces an immediate reconnect attempt (e.g. after the user grants Full Disk Access).
    func retryNow() {
        queue.async {
            guard self.running, self.db == nil else { return }
            self.connect()
        }
    }

    // MARK: - Connection

    private func connect() {
        retryTimer?.cancel(); retryTimer = nil
        do {
            let db = try NCDatabase(url: dbURL)
            self.db = db
            NSLog("Notch: opened notification DB. %@", db.schemaSummary)
            try seed(db)
            installWatchers()
            startPolling()
            emit(.status(.running))
        } catch let error as NCDatabaseError {
            NSLog("Notch: %@", error.description)
            fail(error.isPermission ? .permissionDenied(error.description) : .unavailable(error.description))
        } catch {
            fail(.unavailable(error.localizedDescription))
        }
    }

    private func fail(_ status: SourceStatus) {
        teardown()
        emit(.status(status))
        scheduleRetry(after: 5)
    }

    private func teardown() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
        pollTimer?.cancel(); pollTimer = nil
        retryTimer?.cancel(); retryTimer = nil
        db?.close(); db = nil
    }

    private func scheduleRetry(after seconds: TimeInterval) {
        guard running else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + seconds)
        t.setEventHandler { [weak self] in
            guard let self, self.running, self.db == nil else { return }
            self.connect()
        }
        t.resume()
        retryTimer = t
    }

    private func seed(_ db: NCDatabase) throws {
        let maxID = try db.maxRecID()
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: Self.cursorKey) as? Int64
            ?? (defaults.object(forKey: Self.cursorKey) as? NSNumber)?.int64Value

        // Existing rows go into history only.
        let recent = try db.recent(limit: historySeed).compactMap(Self.makeNotification)
        emit(.history(recent))

        if let stored, stored < maxID {
            // Rows that arrived while we weren't running: flash only the very fresh ones.
            let missed = try db.records(after: stored).compactMap(Self.makeNotification)
            let fresh = missed.filter { Date().timeIntervalSince($0.date) < 60 }
            if !fresh.isEmpty { emit(.arrived(fresh, live: true)) }
        }
        // First launch (or the DB was reset): just seed, don't replay.
        cursor = maxID
        defaults.set(NSNumber(value: maxID), forKey: Self.cursorKey)
    }

    // MARK: - Change detection

    private func installWatchers() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
        for path in [dbURL.path, dbURL.path + "-wal"] {
            let fd = Darwin.open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: queue)
            src.setEventHandler { [weak self, weak src] in
                guard let self, let src else { return }
                if !src.data.intersection([.delete, .rename]).isEmpty {
                    // File replaced (e.g. WAL checkpoint/reset): re-arm shortly.
                    self.queue.asyncAfter(deadline: .now() + 1) { if self.db != nil { self.installWatchers() } }
                }
                self.scheduleCheck()
            }
            src.setCancelHandler { Darwin.close(fd) }
            src.resume()
            watchers.append(src)
        }
    }

    private func startPolling() {
        pollTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        pollTimer = t
    }

    private func scheduleCheck() {
        guard !checkScheduled else { return }
        checkScheduled = true
        // Small debounce: usernoted writes db + wal in bursts.
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.checkScheduled = false
            self?.check()
        }
    }

    private func check() {
        guard running, let db else { return }
        do {
            let rows = try db.records(after: cursor)
            if let maxRow = rows.map(\.recID).max() {
                cursor = maxRow
                UserDefaults.standard.set(NSNumber(value: cursor), forKey: Self.cursorKey)
            } else {
                // Detect a reset DB (rec_ids went backwards).
                let maxID = try db.maxRecID()
                if maxID < cursor { cursor = maxID }
            }
            let items = rows.compactMap(Self.makeNotification)
            if !items.isEmpty { emit(.arrived(items, live: true)) }
        } catch let error as NCDatabaseError {
            NSLog("Notch: poll failed: %@", error.description)
            fail(error.isPermission ? .permissionDenied(error.description) : .unavailable(error.description))
        } catch {
            fail(.unavailable(error.localizedDescription))
        }
    }

    // MARK: - Helpers

    private static func makeNotification(_ row: NCRawRecord) -> NotchNotification? {
        guard let data = row.data, let p = NCPayload.decode(data), !p.isEmpty else { return nil }
        let bundle = row.bundleID ?? p.bundleID ?? "unknown"
        return NotchNotification(
            id: row.uuid.map { "nc-\($0)" } ?? "nc-rec-\(row.recID)",
            recID: row.recID, bundleID: bundle,
            title: p.title, subtitle: p.subtitle, body: p.body, threadID: p.threadID,
            date: row.deliveredDate ?? p.date ?? Date())
    }

    private func emit(_ event: NotificationSourceEvent) {
        if case .status(let s) = event {
            guard s != lastStatus else { return }
            lastStatus = s
        }
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
}
