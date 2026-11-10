import AppKit
import Combine

struct Quicklink: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Type "<keyword> <text>" to use it straight from the search field.
    var keyword: String
    /// URL with an optional {query} placeholder, or a file / folder path.
    var url: String
    var symbol: String = "link"

    var takesQuery: Bool { url.contains("{query}") }

    func resolved(_ query: String) -> URL? {
        if url.hasPrefix("/") || url.hasPrefix("~") {
            return URL(fileURLWithPath: (url as NSString).expandingTildeInPath)
        }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? query
        return URL(string: url.replacingOccurrences(of: "{query}", with: encoded))
    }
}

@MainActor
final class QuicklinkStore: ObservableObject {
    @Published var links: [Quicklink] { didSet { JSONFile.save(links, to: Self.file) } }
    private static let file = LauncherSettings.supportDirectory.appendingPathComponent("quicklinks.json")

    static let defaults: [Quicklink] = [
        Quicklink(name: "Google", keyword: "g", url: "https://www.google.com/search?q={query}", symbol: "magnifyingglass"),
        Quicklink(name: "DuckDuckGo", keyword: "ddg", url: "https://duckduckgo.com/?q={query}", symbol: "magnifyingglass"),
        Quicklink(name: "YouTube", keyword: "yt", url: "https://www.youtube.com/results?search_query={query}", symbol: "play.rectangle.fill"),
        Quicklink(name: "GitHub", keyword: "gh", url: "https://github.com/search?q={query}", symbol: "chevron.left.forwardslash.chevron.right"),
        Quicklink(name: "Wikipedia", keyword: "wiki", url: "https://en.wikipedia.org/w/index.php?search={query}", symbol: "book"),
        Quicklink(name: "Google Maps", keyword: "maps", url: "https://www.google.com/maps/search/{query}", symbol: "map"),
        Quicklink(name: "Google Translate", keyword: "tr", url: "https://translate.google.com/?sl=auto&tl=en&text={query}", symbol: "character.bubble"),
        Quicklink(name: "Stack Overflow", keyword: "so", url: "https://stackoverflow.com/search?q={query}", symbol: "square.stack.3d.up"),
        Quicklink(name: "npm", keyword: "npm", url: "https://www.npmjs.com/search?q={query}", symbol: "shippingbox"),
        Quicklink(name: "MDN", keyword: "mdn", url: "https://developer.mozilla.org/en-US/search?q={query}", symbol: "doc.text"),
        Quicklink(name: "Apple Developer", keyword: "apple", url: "https://developer.apple.com/search/?q={query}", symbol: "apple.logo"),
        Quicklink(name: "X", keyword: "x", url: "https://x.com/search?q={query}", symbol: "bubble.left"),
    ]

    init() {
        links = JSONFile.load([Quicklink].self, from: Self.file) ?? Self.defaults
    }

    func open(_ link: Quicklink, query: String) {
        guard let url = link.resolved(query) else { return }
        NSWorkspace.shared.open(url)
    }

    /// "g cats" → the Google link with "cats".
    func keywordMatch(_ query: String) -> (Quicklink, String)? {
        guard let space = query.firstIndex(of: " ") else { return nil }
        let kw = query[..<space].lowercased()
        let rest = query[query.index(after: space)...].trimmingCharacters(in: .whitespaces)
        guard let link = links.first(where: { $0.keyword.lowercased() == kw && $0.takesQuery }) else { return nil }
        return (link, rest)
    }

    func items(query: String) -> [LauncherItem] {
        var out: [LauncherItem] = []
        if let (link, text) = keywordMatch(query) {
            var item = LauncherItem(
                id: "ql-run:\(link.id)", title: text.isEmpty ? link.name : "Search \(link.name) for “\(text)”",
                subtitle: link.url.replacingOccurrences(of: "{query}", with: text),
                icon: .symbol(link.symbol, LauncherColors.blue), accessory: "Quicklink", section: "Quicklinks",
                actions: [LauncherAction(title: "Open", symbol: "safari") { [weak self] m in
                    self?.open(link, query: text); m.hide()
                }],
                learnKey: "ql:\(link.id)", boost: 150)
            item.score = 100
            out.append(item)
        }
        for link in links {
            let s = FuzzyMatch.best(query, title: link.name, keywords: [link.keyword])
            guard s > 0 else { continue }
            var item = LauncherItem(
                id: "ql:\(link.id)", title: link.name,
                subtitle: link.takesQuery ? "Type “\(link.keyword) …” to search" : link.url,
                icon: .symbol(link.symbol, LauncherColors.blue), accessory: link.keyword, section: "Quicklinks",
                actions: [
                    LauncherAction(title: link.takesQuery ? "Search…" : "Open", symbol: "safari") { [weak self] m in
                        if link.takesQuery {
                            m.setQuery("\(link.keyword) ")
                        } else {
                            self?.open(link, query: ""); m.hide()
                        }
                    },
                    LauncherAction(title: "Edit Quicklinks…", symbol: "pencil") { m in
                        m.hide(); m.services.openSettings(.quicklinks)
                    },
                ],
                learnKey: "ql:\(link.id)")
            item.score = s * 0.9
            item.needsPanel = link.takesQuery
            out.append(item)
        }
        return out
    }

    /// Bottom-of-list "search the web for …" fallbacks.
    func fallbacks(query: String) -> [LauncherItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var out: [LauncherItem] = []
        // A typed URL or domain opens directly.
        if !q.contains(" "), q.contains("."), let u = URL(string: q.contains("://") ? q : "https://\(q)"), u.host?.contains(".") == true {
            out.append(LauncherItem(
                id: "fallback:url", title: "Open \(u.host ?? q)", subtitle: u.absoluteString,
                icon: .symbol("safari", LauncherColors.blue), accessory: "Website", section: "Use “\(q)” with…",
                actions: [LauncherAction(title: "Open", symbol: "safari") { m in NSWorkspace.shared.open(u); m.hide() }],
                boost: -20, score: 1))
        }
        for link in links.prefix(3) where link.takesQuery {
            out.append(LauncherItem(
                id: "fallback:\(link.id)", title: "Search \(link.name)", subtitle: "“\(q)”",
                icon: .symbol(link.symbol, LauncherColors.blue), accessory: link.keyword, section: "Use “\(q)” with…",
                actions: [LauncherAction(title: "Open", symbol: "safari") { [weak self] m in
                    self?.open(link, query: q); m.hide()
                }],
                boost: -50, score: 1))
        }
        return out
    }
}
