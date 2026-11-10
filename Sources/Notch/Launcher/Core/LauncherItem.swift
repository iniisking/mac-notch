import AppKit
import SwiftUI

/// What a row shows on its left.
enum LauncherIcon {
    case app(URL)
    case file(URL)
    case symbol(String, Color)
    case image(NSImage)
    case emoji(String)
    case color(NSColor)
    case bundle(String)
    case text(String)
}

/// Optional right-hand preview (clipboard, snippets, files).
enum LauncherPreview {
    case text(String, monospaced: Bool = false)
    case image(NSImage)
    case files([URL])
    case color(NSColor, String)
}

/// One thing the selected row can do. The first action runs on ↩, the second on ⌘↩, all of them
/// are listed under ⌘K.
struct LauncherAction: Identifiable {
    let id = UUID()
    var title: String
    var symbol: String
    var shortcut: String? = nil
    /// Delete-style actions are tinted red in the ⌘K list.
    var destructive = false
    var run: @MainActor (LauncherModel) -> Void
}

struct LauncherItem: Identifiable {
    var id: String
    var title: String
    var subtitle: String? = nil
    var icon: LauncherIcon
    /// Small label on the right ("Application", "Command", "2m ago").
    var accessory: String? = nil
    var section: String = "Results"
    var keywords: [String] = []
    var actions: [LauncherAction]
    var preview: LauncherPreview? = nil
    /// Learned ranking: picking an item bumps it for similar queries later.
    var learnKey: String? = nil
    /// Fixed bonus on top of the match score (e.g. calculator answers sit on top).
    var boost: Double = 0
    var score: Double = 0
    /// Running it from a hotkey has to open the launcher (it switches mode, prefills the search,
    /// or asks for a second ↩).
    var needsPanel = false
    /// Filled in for display: the item's own global hotkey and alias.
    var hotkey: String? = nil
    var alias: String? = nil
}

// MARK: - Matching

enum FuzzyMatch {
    /// 0 = no match. Higher is better: exact > prefix > word prefix > acronym > substring > subsequence.
    static func score(_ query: String, _ candidate: String) -> Double {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return 1 }
        let c = candidate.lowercased()
        if c == q { return 100 }
        if c.hasPrefix(q) { return 80 + min(10, Double(q.count) / Double(max(c.count, 1)) * 10) }
        let words = c.split(whereSeparator: { " -_./:".contains($0) }).map(String.init)
        if words.contains(where: { $0.hasPrefix(q) }) { return 65 }
        let initials = String(words.compactMap(\.first))
        if q.count >= 2, initials.hasPrefix(q) { return 60 }
        // camelCase initials ("vsc" → Visual Studio Code is above; "Xcode" etc.)
        if c.contains(q) { return 45 }
        // Every query word must prefix some candidate word ("sys set" → System Settings).
        let qWords = q.split(separator: " ").map(String.init)
        if qWords.count > 1, qWords.allSatisfy({ qw in words.contains { $0.hasPrefix(qw) } }) { return 55 }
        // Subsequence, scored by how tight it is.
        var idx = c.startIndex
        var gaps = 0
        var last: String.Index?
        for ch in q where ch != " " {
            guard let found = c[idx...].firstIndex(of: ch) else { return 0 }
            if let l = last, c.index(after: l) != found { gaps += 1 }
            last = found
            idx = c.index(after: found)
        }
        return max(5, 30 - Double(gaps) * 4)
    }

    static func best(_ query: String, title: String, keywords: [String]) -> Double {
        var s = score(query, title)
        for k in keywords { s = max(s, score(query, k) * 0.85) }
        return s
    }
}

/// Remembers what was picked for which query (count + recency) so frequent choices float up.
@MainActor
final class Frecency {
    static let shared = Frecency()
    private struct Entry: Codable { var count: Double; var last: Date }
    private var entries: [String: Entry]
    private let key = "launcherFrecency"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let e = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = e
        } else {
            entries = [:]
        }
    }

    func bump(_ item: String) {
        var e = entries[item] ?? Entry(count: 0, last: Date())
        e.count += 1
        e.last = Date()
        entries[item] = e
        if entries.count > 600 {
            // Forget the weakest.
            let weakest = entries.sorted { bonus(for: $0.value) < bonus(for: $1.value) }.prefix(100).map(\.key)
            weakest.forEach { entries[$0] = nil }
        }
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: key) }
    }

    func bonus(_ item: String) -> Double {
        guard let e = entries[item] else { return 0 }
        return bonus(for: e)
    }

    private func bonus(for e: Entry) -> Double {
        let days = Date().timeIntervalSince(e.last) / 86_400
        let recency = days < 1 ? 1.0 : days < 7 ? 0.7 : days < 30 ? 0.4 : 0.15
        return min(30, log2(e.count + 1) * 8 * recency)
    }

    /// Most used keys with a given prefix (e.g. "emoji:"), best first.
    func top(prefix: String, limit: Int) -> [String] {
        entries.filter { $0.key.hasPrefix(prefix) }
            .sorted { bonus(for: $0.value) > bonus(for: $1.value) }
            .prefix(limit).map(\.key)
    }
}

// MARK: - Icons

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(forFile url: URL) -> NSImage {
        if let hit = cache[url.path] { return hit }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        if cache.count > 800 { cache.removeAll() }
        cache[url.path] = img
        return img
    }
}

struct LauncherIconView: View {
    let icon: LauncherIcon
    var size: CGFloat = 22

    var body: some View {
        switch icon {
        case .app(let url), .file(let url):
            Image(nsImage: IconCache.icon(forFile: url)).resizable().interpolation(.high)
                .frame(width: size, height: size)
        case .bundle(let id):
            AppIconView(bundleID: id, size: size)
        case .symbol(let name, let color):
            Image(systemName: name)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(color.gradient))
        case .image(let img):
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        case .emoji(let e):
            Text(e).font(.system(size: size * 0.82)).frame(width: size, height: size)
        case .color(let c):
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Color(nsColor: c))
                .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(.white.opacity(0.25)))
                .frame(width: size, height: size)
        case .text(let t):
            Text(t).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(.white.opacity(0.14)))
        }
    }
}

/// Launcher palette (shared with symbol tiles).
enum LauncherColors {
    static let gray = Color(white: 0.38)
    static let blue = Color(red: 0.2, green: 0.5, blue: 1)
    static let indigo = Color(red: 0.36, green: 0.36, blue: 0.9)
    static let purple = Color(red: 0.62, green: 0.4, blue: 0.95)
    static let pink = Color(red: 0.95, green: 0.3, blue: 0.55)
    static let red = Color(red: 0.95, green: 0.3, blue: 0.28)
    static let orange = Color(red: 0.98, green: 0.55, blue: 0.15)
    static let yellow = Color(red: 0.95, green: 0.75, blue: 0.1)
    static let green = Color(red: 0.2, green: 0.75, blue: 0.4)
    static let teal = Color(red: 0.15, green: 0.7, blue: 0.75)
    static let brown = Color(red: 0.62, green: 0.45, blue: 0.3)
}
