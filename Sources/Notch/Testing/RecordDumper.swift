import Foundation

/// Debug helper: dumps the full decoded `record.data` plist of recent rows for a few apps.
enum RecordDumper {
    static func dump() {
        let out = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notch/record-dump.txt")
        var text = ""
        do {
            let db = try NCDatabase()
            let rows = try db.recent(limit: 400)
            var counts: [String: Int] = [:]
            for row in rows {
                guard let bundle = row.bundleID?.lowercased(),
                      ["net.whatsapp.whatsapp", "com.apple.mobilesms", "com.apple.mail", "ru.keepcoder.telegram"].contains(bundle),
                      counts[bundle, default: 0] < 8, let data = row.data,
                      let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                else { continue }
                counts[bundle, default: 0] += 1
                if let p = NCPayload.decode(data) {
                    text += "HINT rec \(row.recID) \(bundle): thre=\(p.threadID?.split(separator: "@").last.map(String.init) ?? "-") jid=\(p.chatJID?.split(separator: "@").last.map(String.init) ?? "-") phone=\(p.senderPhone != nil) durl=\(p.defaultURL ?? "-")\n"
                }
                text += "=== rec \(row.recID) \(bundle) ===\n" + describe(obj, indent: 0) + "\n"
            }
        } catch {
            text = "error: \(error)"
        }
        try? text.write(to: out, atomically: true, encoding: .utf8)
        DebugLog.write("record dump written")
    }

    private static func describe(_ v: Any, indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch v {
        case let d as [String: Any]:
            return d.keys.sorted().map { k in
                let child = d[k]!
                if child is [String: Any] || child is [Any] { return "\(pad)\(k):\n" + describe(child, indent: indent + 1) }
                return "\(pad)\(k): \(scalar(child))"
            }.joined(separator: "\n")
        case let a as [Any]:
            return a.enumerated().map { i, c in "\(pad)[\(i)]:\n" + describe(c, indent: indent + 1) }.joined(separator: "\n")
        default:
            return pad + scalar(v)
        }
    }

    private static func scalar(_ v: Any) -> String {
        if let d = v as? Data {
            if let un = try? NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSData.self, NSDate.self, NSURL.self],
                from: d) {
                return "<keyed archive>\n" + describe(un, indent: 3)
            }
            if let inner = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) {
                return "<plist data>\n" + describe(inner, indent: 3)
            }
            return "<data \(d.count) bytes>"
        }
        let s = "\(v)".replacingOccurrences(of: "\n", with: "⏎")
        return "(\(type(of: v))) " + (s.count > 160 ? String(s.prefix(160)) + "…" : s)
    }
}
