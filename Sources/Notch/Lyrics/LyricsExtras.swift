import CryptoKit
import Foundation
import NaturalLanguage
import Translation

// MARK: - Romanization (offline)

/// Latin-script readings for non-Latin lyric lines. Japanese uses the system tokenizer's
/// readings (so kanji read as Japanese, not as Mandarin pinyin); everything else uses ICU's
/// Any-Latin transform (pinyin with tones, Revised-Romanization-ish Korean, Cyrillic, Greek, …).
enum LyricsRomanizer {
    static func romanize(_ lines: [String]) -> [Int: String] {
        let japanese = LyricsLanguage.detect(lines) == .japanese
        var out: [Int: String] = [:]
        for (i, line) in lines.enumerated() where needsRomanization(line) {
            let r = japanese ? japaneseReading(line) : anyLatin(line)
            let clean = r.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty, clean != line { out[i] = clean }
        }
        return out
    }

    /// True when the line has letters outside Latin / Latin Extended.
    static func needsRomanization(_ s: String) -> Bool {
        s.unicodeScalars.contains { u in
            u.properties.isAlphabetic && !(u.value < 0x250 || (0x1E00...0x1EFF).contains(u.value))
        }
    }

    private static func anyLatin(_ s: String) -> String {
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, kCFStringTransformToLatin, false)
        return m as String
    }

    private static func japaneseReading(_ s: String) -> String {
        let cf = s as CFString
        let len = CFStringGetLength(cf)
        guard let tok = CFStringTokenizerCreate(nil, cf, CFRange(location: 0, length: len),
                                                kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale)
        else { return anyLatin(s) }
        var parts: [String] = []
        while CFStringTokenizerAdvanceToNextToken(tok) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            let original = (s as NSString).substring(with: NSRange(location: r.location, length: r.length))
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription) as? String,
               !latin.isEmpty {
                parts.append(latin)
            } else {
                parts.append(needsRomanization(original) ? anyLatin(original) : original)
            }
        }
        return parts.isEmpty ? anyLatin(s) : parts.joined(separator: " ")
    }
}

enum LyricsLanguage {
    /// The song's dominant language, from all its lines together.
    static func detect(_ lines: [String]) -> NLLanguage? {
        let text = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(text)
        return r.dominantLanguage
    }
}

// MARK: - Translation (on-device, Apple Translation)

struct TranslationNote: Error {
    let message: String
}

/// Translates lyric lines into the Mac's language with Apple's on-device Translation framework.
/// Results are cached on disk next to the lyrics cache. Needs macOS 26 and the language pair
/// downloaded in System Settings › General › Language & Region › Translation Languages.
enum LyricsTranslator {
    private static let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notch/lyrics/translations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    @MainActor
    static func translate(_ lines: [String]) async -> Result<[Int: String], TranslationNote> {
        guard #available(macOS 26.0, *) else {
            return .failure(TranslationNote(message: "Translation needs macOS 26"))
        }
        // Songs already in your language (or undetectable) get no second line and no note.
        guard let detected = LyricsLanguage.detect(lines) else { return .success([:]) }
        let target = Locale.current.language
        let source = Locale.Language(identifier: detected.rawValue)
        if source.languageCode == target.languageCode { return .success([:]) }
        let name = Locale.current.localizedString(forIdentifier: detected.rawValue) ?? detected.rawValue
        let targetName = target.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0.identifier) } ?? "your language"

        let cacheFile = cacheDir.appendingPathComponent(cacheKey(lines, target: target) + ".json")
        if let data = try? Data(contentsOf: cacheFile),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            return .success(Dictionary(uniqueKeysWithValues: saved.compactMap { k, v in Int(k).map { ($0, v) } }))
        }

        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
        case .installed:
            break
        case .supported:
            return .failure(TranslationNote(message: "Download \(name) → \(targetName) in Settings › Language & Region › Translation"))
        case .unsupported:
            return .failure(TranslationNote(message: "\(name) → \(targetName) translation isn't available"))
        @unknown default:
            return .failure(TranslationNote(message: "Translation unavailable"))
        }

        // Translate each distinct line once (choruses repeat).
        var unique: [String] = []
        var seen = Set<String>()
        for l in lines where !l.isEmpty && !seen.contains(l) { seen.insert(l); unique.append(l) }
        do {
            let session = TranslationSession(installedSource: source, target: target)
            let requests = unique.enumerated().map {
                TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
            }
            let responses = try await session.translations(from: requests)
            var byText: [String: String] = [:]
            for r in responses {
                guard let id = r.clientIdentifier, let k = Int(id), k < unique.count else { continue }
                byText[unique[k]] = r.targetText
            }
            var out: [Int: String] = [:]
            for (i, l) in lines.enumerated() {
                if let t = byText[l], !t.isEmpty, t != l { out[i] = t }
            }
            let encoded = Dictionary(uniqueKeysWithValues: out.map { (String($0.key), $0.value) })
            if let data = try? JSONEncoder().encode(encoded) { try? data.write(to: cacheFile, options: .atomic) }
            return .success(out)
        } catch {
            DebugLog.write("translation failed: \(error)")
            return .failure(TranslationNote(message: "Translation failed"))
        }
    }

    private static func cacheKey(_ lines: [String], target: Locale.Language) -> String {
        let raw = lines.joined(separator: "\n") + "|" + target.maximalIdentifier
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
}
