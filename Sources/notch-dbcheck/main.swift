import Foundation

// notch-dbcheck: prints the newest notifications from the Notification Center DB.
// Usage: notch-dbcheck [count]   (default 5)
// The process running this (e.g. Terminal) needs Full Disk Access.

let count = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 5
let formatter = DateFormatter()
formatter.dateStyle = .short
formatter.timeStyle = .medium

print("DB: \(NCDatabase.defaultURL.path)")
do {
    let db = try NCDatabase()
    print("Opened OK. Schema: \(db.schemaSummary)")
    print("max rec_id: \(try db.maxRecID())\n")
    let rows = try db.recent(limit: count)
    if rows.isEmpty { print("(no notifications stored)") }
    for row in rows {
        let p = row.data.flatMap(NCPayload.decode)
        let bundle = row.bundleID ?? p?.bundleID ?? "?"
        let date = (row.deliveredDate ?? p?.date).map { formatter.string(from: $0) } ?? "-"
        print("#\(row.recID)  \(date)  [\(bundle)]")
        if let p {
            if !p.title.isEmpty { print("  title:    \(p.title)") }
            if !p.subtitle.isEmpty { print("  subtitle: \(p.subtitle)") }
            if !p.body.isEmpty { print("  body:     \(p.body.replacingOccurrences(of: "\n", with: " ⏎ "))") }
        } else {
            print("  (could not decode payload, \(row.data?.count ?? 0) bytes)")
        }
        print("")
    }
    exit(0)
} catch let error as NCDatabaseError {
    FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
    if error.isPermission {
        FileHandle.standardError.write(Data("Grant Full Disk Access to the app running this command (e.g. Terminal) in System Settings › Privacy & Security › Full Disk Access.\n".utf8))
    }
    exit(error.isPermission ? 2 : 1)
} catch {
    FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
    exit(1)
}
