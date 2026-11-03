import Foundation

// The opt-in second currency: dollars always, plus one more at a live rate. Off until you turn it on
// (Usage window toolbar → Currency); off means no network call at all. The rate comes from Frankfurter
// (api.frankfurter.dev: free, keyless, HTTPS) at most once a day, and is kept with its date, so an
// offline Mac shows the last rate it had and says from when. Guide: docs/usage-window.md.

/// The currencies offered next to dollars, Indian rupees first (the default). Every code here is in
/// Frankfurter's answer (checked 2026-11-03), and one request asks for all of them, so the request does
/// not say which one you picked and switching needs no new one.
enum Currencies {
    struct Info: Identifiable, Equatable {
        let code: String
        let name: String
        /// As written before an amount: "₹", "€", "CA$", "CHF".
        let symbol: String
        /// Minor units shown under 1,000 (0 for yen and won).
        var decimals = 2
        var id: String { code }
    }

    static let offered: [Info] = [
        Info(code: "INR", name: "Indian Rupee", symbol: "₹"),
        Info(code: "EUR", name: "Euro", symbol: "€"),
        Info(code: "GBP", name: "British Pound", symbol: "£"),
        Info(code: "JPY", name: "Japanese Yen", symbol: "¥", decimals: 0),
        Info(code: "CNY", name: "Chinese Yuan", symbol: "CN¥"),
        Info(code: "KRW", name: "South Korean Won", symbol: "₩", decimals: 0),
        Info(code: "CAD", name: "Canadian Dollar", symbol: "CA$"),
        Info(code: "AUD", name: "Australian Dollar", symbol: "A$"),
        Info(code: "SGD", name: "Singapore Dollar", symbol: "S$"),
        Info(code: "HKD", name: "Hong Kong Dollar", symbol: "HK$"),
        Info(code: "CHF", name: "Swiss Franc", symbol: "CHF"),
        Info(code: "SEK", name: "Swedish Krona", symbol: "SEK"),
        Info(code: "BRL", name: "Brazilian Real", symbol: "R$"),
        Info(code: "MXN", name: "Mexican Peso", symbol: "MX$"),
        Info(code: "ZAR", name: "South African Rand", symbol: "ZAR"),
        Info(code: "AED", name: "UAE Dirham", symbol: "AED"),
    ]
    static let defaultCode = "INR"

    static func info(_ code: String) -> Info? { offered.first { $0.code == code } }
}

/// How an amount in the second currency is written.
enum CurrencyFormat {
    /// Indian rupees in the Indian short scale (₹91.2K, ₹8.26L, ₹1.2Cr); every other currency the usual
    /// way, like the dollars beside it ("€11.42", "¥1,903", "CA$1,284").
    static func amount(_ v: Double, code: String) -> String {
        let info = Currencies.info(code) ?? Currencies.Info(code: code, name: code, symbol: code)
        if code == "INR" { return info.symbol + indian(v) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        let digits = abs(v) >= 1000 ? 0 : info.decimals
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        let number = f.string(from: NSNumber(value: abs(v))) ?? String(format: "%.\(digits)f", abs(v))
        // A symbol made of letters gets a space ("CHF 12.40"); "€12.40", "CA$12.40" do not.
        let gap = info.symbol.last?.isLetter == true ? " " : ""
        return (v < 0 ? "-" : "") + info.symbol + gap + number
    }

    /// "37.80", "845", "9.12K", "91.2K", "8.26L", "82.6L", "1.2Cr", "1,240Cr": three significant digits
    /// from a thousand up, trailing zeros dropped.
    static func indian(_ v: Double) -> String {
        let a = abs(v), sign = v < 0 ? "-" : ""
        func short(_ x: Double) -> String {
            var s = String(format: "%.\(x < 10 ? 2 : x < 100 ? 1 : 0)f", x)
            if s.contains(".") {
                while s.hasSuffix("0") { s.removeLast() }
                if s.hasSuffix(".") { s.removeLast() }
            }
            return s
        }
        if a < 100 { return sign + String(format: "%.2f", a) }
        if a < 1_000 { return sign + String(format: "%.0f", a) }
        if a < 100_000 { return sign + short(a / 1_000) + "K" }
        if a < 10_000_000 { return sign + short(a / 100_000) + "L" }
        let crore = a / 10_000_000
        if crore < 1_000 { return sign + short(crore) + "Cr" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_IN")
        f.maximumFractionDigits = 0
        return sign + (f.string(from: NSNumber(value: crore.rounded())) ?? String(format: "%.0f", crore)) + "Cr"
    }

    /// "₹ at 94.12 (3 Nov)": the symbol, the rate for one dollar and the day it is for.
    static func rateLine(code: String, perUSD: Double, date: Date, calendar: Calendar = .current) -> String {
        let symbol = Currencies.info(code)?.symbol ?? code
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = perUSD < 1 ? 4 : 2
        f.maximumFractionDigits = perUSD < 1 ? 4 : 2
        let d = DateFormatter()
        d.calendar = calendar
        d.timeZone = calendar.timeZone
        d.locale = Locale(identifier: "en_GB")
        d.setLocalizedDateFormatFromTemplate(calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? "d MMM" : "d MMM yyyy")
        return "\(symbol) at \(f.string(from: NSNumber(value: perUSD)) ?? String(perUSD)) (\(d.string(from: date)))"
    }
}

/// The rates last fetched, kept between launches with the day each is for.
struct RateTable: Codable, Equatable {
    struct Rate: Codable, Equatable {
        /// Units of the currency for one US dollar.
        var perUSD: Double
        /// The day the rate is for, as the service states it ("2026-11-02"); a weekend or holiday keeps
        /// the last working day's.
        var date: String
    }
    /// When we got the answer (our clock).
    var fetched: Date
    var rates: [String: Rate]
}

/// When a request may go out. A day that got an answer gets no other; a request that failed (offline,
/// the service down) waits an hour before the next try. Pure, for the self-test.
enum RateRule {
    static let retryAfter: TimeInterval = 3600

    static func shouldFetch(table: RateTable?, lastAttempt: Date?, now: Date, calendar: Calendar) -> Bool {
        if let t = table, calendar.isDate(t.fetched, inSameDayAs: now) || t.fetched > now { return false }
        if let a = lastAttempt, now.timeIntervalSince(a) < retryAfter, a <= now { return false }
        return true
    }

    /// "2026-11-02" as a calendar day (its start, in `calendar`'s time zone).
    static func day(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// Frankfurter's v2 API: blended mid-market rates from central banks, free for any use, no key, HTTPS.
/// Its FAQ (frankfurter.dev, read 2026-11-03): no quotas, caching encouraged, and it "doesn't collect or
/// log personal data, IP addresses, or request URLs"; it runs behind Cloudflare.
enum Frankfurter {
    static let host = "api.frankfurter.dev"

    /// The one request: every offered currency against the dollar.
    static func url(codes: [String] = Currencies.offered.map(\.code)) -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.path = "/v2/rates"
        c.queryItems = [URLQueryItem(name: "base", value: "USD"), URLQueryItem(name: "quotes", value: codes.sorted().joined(separator: ","))]
        return c.url!
    }

    /// `[{"date":"2026-11-02","base":"USD","quote":"INR","rate":94.94}, …]`. nil when nothing usable came back.
    static func parse(_ data: Data, codes: Set<String>) -> [String: RateTable.Rate]? {
        struct Row: Decodable { let date: String; let base: String; let quote: String; let rate: Double }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }
        var out: [String: RateTable.Rate] = [:]
        for r in rows where r.base == "USD" && codes.contains(r.quote) && r.rate.isFinite && r.rate > 0
            && r.date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            out[r.quote] = .init(perUSD: r.rate, date: r.date)
        }
        return out.isEmpty ? nil : out
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// One GET, no cookies, no cache on disk, our own short user agent.
    static func fetch(_ codes: [String]) async throws -> [String: RateTable.Rate] {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": "ClawsSearch", "Accept": "application/json"]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url(codes: codes))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure(description: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let rates = parse(data, codes: Set(codes)) else { throw Failure(description: "no rates in the answer") }
        return rates
    }
}

/// Where the setting and the rates are kept: the helper's own UserDefaults, or memory (the demo, tests).
protocol SettingStore: AnyObject {
    func value(_ key: String) -> Any?
    func set(_ value: Any?, _ key: String)
}

extension UserDefaults: SettingStore {
    func value(_ key: String) -> Any? { object(forKey: key) }
    func set(_ value: Any?, _ key: String) { if let value { set(value, forKey: key) } else { removeObject(forKey: key) } }
}

final class MemoryStore: SettingStore {
    var values: [String: Any] = [:]
    init(_ values: [String: Any] = [:]) { self.values = values }
    func value(_ key: String) -> Any? { values[key] }
    func set(_ value: Any?, _ key: String) { values[key] = value }
}

/// The second-currency setting and its rate: what `UsageModel.second` follows, so Search and the Usage
/// window change together. Starts off and in memory, with no way to reach the network; the window's
/// launch (`useDefaults`) connects it to the helper's UserDefaults and Frankfurter, `--demo` to made-up
/// rates (`useDemo`).
@MainActor
final class SecondCurrencySetting: ObservableObject {
    static let shared = SecondCurrencySetting()

    enum Key {
        static let code = "secondCurrency"          // ISO code; absent = off
        static let lastCode = "secondCurrencyLast"  // what turning it on again picks
        static let rates = "exchangeRates"          // RateTable as JSON
        static let attempt = "exchangeRatesAttempt" // Date of the last request
    }

    /// nil = dollars only.
    @Published private(set) var code: String?
    @Published private(set) var table: RateTable?
    @Published private(set) var fetching = false
    /// Why the last request failed, until one succeeds.
    @Published private(set) var problem: String?
    /// The currency and rate to show, when on and a rate is known.
    @Published private(set) var active: UsageModel.SecondCurrency?
    @Published private(set) var isDemo = false

    typealias Fetcher = @Sendable ([String]) async throws -> [String: RateTable.Rate]
    /// nil: never asks the network (the default, the demo, snapshots).
    private(set) var fetcher: Fetcher?
    private(set) var store: SettingStore
    var now: () -> Date = Date.init
    var calendar = Calendar.current
    /// How many requests went out: the self-test counts them.
    private(set) var requests = 0

    init(store: SettingStore = MemoryStore(), fetcher: Fetcher? = nil) {
        self.store = store
        self.fetcher = fetcher
        load()
    }

    /// The window's own launch: your setting and the cached rates, and Frankfurter for new ones.
    func useDefaults(_ defaults: SettingStore, fetcher: Fetcher?) {
        store = defaults
        self.fetcher = fetcher
        isDemo = false
        load()
        refreshIfNeeded()
    }

    /// `--demo`: made-up fixed rates dated today, nothing stored, nothing fetched.
    func useDemo(code: String? = nil) {
        store = MemoryStore()
        fetcher = nil
        isDemo = true
        let day = Self.dayText(now(), calendar: calendar)
        let made: [String: Double] = ["INR": 90, "EUR": 0.9, "GBP": 0.75, "JPY": 150, "CNY": 7, "KRW": 1300, "CAD": 1.4,
                                      "AUD": 1.5, "SGD": 1.3, "HKD": 7.8, "CHF": 0.85, "SEK": 10, "BRL": 5.5, "MXN": 18,
                                      "ZAR": 17, "AED": 3.67]
        table = RateTable(fetched: now(), rates: made.mapValues { .init(perUSD: $0, date: day) })
        self.code = code.flatMap { Currencies.info($0) != nil ? $0 : nil }
        problem = nil
        recompute()
    }

    var lastCode: String { (store.value(Key.lastCode) as? String).flatMap { Currencies.info($0)?.code } ?? Currencies.defaultCode }

    /// Turns it on with `code`, or off with nil. Turning it on may fetch today's rate.
    func set(_ new: String?) {
        let valid = new.flatMap { Currencies.info($0)?.code }
        if valid != code {
            code = valid
            if !isDemo {
                store.set(valid, Key.code)
                if let valid { store.set(valid, Key.lastCode) }
            }
            recompute()
        }
        refreshIfNeeded()
    }

    /// At most once a day, only while on, only with a fetcher (`RateRule`).
    func refreshIfNeeded() {
        guard code != nil, let fetcher, !fetching else { return }
        let lastAttempt = store.value(Key.attempt) as? Date
        guard RateRule.shouldFetch(table: table, lastAttempt: lastAttempt, now: now(), calendar: calendar) else { return }
        let started = now()
        store.set(started, Key.attempt)
        fetching = true
        requests += 1
        let codes = Currencies.offered.map(\.code)
        Task { [weak self] in
            do {
                let rates = try await fetcher(codes)
                self?.finish(.success(rates), at: started)
            } catch {
                self?.finish(.failure(error), at: started)
            }
        }
    }

    private func finish(_ result: Result<[String: RateTable.Rate], Error>, at started: Date) {
        fetching = false
        switch result {
        case .success(let rates):
            // Keep any currency the answer left out from the last table.
            let merged = (table?.rates ?? [:]).merging(rates) { $1 }
            table = RateTable(fetched: started, rates: merged)
            if let data = try? JSONEncoder().encode(table) { store.set(data, Key.rates) }
            problem = nil
        case .failure(let error):
            problem = (error as? Frankfurter.Failure)?.description ?? error.localizedDescription
        }
        recompute()
    }

    /// What the menu says about the rate.
    var statusLine: String {
        guard let code else { return "Dollars only. Turn on a second currency to fetch a rate once a day." }
        if isDemo { return "Demo: a made-up rate, nothing fetched." }
        if let a = active {
            let line = CurrencyFormat.rateLine(code: code, perUSD: a.perUSD, date: a.date, calendar: calendar)
            return problem == nil ? line : line + ", the last rate fetched (offline)"
        }
        if fetching { return "Fetching today's rate…" }
        if let problem { return "No rate yet: \(problem). Dollars only for now." }
        return "No rate yet."
    }

    private func load() {
        code = (store.value(Key.code) as? String).flatMap { Currencies.info($0)?.code }
        table = (store.value(Key.rates) as? Data).flatMap { try? JSONDecoder().decode(RateTable.self, from: $0) }
        problem = nil
        recompute()
    }

    private func recompute() {
        let next: UsageModel.SecondCurrency? = code.flatMap { c in
            guard let r = table?.rates[c], let day = RateRule.day(r.date, calendar: calendar) else { return nil }
            return UsageModel.SecondCurrency(code: c, perUSD: r.perUSD, date: day)
        }
        if next != active { active = next }
    }

    static func dayText(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// `ClawsSearch --currency-status`: the setting and the cached rates, from the helper's defaults; no
/// network. `ClawsSearch --fetch-rates`: one request to Frankfurter, the answer printed, nothing stored.
enum RateCLI {
    @MainActor
    static func status() -> Int32 {
        let s = SecondCurrencySetting(store: UserDefaults.standard)
        print("second currency: \(s.code ?? "off")")
        print(s.statusLine)
        if let t = s.table {
            print("cached rates fetched \(t.fetched.formatted(date: .abbreviated, time: .shortened)):")
            for (code, r) in t.rates.sorted(by: { $0.key < $1.key }) { print("  \(code) \(r.perUSD) (\(r.date))") }
        }
        if let a = s.store.value(SecondCurrencySetting.Key.attempt) as? Date { print("last request: \(a.formatted())") }
        return 0
    }

    @MainActor
    static func fetch() -> Int32 {
        let s = SecondCurrencySetting(store: MemoryStore(), fetcher: Frankfurter.fetch)
        print("GET \(Frankfurter.url())")
        s.set(Currencies.defaultCode)
        let start = Date()
        while s.fetching && Date().timeIntervalSince(start) < 20 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        print(s.statusLine)
        for (code, r) in (s.table?.rates ?? [:]).sorted(by: { $0.key < $1.key }) {
            print("  \(code) \(r.perUSD) (\(r.date))  $12.40 = \(CurrencyFormat.amount(12.4 * r.perUSD, code: code))")
        }
        return s.active == nil ? 1 : 0
    }
}

extension UsageModel {
    /// The second currency alone ("₹1.17K"), when it is on.
    func secondMoney(_ usd: Double) -> String? {
        second.map { CurrencyFormat.amount(usd * $0.perUSD, code: $0.code) }
    }

    /// "₹ at 94.12 (3 Nov)", when it is on.
    var rateLine: String? {
        second.map { CurrencyFormat.rateLine(code: $0.code, perUSD: $0.perUSD, date: $0.date) }
    }
}
