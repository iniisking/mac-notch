import AppKit
import CoreText

/// Emoji from the bundled Unicode list (emoji.json: names, CLDR keywords, groups and skin-tone
/// variants), plus symbols and kaomoji.
@MainActor
final class EmojiStore {
    struct Emoji: Decodable, Hashable {
        let e: String
        let n: String
        let g: Int
        let v: Double?
        let k: String?
        let t: [String]?

        func with(tone: Int) -> String {
            guard tone > 0, let t, t.count == 5 else { return e }
            return t[tone - 1]
        }
    }

    struct Section: Identifiable {
        let id: String
        let title: String
        let items: [GridCell]
    }

    /// A cell in the emoji grid (emoji or symbol).
    struct GridCell: Identifiable, Hashable {
        let id: String
        let glyph: String
        let name: String
        /// Base emoji (for remembering use independent of skin tone).
        let base: String
    }

    private(set) var groups: [String] = []
    private(set) var all: [Emoji] = []
    private var loaded = false

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        struct File: Decodable { let groups: [String]; let emoji: [Emoji] }
        guard let url = Bundle.main.url(forResource: "emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            DebugLog.write("emoji.json missing from the app bundle")
            return
        }
        groups = file.groups
        // The bundled list can be newer than this Mac's emoji font: drop what it can't draw.
        all = file.emoji.filter { ($0.v ?? 0) < 13 || Self.renders($0.e) }
    }

    /// True when Apple Color Emoji draws the sequence as a single glyph (no tofu, no split ZWJ parts).
    static func renders(_ s: String) -> Bool {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)
        let attr = NSAttributedString(string: s, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attr)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], runs.count == 1 else { return false }
        let run = runs[0]
        guard CTRunGetGlyphCount(run) == 1 else { return false }
        var glyph = CGGlyph()
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        return glyph != 0 && (CTFontCopyPostScriptName(runFont) as String).contains("AppleColorEmoji")
    }

    static let groupSymbols = ["face.smiling", "hand.wave", "leaf", "fork.knife", "car", "soccerball", "lightbulb", "heart", "flag", "command"]

    func sections(query: String, tone: Int) -> [Section] {
        loadIfNeeded()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            let scored: [(GridCell, Double)] = all.compactMap { em in
                var s = FuzzyMatch.score(q, em.n)
                if s < 60, let k = em.k {
                    // Keyword hit: any keyword word starting with every query word.
                    let words = k.split(separator: " ")
                    let qWords = q.split(separator: " ")
                    if qWords.allSatisfy({ qw in words.contains { $0.hasPrefix(qw) } }) { s = max(s, 58) }
                }
                if s < 40 { return nil }   // skip loose subsequence matches for emoji
                let cell = GridCell(id: em.e, glyph: em.with(tone: tone), name: em.n, base: em.e)
                return (cell, s + Frecency.shared.bonus("emoji:\(em.e)"))
            }
            let symbols: [(GridCell, Double)] = Self.symbols.compactMap { sym in
                let s = FuzzyMatch.score(q, sym.1)
                return s >= 40 ? (GridCell(id: "sym:" + sym.0, glyph: sym.0, name: sym.1, base: sym.0), s) : nil
            }
            let cells = (scored + symbols).sorted { $0.1 > $1.1 }.map(\.0)
            return cells.isEmpty ? [] : [Section(id: "results", title: "Results", items: cells)]
        }
        var out: [Section] = []
        let recentKeys = Frecency.shared.top(prefix: "emoji:", limit: 24).map { String($0.dropFirst(6)) }
        let byGlyph = Dictionary(all.map { ($0.e, $0) }, uniquingKeysWith: { a, _ in a })
        let recents = recentKeys.compactMap { key -> GridCell? in
            if let em = byGlyph[key] { return GridCell(id: "recent:" + key, glyph: em.with(tone: tone), name: em.n, base: key) }
            if let sym = Self.symbols.first(where: { $0.0 == key }) { return GridCell(id: "recent:" + key, glyph: key, name: sym.1, base: key) }
            return nil
        }
        if !recents.isEmpty { out.append(Section(id: "recent", title: "Frequently Used", items: recents)) }
        for (i, g) in groups.enumerated() {
            let cells = all.filter { $0.g == i }.map { GridCell(id: $0.e, glyph: $0.with(tone: tone), name: $0.n, base: $0.e) }
            out.append(Section(id: "g\(i)", title: g, items: cells))
        }
        out.append(Section(id: "symbols", title: "Symbols & Keys",
                           items: Self.symbols.map { GridCell(id: "sym:" + $0.0, glyph: $0.0, name: $0.1, base: $0.0) }))
        return out
    }

    static let symbols: [(String, String)] = [
        ("⌘", "command key"), ("⌥", "option key"), ("⌃", "control key"), ("⇧", "shift key"), ("⇪", "caps lock"),
        ("↩", "return key"), ("⌫", "delete key"), ("⌦", "forward delete"), ("⎋", "escape key"), ("⇥", "tab key"),
        ("", "apple logo"), ("→", "right arrow"), ("←", "left arrow"), ("↑", "up arrow"), ("↓", "down arrow"),
        ("↔", "left right arrow"), ("⇒", "double right arrow implies"), ("⇐", "double left arrow"), ("⇔", "if and only if"),
        ("↗", "north east arrow"), ("↘", "south east arrow"), ("⤴", "arrow curving up"), ("↻", "clockwise refresh"),
        ("✓", "check mark tick"), ("✗", "ballot x cross"), ("•", "bullet"), ("·", "middle dot interpunct"), ("…", "ellipsis"),
        ("—", "em dash"), ("–", "en dash"), ("§", "section sign"), ("¶", "pilcrow paragraph"), ("†", "dagger"),
        ("©", "copyright"), ("®", "registered"), ("™", "trademark"), ("°", "degree"), ("′", "prime minutes"), ("″", "double prime seconds"),
        ("±", "plus minus"), ("×", "multiply times"), ("÷", "divide"), ("≈", "approximately"), ("≠", "not equal"),
        ("≤", "less than or equal"), ("≥", "greater than or equal"), ("∞", "infinity"), ("√", "square root"),
        ("∑", "sum sigma"), ("∏", "product pi"), ("∆", "delta increment"), ("π", "pi"), ("µ", "micro mu"), ("Ω", "ohm omega"),
        ("α", "alpha"), ("β", "beta"), ("γ", "gamma"), ("λ", "lambda"), ("θ", "theta"), ("σ", "sigma"),
        ("½", "one half"), ("⅓", "one third"), ("¼", "one quarter"), ("¾", "three quarters"),
        ("²", "superscript two squared"), ("³", "superscript three cubed"), ("‰", "per mille"),
        ("€", "euro"), ("£", "pound sterling"), ("¥", "yen yuan"), ("₦", "naira"), ("₹", "rupee"), ("₿", "bitcoin"),
        ("¢", "cent"), ("₩", "won"), ("₽", "ruble"), ("₺", "lira"),
        ("«", "left guillemet"), ("»", "right guillemet"), ("“", "left double quote"), ("”", "right double quote"),
        ("‘", "left single quote"), ("’", "right single quote apostrophe"), ("¿", "inverted question"), ("¡", "inverted exclamation"),
        ("★", "black star"), ("☆", "white star"), ("♥", "heart suit"), ("♦", "diamond suit"), ("♠", "spade suit"), ("♣", "club suit"),
        ("☀", "sun"), ("☁", "cloud"), ("☂", "umbrella"), ("♪", "music note"), ("♫", "music notes"),
        ("■", "black square"), ("□", "white square"), ("▲", "black triangle up"), ("▼", "black triangle down"),
        ("●", "black circle"), ("○", "white circle"), ("◆", "black diamond"), ("◇", "white diamond"),
        ("␣", "space symbol"), ("⏎", "return symbol"), ("⌽", "power symbol"), ("⏏", "eject"),
    ]

    static let kaomoji: [(String, String)] = [
        ("¯\\_(ツ)_/¯", "shrug"), ("(╯°□°)╯︵ ┻━┻", "table flip angry"), ("┬─┬ノ( º _ ºノ)", "put table back calm"),
        ("( ͡° ͜ʖ ͡°)", "lenny face"), ("ಠ_ಠ", "look of disapproval"), ("(づ｡◕‿‿◕｡)づ", "hug"), ("ʕ•ᴥ•ʔ", "bear"),
        ("(ノ◕ヮ◕)ノ*:･ﾟ✧", "sparkle excited magic"), ("(⌐■_■)", "deal with it sunglasses cool"), ("(•_•)", "neutral face"),
        ("( •_•)>⌐■-■", "putting on sunglasses"), ("(｡◕‿◕｡)", "happy cute"), ("(◕‿◕✿)", "flower happy"),
        ("(ᵔᴥᵔ)", "happy bear"), ("(ಥ﹏ಥ)", "crying sad"), ("(T_T)", "crying"), ("(；一_一)", "annoyed"),
        ("(¬‿¬)", "smirk"), ("(☞ﾟヮﾟ)☞", "pointing finger guns"), ("☜(ﾟヮﾟ☜)", "pointing left"),
        ("ヽ(´▽`)/", "joy hooray"), ("\\(^o^)/", "yay cheer"), ("(＾▽＾)", "smile"), ("(≧▽≦)", "excited happy"),
        ("(*^_^*)", "blush"), ("(>_<)", "frustrated"), ("(-_-)zzz", "sleeping tired"), ("(°ロ°)", "shocked surprised"),
        ("(o_O)", "confused"), ("(ʘ‿ʘ)", "wide eyed"), ("(✿◠‿◠)", "flower smile"), ("ᕕ( ᐛ )ᕗ", "happy walk"),
        ("ᕦ(ò_óˇ)ᕤ", "flex strong"), ("(ง'̀-'́)ง", "fight me"), ("(っ˘ڡ˘ς)", "yummy"), ("(=^･ω･^=)", "cat"),
        ("/ᐠ｡ꞈ｡ᐟ\\", "cat face"), ("V●ᴥ●V", "dog"), ("(・ω・)ノ", "wave hi"), ("( ´ ▽ ` )ﾉ", "wave bye"),
        ("(ﾉ´ヮ`)ﾉ*: ･ﾟ", "celebrate"), ("(｡•́︿•̀｡)", "pout sad"), ("(¬_¬)", "suspicious side eye"),
        ("(⊙_☉)", "dizzy confused"), ("♪~ ᕕ(ᐛ)ᕗ", "dance music"), ("(っ◔◡◔)っ ♥", "give love heart"),
        ("(˘▾˘~)", "dance"), ("(~˘▾˘)~", "dance right"), ("┐(￣ヘ￣)┌", "whatever"), ("(￣ー￣)", "smug"),
        ("(╥﹏╥)", "tears"), ("(¬º-°)¬", "zombie"), ("(ノಠ益ಠ)ノ彡┻━┻", "rage table flip"), ("༼ つ ◕_◕ ༽つ", "give"),
        ("(◕ᴗ◕✿)", "cute flower"), ("(ㆆ _ ㆆ)", "unimpressed"), ("(•̀ᴗ•́)و ̑̑", "determined"), ("✌(-‿-)✌", "peace"),
    ]
}
