import Foundation
import SQLite3

/// One raw row from the Notification Center `record` table.
struct NCRawRecord {
    let recID: Int64
    let bundleID: String?
    let uuid: String?
    let deliveredDate: Date?
    let data: Data?
}

/// Fields decoded from a record's binary-plist `data` blob.
struct NCPayload {
    var bundleID: String?
    var title: String = ""
    var subtitle: String = ""
    var body: String = ""
    var threadID: String?
    var date: Date?
    /// The app's own default-action URL, when it provides one (Messages: `durl`).
    var defaultURL: String?
    /// WhatsApp chat id from userInfo (`jid`), e.g. "…@lid", "…@s.whatsapp.net", "…@g.us".
    var chatJID: String?
    /// Sender's phone handle from the communication context, e.g. "+2348012345678".
    var senderPhone: String?

    var isEmpty: Bool { title.isEmpty && subtitle.isEmpty && body.isEmpty }

    /// Decodes the usernoted plist. The layout is undocumented, so every key is optional.
    static func decode(_ data: Data) -> NCPayload? {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { return nil }
        var p = NCPayload()
        p.bundleID = dict["app"] as? String
        if let d = dict["date"] as? Double { p.date = Date(timeIntervalSinceReferenceDate: d) }
        else if let d = dict["date"] as? Date { p.date = d }
        if let req = dict["req"] as? [String: Any] {
            p.title = string(req["titl"])
            p.subtitle = string(req["subt"])
            p.body = string(req["body"])
            let thread = string(req["thre"])
            p.threadID = thread.isEmpty ? nil : thread
            let durl = string(req["durl"])
            p.defaultURL = durl.isEmpty ? nil : durl
            if let usda = req["usda"] as? Data, let info = unarchive(usda) as? [String: Any] {
                let jid = string(info["jid"])
                p.chatJID = jid.isEmpty ? nil : jid
            }
            if let uncc = req["uncc"] as? Data {
                p.senderPhone = phoneHandle(inArchive: uncc)
            }
        }
        return p
    }

    private static func unarchive(_ data: Data) -> Any? {
        try? NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSDate.self, NSData.self, NSURL.self],
            from: data)
    }

    /// The communication context (`uncc`) is a keyed archive of a private class, so read its raw
    /// object table and take the first phone-number-looking string (the sender's handle).
    private static func phoneHandle(inArchive data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else { return nil }
        for case let s as String in objects {
            let digits = s.filter(\.isNumber)
            if s.range(of: #"^\+?[0-9 ()-]{7,20}$"#, options: .regularExpression) != nil, (7...15).contains(digits.count) {
                return s
            }
        }
        return nil
    }

    private static func string(_ any: Any?) -> String {
        switch any {
        case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }
}

enum NCDatabaseError: Error, CustomStringConvertible {
    case notFound(String)
    case permissionDenied(String)
    case openFailed(String)
    case schemaMismatch(String)
    case queryFailed(String)

    var isPermission: Bool {
        if case .permissionDenied = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .notFound(let s): return "Notification database not found: \(s)"
        case .permissionDenied(let s): return "Permission denied (Full Disk Access needed): \(s)"
        case .openFailed(let s): return "Could not open notification database: \(s)"
        case .schemaMismatch(let s): return "Unexpected notification database schema: \(s)"
        case .queryFailed(let s): return "Notification database query failed: \(s)"
        }
    }
}

/// Minimal read-only wrapper over the system libsqlite3 for the usernoted database.
final class NCDatabase {
    static var defaultURL: URL {
        // Non-sandboxed, so this is the real home folder.
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    }

    let url: URL
    private var db: OpaquePointer?
    private var recordColumns: Set<String> = []
    private var appColumns: Set<String> = []
    private var selectSQL = ""

    init(url: URL = NCDatabase.defaultURL) throws {
        self.url = url
        try open()
    }

    deinit { close() }

    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    private func open() throws {
        let path = url.path
        // Probe with a plain open() first: it gives a clean errno for TCC denials.
        let fd = Darwin.open(path, O_RDONLY)
        if fd < 0 {
            let err = errno
            switch err {
            case ENOENT: throw NCDatabaseError.notFound(path)
            case EPERM, EACCES: throw NCDatabaseError.permissionDenied(path)
            default: throw NCDatabaseError.openFailed(String(cString: strerror(err)))
            }
        }
        Darwin.close(fd)

        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle { sqlite3_close_v2(handle) }
            if rc == SQLITE_AUTH || rc == SQLITE_PERM { throw NCDatabaseError.permissionDenied(msg) }
            throw NCDatabaseError.openFailed(msg)
        }
        db = handle
        sqlite3_busy_timeout(handle, 250)

        recordColumns = try columns(of: "record")
        appColumns = (try? columns(of: "app")) ?? []
        guard !recordColumns.isEmpty else {
            close()
            throw NCDatabaseError.schemaMismatch("table `record` missing")
        }
        for required in ["rec_id", "data"] where !recordColumns.contains(required) {
            close()
            throw NCDatabaseError.schemaMismatch("record.\(required) missing (have: \(recordColumns.sorted().joined(separator: ", ")))")
        }
        let canJoinApp = recordColumns.contains("app_id") && appColumns.contains("app_id") && appColumns.contains("identifier")
        let delivered = recordColumns.contains("delivered_date") ? "r.delivered_date" : "NULL"
        let uuid = recordColumns.contains("uuid") ? "r.uuid" : "NULL"
        let ident = canJoinApp ? "a.identifier" : "NULL"
        let join = canJoinApp ? "LEFT JOIN app a ON a.app_id = r.app_id" : ""
        selectSQL = "SELECT r.rec_id, r.data, \(delivered), \(ident), \(uuid) FROM record r \(join)"
    }

    private func columns(of table: String) throws -> Set<String> {
        var names = Set<String>()
        try query("PRAGMA table_info(\(table))") { stmt in
            if let c = sqlite3_column_text(stmt, 1) { names.insert(String(cString: c)) }
        }
        return names
    }

    var schemaSummary: String {
        "record(\(recordColumns.sorted().joined(separator: ", "))) app(\(appColumns.sorted().joined(separator: ", ")))"
    }

    func maxRecID() throws -> Int64 {
        var value: Int64 = 0
        try query("SELECT IFNULL(MAX(rec_id), 0) FROM record") { value = sqlite3_column_int64($0, 0) }
        return value
    }

    /// Rows with rec_id greater than `after`, oldest first.
    func records(after: Int64, limit: Int = 200) throws -> [NCRawRecord] {
        var rows: [NCRawRecord] = []
        try query("\(selectSQL) WHERE r.rec_id > ? ORDER BY r.rec_id ASC LIMIT ?", bind: { stmt in
            sqlite3_bind_int64(stmt, 1, after)
            sqlite3_bind_int64(stmt, 2, Int64(limit))
        }) { rows.append(Self.row($0)) }
        return rows
    }

    /// The newest `limit` rows, newest first.
    func recent(limit: Int) throws -> [NCRawRecord] {
        var rows: [NCRawRecord] = []
        try query("\(selectSQL) ORDER BY r.rec_id DESC LIMIT ?", bind: { sqlite3_bind_int64($0, 1, Int64(limit)) }) {
            rows.append(Self.row($0))
        }
        return rows
    }

    private static func row(_ stmt: OpaquePointer) -> NCRawRecord {
        let recID = sqlite3_column_int64(stmt, 0)
        var data: Data?
        if let blob = sqlite3_column_blob(stmt, 1) {
            data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 1)))
        }
        var delivered: Date?
        if sqlite3_column_type(stmt, 2) != SQLITE_NULL {
            delivered = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))
        }
        var bundle: String?
        if let c = sqlite3_column_text(stmt, 3) { bundle = String(cString: c) }
        var uuid: String?
        switch sqlite3_column_type(stmt, 4) {
        case SQLITE_BLOB:
            let n = Int(sqlite3_column_bytes(stmt, 4))
            if n == 16, let p = sqlite3_column_blob(stmt, 4) {
                let b = p.assumingMemoryBound(to: UInt8.self)
                uuid = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                                   b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])).uuidString
            }
        case SQLITE_TEXT:
            if let c = sqlite3_column_text(stmt, 4) { uuid = String(cString: c) }
        default: break
        }
        return NCRawRecord(recID: recID, bundleID: bundle, uuid: uuid, deliveredDate: delivered, data: data)
    }

    private func query(_ sql: String,
                       bind: ((OpaquePointer) -> Void)? = nil,
                       row: (OpaquePointer) throws -> Void) throws {
        guard let db else { throw NCDatabaseError.openFailed("database is closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            if rc == SQLITE_AUTH || rc == SQLITE_PERM { throw NCDatabaseError.permissionDenied(msg) }
            throw NCDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt)
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW { try row(stmt); continue }
            if step == SQLITE_DONE { break }
            let msg = String(cString: sqlite3_errmsg(db))
            if step == SQLITE_AUTH || step == SQLITE_PERM || step == SQLITE_CANTOPEN {
                throw NCDatabaseError.permissionDenied(msg)
            }
            throw NCDatabaseError.queryFailed(msg)
        }
    }
}
