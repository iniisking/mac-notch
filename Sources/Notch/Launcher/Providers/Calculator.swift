import AppKit
import Foundation

/// Inline answers for the launcher: arithmetic, unit conversion, currency, and time zones.
@MainActor
final class Calculator {
    struct Answer {
        var result: String
        var detail: String
        /// The plain value to copy/paste (no thousands separators).
        var copyValue: String
    }

    let currency = CurrencyRates()

    func answer(_ raw: String) -> Answer? {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        if let a = timeZoneAnswer(q) { return a }
        if let a = conversion(q) { return a }
        if let a = percentOf(q) { return a }
        // Plain maths: needs an operator or function so typing "2024" doesn't become a "calculation".
        let hasOperator = q.contains(where: { "+-*/^×÷%()".contains($0) }) || q.contains(" x ")
            || ["sqrt", "sin", "cos", "tan", "log", "ln", "abs", "round", "floor", "ceil", "pi"].contains(where: { q.lowercased().contains($0) })
        guard hasOperator, let v = MathParser.evaluate(q), v.isFinite else { return nil }
        return Answer(result: Self.format(v), detail: q, copyValue: Self.plain(v))
    }

    // MARK: Formatting

    static func format(_ v: Double, maxFraction: Int = 10) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = abs(v) >= 1e15 ? 0 : maxFraction
        f.usesGroupingSeparator = true
        if abs(v) >= 1e21 || (abs(v) < 1e-9 && v != 0) {
            f.numberStyle = .scientific
            f.maximumFractionDigits = 6
        }
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func plain(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        var s = String(format: "%.10f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: "20% of 150", "150 + 20%"

    private func percentOf(_ q: String) -> Answer? {
        let lower = q.lowercased()
        if let r = lower.range(of: "% of ") {
            guard let p = MathParser.evaluate(String(lower[..<r.lowerBound])),
                  let base = MathParser.evaluate(String(lower[r.upperBound...])) else { return nil }
            let v = p / 100 * base
            return Answer(result: Self.format(v), detail: q, copyValue: Self.plain(v))
        }
        // "150 + 20%" / "150 - 15%"
        let pattern = #"^(.+?)\s*([+\-])\s*([\d.]+)\s*%$"#
        if let m = lower.firstMatch(pattern), m.count == 4,
           let base = MathParser.evaluate(m[1]), let p = Double(m[3]) {
            let v = m[2] == "+" ? base * (1 + p / 100) : base * (1 - p / 100)
            return Answer(result: Self.format(v), detail: q, copyValue: Self.plain(v))
        }
        return nil
    }

    // MARK: Units and currency: "5 km to mi", "100 usd in ngn", "72f to c", "$50 to eur"

    private func conversion(_ q: String) -> Answer? {
        var lower = q.lowercased()
        for (sym, code) in [("$", "usd "), ("€", "eur "), ("£", "gbp "), ("₦", "ngn "), ("¥", "jpy "), ("₹", "inr ")] {
            if lower.hasPrefix(sym) {
                // "$50 to eur" → "50 usd to eur"
                let rest = lower.dropFirst(sym.count)
                let num = rest.prefix { $0.isNumber || $0 == "." || $0 == "," }
                lower = num + " " + code + rest.dropFirst(num.count)
            }
        }
        let pattern = #"^([\d.,]+(?:\s*[*/x+\-]\s*[\d.,]+)*)\s*([a-zA-Z°/²³ ]+?)\s+(?:to|in|as|=|->)\s+([a-zA-Z°/²³ ]+)$"#
        let pattern2 = #"^([\d.,]+)\s*([a-zA-Z°/²³]+)\s*(?:to|in|as|->)\s*([a-zA-Z°/²³]+)$"#
        guard let m = lower.firstMatch(pattern) ?? lower.firstMatch(pattern2), m.count == 4 else { return nil }
        let numText = m[1].replacingOccurrences(of: ",", with: "")
        guard let value = MathParser.evaluate(numText) else { return nil }
        let fromKey = m[2].trimmingCharacters(in: .whitespaces), toKey = m[3].trimmingCharacters(in: .whitespaces)

        if let from = Units.lookup(fromKey), let to = Units.lookup(toKey), type(of: from) == type(of: to) {
            let converted = Measurement(value: value, unit: from).converted(to: to).value
            let r = "\(Self.format(converted, maxFraction: 4)) \(Units.label(toKey, to))"
            return Answer(result: r, detail: "\(Self.format(value)) \(Units.label(fromKey, from))", copyValue: Self.plain((converted * 10_000).rounded() / 10_000))
        }
        let fromC = fromKey.uppercased(), toC = toKey.uppercased()
        if fromC.count == 3, toC.count == 3, CurrencyRates.isCode(fromC), CurrencyRates.isCode(toC) {
            guard let rate = currency.rate(from: fromC, to: toC) else {
                currency.refresh()
                return Answer(result: "Fetching rates…", detail: "\(Self.format(value)) \(fromC) → \(toC)", copyValue: "")
            }
            let v = value * rate
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.currencyCode = toC
            f.maximumFractionDigits = v < 1 ? 4 : 2
            let r = f.string(from: NSNumber(value: v)) ?? "\(v) \(toC)"
            let updated = currency.updated.map { " · rates \($0.formatted(.relative(presentation: .named)))" } ?? ""
            return Answer(result: r, detail: "\(Self.format(value)) \(fromC) → \(toC)\(updated)",
                          copyValue: String(format: "%.2f", v))
        }
        return nil
    }

    // MARK: Time zones: "time in tokyo", "5pm lagos in pst", "now in london", "14:30 utc to wat"

    private func timeZoneAnswer(_ q: String) -> Answer? {
        let lower = q.lowercased()
        if let r = lower.range(of: #"^(?:time|now|what time is it)\s+in\s+(.+)$"#, options: .regularExpression) {
            let place = String(lower[r]).replacingOccurrences(of: #"^(?:time|now|what time is it)\s+in\s+"#, with: "", options: .regularExpression)
            guard let tz = TimeZones.find(place) else { return nil }
            return Answer(result: TimeZones.format(Date(), tz), detail: "Now in \(TimeZones.name(tz))",
                          copyValue: TimeZones.format(Date(), tz))
        }
        // "<time> [<zone>] to|in <zone>"
        let pattern = #"^(\d{1,2}(?::\d{2})?\s*(?:am|pm)?|noon|midnight|now)\s*([a-z/_ ]*?)\s+(?:to|in)\s+([a-z/_ ]+)$"#
        guard let m = lower.firstMatch(pattern), m.count == 4 else { return nil }
        let fromTZ = m[2].isEmpty ? TimeZone.current : TimeZones.find(m[2])
        guard let fromTZ, let toTZ = TimeZones.find(m[3]), let date = TimeZones.parseTime(m[1], in: fromTZ) else { return nil }
        let r = TimeZones.format(date, toTZ)
        return Answer(result: "\(r) \(TimeZones.name(toTZ))",
                      detail: "\(TimeZones.format(date, fromTZ)) \(TimeZones.name(fromTZ))", copyValue: r)
    }

    func item(for a: Answer, query: String) -> LauncherItem {
        LauncherItem(
            id: "calc", title: a.result, subtitle: a.detail, icon: .symbol("equal", LauncherColors.orange),
            accessory: "Calculator", section: "Calculator",
            actions: [
                LauncherAction(title: "Copy Answer", symbol: "doc.on.doc") { m in
                    PasteBack.copy(text: a.copyValue.isEmpty ? a.result : a.copyValue)
                    m.hide(toast: "Copied \(a.result)")
                },
                LauncherAction(title: "Paste Answer", symbol: "doc.on.clipboard", shortcut: "⌘↩") { m in
                    m.paste(text: a.copyValue.isEmpty ? a.result : a.copyValue)
                },
                LauncherAction(title: "Copy With Units", symbol: "textformat") { m in
                    PasteBack.copy(text: a.result); m.hide(toast: "Copied")
                },
            ],
            boost: 200)
    }
}

// MARK: - Math

/// Recursive-descent evaluator (NSExpression raises Objective-C exceptions on bad input, which
/// Swift can't catch). Supports + - * / ^ %, parentheses, unary minus, implicit "x"/"×"/"÷",
/// functions and constants.
enum MathParser {
    static func evaluate(_ s: String) -> Double? {
        var text = s.lowercased()
            .replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "**", with: "^").replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "π", with: "pi")
        text = text.replacingOccurrences(of: #"(?<=[\d)\s])x(?=[\d(\s])"#, with: "*", options: .regularExpression)
        var p = Parser(chars: Array(text.filter { !$0.isWhitespace }))
        guard let v = p.expression(), p.i == p.chars.count else { return nil }
        return v
    }

    private struct Parser {
        let chars: [Character]
        var i = 0

        mutating func peek() -> Character? { i < chars.count ? chars[i] : nil }

        mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                guard let r = term() else { return nil }
                v = c == "+" ? v + r : v - r
            }
            return v
        }

        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while let c = peek(), c == "*" || c == "/" || c == "%" {
                // "50%" at the end or before an operator means percent, not modulo.
                if c == "%" {
                    let next = i + 1 < chars.count ? chars[i + 1] : nil
                    if next == nil || "+-*/)^".contains(next!) { i += 1; v /= 100; continue }
                }
                i += 1
                guard let r = power() else { return nil }
                switch c {
                case "*": v *= r
                case "/": v /= r
                default: v = v.truncatingRemainder(dividingBy: r)
                }
            }
            return v
        }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek() == "^" {
                i += 1
                guard let e = power() else { return nil }   // right-associative
                return pow(base, e)
            }
            return base
        }

        mutating func unary() -> Double? {
            if peek() == "-" { i += 1; return unary().map { -$0 } }
            if peek() == "+" { i += 1; return unary() }
            return factorial()
        }

        mutating func factorial() -> Double? {
            guard var v = primary() else { return nil }
            while peek() == "!" {
                i += 1
                guard v >= 0, v <= 170, v == v.rounded() else { return nil }
                v = (1...max(1, Int(v))).reduce(1.0) { $0 * Double($1) }
            }
            return v
        }

        mutating func primary() -> Double? {
            guard let c = peek() else { return nil }
            if c == "(" {
                i += 1
                let v = expression()
                guard peek() == ")" else { return nil }
                i += 1
                return v
            }
            if c.isNumber || c == "." {
                var s = ""
                while let d = peek(), d.isNumber || d == "." || d == "e" && s.last?.isNumber == true && i + 1 < chars.count && (chars[i + 1].isNumber || chars[i + 1] == "-") {
                    s.append(d); i += 1
                    if d == "e", peek() == "-" { s.append("-"); i += 1 }
                }
                return Double(s)
            }
            if c.isLetter {
                var name = ""
                while let d = peek(), d.isLetter || (d.isNumber && !name.isEmpty) { name.append(d); i += 1 }
                switch name {
                case "pi": return .pi
                case "e": return M_E
                case "tau": return 2 * .pi
                default: break
                }
                guard peek() == "(" else { return nil }
                i += 1
                guard let arg = expression(), peek() == ")" else { return nil }
                i += 1
                switch name {
                case "sqrt": return sqrt(arg)
                case "cbrt": return cbrt(arg)
                case "sin": return sin(arg)
                case "cos": return cos(arg)
                case "tan": return tan(arg)
                case "asin": return asin(arg)
                case "acos": return acos(arg)
                case "atan": return atan(arg)
                case "log", "log10": return log10(arg)
                case "log2": return log2(arg)
                case "ln": return log(arg)
                case "exp": return exp(arg)
                case "abs": return abs(arg)
                case "round": return arg.rounded()
                case "floor": return floor(arg)
                case "ceil": return ceil(arg)
                default: return nil
                }
            }
            return nil
        }
    }
}

// MARK: - Units

enum Units {
    static let table: [String: Dimension] = {
        var t: [String: Dimension] = [:]
        func add(_ names: [String], _ u: Dimension) { names.forEach { t[$0] = u } }
        // Length
        add(["mm", "millimeter", "millimeters", "millimetre", "millimetres"], UnitLength.millimeters)
        add(["cm", "centimeter", "centimeters", "centimetre", "centimetres"], UnitLength.centimeters)
        add(["m", "meter", "meters", "metre", "metres"], UnitLength.meters)
        add(["km", "kilometer", "kilometers", "kilometre", "kilometres"], UnitLength.kilometers)
        add(["in", "inch", "inches", "\""], UnitLength.inches)
        add(["ft", "foot", "feet", "'"], UnitLength.feet)
        add(["yd", "yard", "yards"], UnitLength.yards)
        add(["mi", "mile", "miles"], UnitLength.miles)
        add(["nmi", "nautical mile", "nautical miles"], UnitLength.nauticalMiles)
        // Mass
        add(["mg", "milligram", "milligrams"], UnitMass.milligrams)
        add(["g", "gram", "grams"], UnitMass.grams)
        add(["kg", "kilo", "kilos", "kilogram", "kilograms"], UnitMass.kilograms)
        add(["t", "tonne", "tonnes", "metric ton"], UnitMass.metricTons)
        add(["oz", "ounce", "ounces"], UnitMass.ounces)
        add(["lb", "lbs", "pound", "pounds"], UnitMass.pounds)
        add(["st", "stone", "stones"], UnitMass.stones)
        // Temperature
        add(["c", "°c", "celsius", "centigrade"], UnitTemperature.celsius)
        add(["f", "°f", "fahrenheit"], UnitTemperature.fahrenheit)
        add(["k", "kelvin"], UnitTemperature.kelvin)
        // Volume
        add(["ml", "milliliter", "milliliters", "millilitre", "millilitres"], UnitVolume.milliliters)
        add(["l", "liter", "liters", "litre", "litres"], UnitVolume.liters)
        add(["gal", "gallon", "gallons"], UnitVolume.gallons)
        add(["qt", "quart", "quarts"], UnitVolume.quarts)
        add(["pt", "pint", "pints"], UnitVolume.pints)
        add(["cup", "cups"], UnitVolume.cups)
        add(["floz", "fl oz", "fluid ounce", "fluid ounces"], UnitVolume.fluidOunces)
        add(["tbsp", "tablespoon", "tablespoons"], UnitVolume.tablespoons)
        add(["tsp", "teaspoon", "teaspoons"], UnitVolume.teaspoons)
        // Speed
        add(["mph"], UnitSpeed.milesPerHour)
        add(["kph", "kmh", "km/h", "kmph"], UnitSpeed.kilometersPerHour)
        add(["m/s", "mps"], UnitSpeed.metersPerSecond)
        add(["knot", "knots", "kn"], UnitSpeed.knots)
        // Data (decimal, like Finder)
        add(["b", "byte", "bytes"], UnitInformationStorage.bytes)
        add(["kb", "kilobyte", "kilobytes"], UnitInformationStorage.kilobytes)
        add(["mb", "megabyte", "megabytes"], UnitInformationStorage.megabytes)
        add(["gb", "gigabyte", "gigabytes"], UnitInformationStorage.gigabytes)
        add(["tb", "terabyte", "terabytes"], UnitInformationStorage.terabytes)
        add(["kib", "kibibyte"], UnitInformationStorage.kibibytes)
        add(["mib", "mebibyte"], UnitInformationStorage.mebibytes)
        add(["gib", "gibibyte"], UnitInformationStorage.gibibytes)
        add(["bit", "bits"], UnitInformationStorage.bits)
        add(["mbit", "megabit", "megabits"], UnitInformationStorage.megabits)
        // Duration
        add(["ms", "millisecond", "milliseconds"], UnitDuration.milliseconds)
        add(["s", "sec", "secs", "second", "seconds"], UnitDuration.seconds)
        add(["min", "mins", "minute", "minutes"], UnitDuration.minutes)
        add(["h", "hr", "hrs", "hour", "hours"], UnitDuration.hours)
        add(["day", "days"], UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400)))
        add(["week", "weeks", "wk"], UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800)))
        // Area
        add(["m2", "m²", "sqm"], UnitArea.squareMeters)
        add(["km2", "km²"], UnitArea.squareKilometers)
        add(["ft2", "ft²", "sqft"], UnitArea.squareFeet)
        add(["acre", "acres"], UnitArea.acres)
        add(["ha", "hectare", "hectares"], UnitArea.hectares)
        // Energy
        add(["j", "joule", "joules"], UnitEnergy.joules)
        add(["kj", "kilojoule", "kilojoules"], UnitEnergy.kilojoules)
        add(["cal", "kcal", "calorie", "calories"], UnitEnergy.kilocalories)
        add(["kwh"], UnitEnergy.kilowattHours)
        return t
    }()

    static func lookup(_ key: String) -> Dimension? { table[key.lowercased()] }

    static func label(_ typed: String, _ unit: Dimension) -> String {
        if unit is UnitTemperature { return unit.symbol }
        return typed.count <= 4 ? typed : unit.symbol
    }
}

// MARK: - Currency

/// Daily exchange rates from open.er-api.com (free, no key; ECB plus many other currencies,
/// including NGN). Cached on disk, refreshed when older than 12 hours.
@MainActor
final class CurrencyRates {
    private(set) var rates: [String: Double] = [:]   // per 1 USD
    private(set) var updated: Date?
    private var fetching = false
    var enabled = true
    var onUpdate: (() -> Void)?
    private let file = LauncherSettings.supportDirectory.appendingPathComponent("rates.json")

    private struct Cache: Codable { var rates: [String: Double]; var updated: Date }

    static let codes: Set<String> = Set(Locale.commonISOCurrencyCodes)
    static func isCode(_ s: String) -> Bool { codes.contains(s) }

    init() {
        if let c = JSONFile.load(Cache.self, from: file) {
            rates = c.rates
            updated = c.updated
        }
    }

    func rate(from: String, to: String) -> Double? {
        if Date().timeIntervalSince(updated ?? .distantPast) > 12 * 3600 { refresh() }
        guard let f = from == "USD" ? 1 : rates[from], let t = to == "USD" ? 1 : rates[to], f > 0 else { return nil }
        return t / f
    }

    func refresh() {
        guard enabled, !fetching else { return }
        fetching = true
        var req = URLRequest(url: URL(string: "https://open.er-api.com/v6/latest/USD")!)
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { data, _, _ in
            struct Response: Decodable { let rates: [String: Double] }
            let parsed = data.flatMap { try? JSONDecoder().decode(Response.self, from: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fetching = false
                    guard let parsed else { return }
                    self.rates = parsed.rates
                    self.updated = Date()
                    JSONFile.save(Cache(rates: parsed.rates, updated: Date()), to: self.file)
                    self.onUpdate?()
                }
            }
        }.resume()
    }
}

// MARK: - Time zones

enum TimeZones {
    static let aliases: [String: String] = [
        "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles", "pt": "America/Los_Angeles",
        "sf": "America/Los_Angeles", "san francisco": "America/Los_Angeles", "la": "America/Los_Angeles",
        "seattle": "America/Los_Angeles", "mst": "America/Denver", "mt": "America/Denver",
        "cst": "America/Chicago", "ct": "America/Chicago", "austin": "America/Chicago", "dallas": "America/Chicago",
        "est": "America/New_York", "edt": "America/New_York", "et": "America/New_York",
        "nyc": "America/New_York", "new york": "America/New_York", "boston": "America/New_York",
        "utc": "UTC", "gmt": "GMT", "uk": "Europe/London", "bst": "Europe/London",
        "cet": "Europe/Paris", "cest": "Europe/Paris", "berlin": "Europe/Berlin", "wat": "Africa/Lagos",
        "nigeria": "Africa/Lagos", "abuja": "Africa/Lagos", "ghana": "Africa/Accra", "kenya": "Africa/Nairobi",
        "eat": "Africa/Nairobi", "cat": "Africa/Maputo", "sast": "Africa/Johannesburg", "cape town": "Africa/Johannesburg",
        "ist": "Asia/Kolkata", "india": "Asia/Kolkata", "mumbai": "Asia/Kolkata", "delhi": "Asia/Kolkata",
        "bangalore": "Asia/Kolkata", "jst": "Asia/Tokyo", "japan": "Asia/Tokyo", "kst": "Asia/Seoul",
        "korea": "Asia/Seoul", "china": "Asia/Shanghai", "beijing": "Asia/Shanghai", "sgt": "Asia/Singapore",
        "aest": "Australia/Sydney", "aedt": "Australia/Sydney", "awst": "Australia/Perth",
        "nzst": "Pacific/Auckland", "nzdt": "Pacific/Auckland", "dubai": "Asia/Dubai", "uae": "Asia/Dubai",
        "gst": "Asia/Dubai", "hkt": "Asia/Hong_Kong", "brt": "America/Sao_Paulo", "brazil": "America/Sao_Paulo",
        "msk": "Europe/Moscow", "here": TimeZone.current.identifier, "local": TimeZone.current.identifier,
    ]

    static func find(_ raw: String) -> TimeZone? {
        let q = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }
        if let id = aliases[q] { return TimeZone(identifier: id) }
        let underscored = q.replacingOccurrences(of: " ", with: "_")
        if let id = TimeZone.knownTimeZoneIdentifiers.first(where: {
            $0.lowercased().split(separator: "/").last.map(String.init) == underscored
        }) { return TimeZone(identifier: id) }
        if q.count <= 5, let tz = TimeZone(abbreviation: q.uppercased()) { return tz }
        return nil
    }

    static func parseTime(_ s: String, in tz: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let t = s.replacingOccurrences(of: " ", with: "")
        if t == "now" { return Date() }
        var hour = 0, minute = 0
        if t == "noon" { hour = 12 } else if t == "midnight" { hour = 0 } else {
            let isPM = t.hasSuffix("pm"), isAM = t.hasSuffix("am")
            let core = (isPM || isAM) ? String(t.dropLast(2)) : t
            let parts = core.split(separator: ":")
            guard let h = Int(parts.first ?? ""), h <= 24 else { return nil }
            hour = h
            minute = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            if isPM, hour < 12 { hour += 12 }
            if isAM, hour == 12 { hour = 0 }
        }
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        return cal.date(from: comps)
    }

    static func format(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = tz
        f.dateFormat = "h:mm a"
        var s = f.string(from: d)
        // Show the day when it differs from today here.
        let here = Calendar.current.component(.day, from: d)
        var cal = Calendar.current
        cal.timeZone = tz
        if cal.component(.day, from: d) != here {
            f.dateFormat = "EEE"
            s += " (\(f.string(from: d)))"
        }
        return s
    }

    static func name(_ tz: TimeZone) -> String {
        let city = tz.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? tz.identifier
        return "\(city) \(tz.abbreviation() ?? "")".trimmingCharacters(in: .whitespaces)
    }
}

extension String {
    /// Capture groups of the first regex match (index 0 = whole match).
    func firstMatch(_ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: self).map { String(self[$0]) } ?? ""
        }
    }
}
