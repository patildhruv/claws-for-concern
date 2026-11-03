import AppKit
import Foundation

/// The Usage window's self-test: the date ranges and totals, CSV, the second currency (formats, the
/// once-a-day rule and the cache, with an injected clock and fetcher: no network), Claws' live session
/// files, the launch window, window requests, and Open in Search. Run by `SelfTest`.
enum UsageWindowTests {
    @MainActor
    static func run() -> [(String, Bool)] {
        formats() + rates() + report() + rules() + windowModel() + csv() + live() + windows() + reveal()
    }

    // MARK: Formats

    static func formats() -> [(String, Bool)] {
        let indian: [(Double, String)] = [(37.8, "37.80"), (845, "845"), (9_120, "9.12K"), (91_200, "91.2K"), (826_000, "8.26L"),
                                          (8_260_000, "82.6L"), (12_000_000, "1.2Cr"), (12_400_000_000, "1,240Cr"), (100_000, "1L"),
                                          // Rounded before the unit is chosen.
                                          (99_950, "1L"), (9_995_000, "1Cr"), (999.5, "1K"), (99.995, "100"), (99_949, "99.9K"),
                                          (9_999_500_000, "1,000Cr"), (99_999_999_999, "10,000Cr")]
        let bad = indian.filter { CurrencyFormat.indian($0.0) != $0.1 }.map { "\($0.0) -> \(CurrencyFormat.indian($0.0))" }
        let now = RateRule.day("2026-11-03")!.addingTimeInterval(12 * 3600)
        return [
            ("currency: Indian short scale (₹91.2K, ₹8.26L, ₹1.2Cr), rounded before the unit (99,950 is ₹1L)",
             bad.isEmpty && CurrencyFormat.amount(91_200, code: "INR") == "₹91.2K"),
            ("currency: a negative amount has its sign first", CurrencyFormat.amount(-3, code: "INR") == "-₹3.00"
             && CurrencyFormat.amount(-91_200, code: "INR") == "-₹91.2K" && CurrencyFormat.amount(-3, code: "EUR") == "-€3.00"
             && CurrencyFormat.amount(-0.001, code: "EUR") == "€0.00"),
            ("currency: others the usual way, like the dollars, rounded before the decimals are chosen",
             CurrencyFormat.amount(11.42, code: "EUR") == "€11.42" && CurrencyFormat.amount(1_284.4, code: "EUR") == "€1,284"
             && CurrencyFormat.amount(1_903.4, code: "JPY") == "¥1,903" && CurrencyFormat.amount(12.4, code: "CHF") == "CHF 12.40"
             && CurrencyFormat.amount(12.4, code: "CAD") == "CA$12.40" && CurrencyFormat.amount(999.995, code: "EUR") == "€1,000"
             && CurrencyFormat.amount(0.005, code: "EUR") == "€0.01"),
            ("currency: the rate line, with the service's day, in the Gregorian calendar and UTC whatever yours are",
             CurrencyFormat.rateLine(code: "INR", perUSD: 94.12, date: RateRule.day("2026-11-03")!, now: now) == "₹ at 94.12 (3 Nov)"
             && CurrencyFormat.rateLine(code: "EUR", perUSD: 0.89378, date: RateRule.day("2024-11-03")!, now: now) == "€ at 0.8938 (3 Nov 2024)"
             && RateRule.utc.identifier == .gregorian && RateRule.utc.timeZone.secondsFromGMT() == 0),
            ("currency: the service's days must be real dates", RateRule.day("2026-02-30") == nil && RateRule.day("2026-13-01") == nil
             && RateRule.day("2026-99-99") == nil && RateRule.day("4044-11-02") == nil && RateRule.day("1483-11-02") == nil
             && RateRule.day("26-11-02") == nil && RateRule.day("2026-11-02T00:00") == nil
             && RateRule.day("2028-02-29") != nil && RateRule.text(RateRule.day("2026-11-02")!) == "2026-11-02"),
            ("currency: INR is the default and first", Currencies.defaultCode == "INR" && Currencies.offered.first?.code == "INR"),
        ]
    }

    // MARK: The rate: once a day, cached with its date

    @MainActor
    static func rates() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        let codes = Set(Currencies.offered.map(\.code))
        let answer = #"[{"date":"2026-11-02","base":"USD","quote":"INR","rate":94.94},{"date":"2026-11-03","base":"USD","quote":"EUR","rate":0.89},"#
            + #"{"date":"2026-11-03","base":"EUR","quote":"GBP","rate":0.8},{"date":"2026-11-03","base":"USD","quote":"XYZ","rate":2},"#
            + #"{"date":"2026-11-03","base":"USD","quote":"JPY","rate":-1},{"date":"3 Nov","base":"USD","quote":"GBP","rate":0.74},"#
            + #"{"date":"2026-11-03","base":"USD","quote":"KRW","rate":1e300},{"date":"2026-11-03","base":"USD","quote":"CHF","rate":5e-324},"#
            + #"{"date":"2026-11-03","base":"USD","quote":"SEK","rate":0},{"date":"2026-99-99","base":"USD","quote":"AUD","rate":1.4},"#
            + #"{"date":"2026-02-30","base":"USD","quote":"CAD","rate":1.4},{"date":"2026-11-06","base":"USD","quote":"SGD","rate":1.3},"#
            + #"{"date":"2026-11-04","base":"USD","quote":"HKD","rate":7.8}]"#
        let at = RateRule.day("2026-11-03")!.addingTimeInterval(9 * 3600)
        let parsed = Frankfurter.parse(Data(answer.utf8), codes: codes, now: at)
        out.append(("rate: rows with another base, an unknown currency, an implausible rate, a date that is not real or is days ahead are dropped",
                    parsed == ["INR": .init(perUSD: 94.94, date: "2026-11-02"), "EUR": .init(perUSD: 0.89, date: "2026-11-03"),
                               "HKD": .init(perUSD: 7.8, date: "2026-11-04")]
                    && Frankfurter.parse(Data("<html>".utf8), codes: codes) == nil && Frankfurter.parse(Data("[]".utf8), codes: codes) == nil
                    && Frankfurter.plausible == 1e-4...1e6))
        let config = Frankfurter.configuration()
        out.append(("rate: one HTTPS request for every offered currency against the dollar, the same headers for everyone",
                    Frankfurter.url().absoluteString == "https://api.frankfurter.dev/v2/rates?base=USD&quotes="
                    + Currencies.offered.map(\.code).sorted().joined(separator: ",")
                    && Frankfurter.headers == ["User-Agent": "ClawsSearch", "Accept": "application/json", "Accept-Language": "en"]
                    && config.httpAdditionalHeaders as? [String: String] == Frankfurter.headers))
        out.append(("rate: 15 s without data or 20 s in all, no cookies, no cache",
                    config.timeoutIntervalForRequest == 15 && config.timeoutIntervalForResource == 20
                    && config.urlCache == nil && config.httpCookieStorage == nil))
        out.append(("rate: redirects are refused", refusesRedirects()))
        let (atLimit, overLimit) = sizeCap()
        out.append(("rate: the answer is read up to 64 KB, more fails", atLimit == Frankfurter.maxBytes && overLimit))

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let t0 = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9, minute: 30))!
        let table = RateTable(fetched: t0, rates: ["INR": .init(perUSD: 94, date: "2026-11-02")])
        out.append(("rate: never twice on the same day, again the next day",
                    !RateRule.shouldFetch(table: table, lastAttempt: t0, now: t0.addingTimeInterval(8 * 3600), calendar: cal)
                    && RateRule.shouldFetch(table: table, lastAttempt: t0, now: t0.addingTimeInterval(15 * 3600), calendar: cal)))
        out.append(("rate: a failed request waits an hour; rates or an attempt stored in the future are stale",
                    !RateRule.shouldFetch(table: nil, lastAttempt: t0, now: t0.addingTimeInterval(600), calendar: cal)
                    && RateRule.shouldFetch(table: nil, lastAttempt: t0, now: t0.addingTimeInterval(3_700), calendar: cal)
                    && RateRule.shouldFetch(table: table, lastAttempt: nil, now: t0.addingTimeInterval(-86_400), calendar: cal)
                    && RateRule.shouldFetch(table: table, lastAttempt: t0, now: t0.addingTimeInterval(-60), calendar: cal)))

        // The setting, with a made-up service and clock.
        final class Fake: @unchecked Sendable {
            var calls = 0
            var fail = false
            var rate = 94.94
        }
        let fake = Fake()
        let fetcher: SecondCurrencySetting.Fetcher = { codes in
            await MainActor.run { fake.calls += 1 }
            let (fail, rate) = await MainActor.run { (fake.fail, fake.rate) }
            if fail { throw Frankfurter.Failure(description: "offline") }
            return ["INR": .init(perUSD: rate, date: "2026-11-02"), "EUR": .init(perUSD: 0.89, date: "2026-11-03")]
        }
        func settle(_ s: SecondCurrencySetting) {
            let end = Date().addingTimeInterval(5)
            while s.fetching && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        let store = MemoryStore()
        var clock = t0
        let s = SecondCurrencySetting(store: store, fetcher: fetcher)
        s.now = { clock }
        s.calendar = cal
        s.refreshIfNeeded()
        out.append(("rate: off means no request at all", fake.calls == 0 && s.active == nil && s.code == nil))
        s.set("INR")
        settle(s)
        let today = RateRule.day("2026-11-02")
        out.append(("rate: turning it on fetches once; the rate carries the day the service gave",
                    fake.calls == 1 && s.active == UsageModel.SecondCurrency(code: "INR", perUSD: 94.94, date: today!)
                    && store.value(SecondCurrencySetting.Key.code) as? String == "INR" && store.value(SecondCurrencySetting.Key.rates) is Data))
        s.set("EUR")
        s.refreshIfNeeded()
        settle(s)
        out.append(("rate: another currency the same day needs no request", fake.calls == 1 && s.active?.code == "EUR" && s.active?.perUSD == 0.89))
        clock = t0.addingTimeInterval(86_400)
        fake.fail = true
        s.refreshIfNeeded()
        settle(s)
        out.append(("rate: offline the next day: one try, then the cached rate with its date",
                    fake.calls == 2 && s.active?.perUSD == 0.89 && s.statusLine.contains("offline")))
        clock = clock.addingTimeInterval(600)
        s.refreshIfNeeded()
        out.append(("rate: no retry within the hour", fake.calls == 2))
        clock = clock.addingTimeInterval(3_600)
        fake.fail = false
        fake.rate = 95.1
        s.set("INR")
        settle(s)
        out.append(("rate: an hour later it tries again and keeps the new rate", fake.calls == 3 && s.active?.perUSD == 95.1))
        let again = SecondCurrencySetting(store: store)
        out.append(("rate: the setting and the rates come back from the store, and nothing is fetched without a fetcher",
                    again.code == "INR" && again.table?.rates["INR"]?.perUSD == 95.1 && again.requests == 0))
        s.set(nil)
        out.append(("rate: off again: dollars only, the choice remembered for next time",
                    s.active == nil && store.value(SecondCurrencySetting.Key.code) == nil && s.lastCode == "INR"))
        let empty = SecondCurrencySetting(store: MemoryStore(), fetcher: { _ in throw Frankfurter.Failure(description: "offline") })
        empty.set("INR")
        settle(empty)
        out.append(("rate: offline with nothing cached: dollars only, and it says why", empty.active == nil && empty.statusLine.hasPrefix("No rate yet")))
        let demo = SecondCurrencySetting(store: MemoryStore(), fetcher: fetcher)
        let calls = fake.calls
        demo.useDemo(code: "INR")
        demo.refreshIfNeeded()
        out.append(("rate: the demo has a made-up fixed rate and never fetches", demo.active?.perUSD == 90 && fake.calls == calls && demo.isDemo))

        let model = UsageModel(store: UsageStore(root: URL(fileURLWithPath: "/nonexistent-claws-usage"), cache: nil))
        model.second = nil
        let plain = model.money(12.4)
        model.second = .init(code: "INR", perUSD: 90, date: t0)
        out.append(("money: dollars, plus the second currency when it is on", plain == "$12.40" && model.money(12.4) == "$12.40 (₹1.12K)"
                    && model.secondMoney(1000) == "₹90K"))
        model.second = .init(code: "EUR", perUSD: 0.9, date: t0)
        out.append(("money: another currency the usual way", model.money(1500) == "$1,500 (€1,350)"))
        return out
    }

    /// The redirect hook answers nil (no request is made: the task is never resumed).
    @MainActor
    static func refusesRedirects() -> Bool {
        let url = URL(string: "https://api.frankfurter.dev/v2/rates")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://elsewhere.invalid/"])!
        var result: URLRequest?? = .none
        Task { result = .some(await Frankfurter.NoRedirects().urlSession(session, task: task, willPerformHTTPRedirection: redirect,
                                                                           newRequest: URLRequest(url: URL(string: "https://elsewhere.invalid/")!))) }
        let end = Date().addingTimeInterval(2)
        while result == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return result.map { $0 == nil } ?? false
    }

    /// Exactly 64 KB is read; one byte more fails.
    @MainActor
    static func sizeCap() -> (Int, Bool) {
        func stream(_ n: Int) -> AsyncStream<UInt8> {
            AsyncStream { c in
                for _ in 0..<n { c.yield(UInt8(ascii: "x")) }
                c.finish()
            }
        }
        var got = -1, failed = false, done = 0
        Task {
            got = (try? await Frankfurter.collect(stream(Frankfurter.maxBytes)))?.count ?? -1
            do { _ = try await Frankfurter.collect(stream(Frankfurter.maxBytes + 1)) } catch { failed = true }
            done = 1
        }
        let end = Date().addingTimeInterval(10)
        while done == 0 && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return (got, failed)
    }

    // MARK: Ranges and totals

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Three made-up sessions: A on 1 and 3 Nov with Claude Code's figure (twice the estimate) and a
    /// compaction each in October and November; B on 3 Nov with a model that has no price, in another
    /// folder with the same last name; C only in September.
    static func sessions() -> [String: SessionUsage] {
        let cal = calendar
        func at(_ day: Int, _ month: Int = 11, hour: Int = 12) -> Date { cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))! }
        func day(_ key: String, est: Double?, output: Int, work: [Int: Double], lines: (Int, Int), replies: Int = 5) -> SessionUsage.Day {
            var d = SessionUsage.Day(date: key, weekday: cal.component(.weekday, from: UsageDay.date(key, cal)!))
            d.estimatedUSD = est
            d.tokens.output = output
            d.replies = replies
            for (h, s) in work { d.workSeconds[h] = s }
            d.linesAdded = lines.0
            d.linesRemoved = lines.1
            return d
        }
        var a = SessionUsage(sessionID: "aaaaaaaa-0000-4000-8000-000000000001", projectDir: "-p-alpha")
        a.folder = "/p/alpha"
        a.lastActive = at(3)
        a.models = ["claude-opus-5-5", "claude-haiku-4-5"]
        a.byModel = ["claude-opus-5-5": .init(tokens: .init(output: 300), replies: 8, estimatedUSD: 4),
                     "claude-haiku-4-5": .init(tokens: .init(output: 100), replies: 2, estimatedUSD: 1)]
        a.tokens.output = 400
        a.cost = .init(usd: 10, source: .claudeCode, estimateUSD: 5)
        a.turns.seconds = 1_800
        a.days = [day("2026-11-01", est: 2, output: 100, work: [10: 600], lines: (10, 2)),
                  day("2026-11-03", est: 3, output: 300, work: [14: 1_200], lines: (30, 5))]
        a.lines = .init(added: 80, removed: 14, source: .claudeCode)
        a.context.now = 850_000
        a.context.model = "claude-opus-5-5"
        a.context.compactions = [.init(at: at(20, 10), trigger: "manual"), .init(at: at(3), trigger: "auto")]
        var b = SessionUsage(sessionID: "bbbbbbbb-0000-4000-8000-000000000002", projectDir: "-q-alpha")
        b.folder = "/q/alpha"
        b.lastActive = at(3, hour: 9)
        b.models = ["claude-3-7-sonnet-20250219"]
        b.byModel = ["claude-3-7-sonnet-20250219": .init(tokens: .init(output: 50), replies: 3, unpricedReplies: 3)]
        b.tokens.output = 50
        b.cost = .init(usd: nil, source: .estimate, estimateUSD: nil, unpriced: ["claude-3-7-sonnet-20250219"])
        b.days = [day("2026-11-03", est: nil, output: 50, work: [9: 300], lines: (4, 0), replies: 3)]
        b.lines = .init(added: 4, removed: 0, source: .estimate)
        var c = SessionUsage(sessionID: "cccccccc-0000-4000-8000-000000000003", projectDir: "-p-gamma")
        c.folder = "/p/gamma"
        c.lastActive = at(1, 9)
        c.models = ["claude-sonnet-5"]
        c.byModel = ["claude-sonnet-5": .init(tokens: .init(output: 70), replies: 4, estimatedUSD: 0.5)]
        c.tokens.output = 70
        c.cost = .init(usd: 0.5, source: .estimate, estimateUSD: 0.5)
        c.turns.seconds = 120
        c.days = [day("2026-09-01", est: 0.5, output: 70, work: [11: 120], lines: (1, 1))]
        c.lines = .init(added: 1, removed: 1, source: .estimate)
        return [a.sessionID: a, b.sessionID: b, c.sessionID: c]
    }

    static func report() -> [(String, Bool)] {
        let cal = calendar
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 18))!
        let all = sessions()
        let (a, b, c) = ("aaaaaaaa-0000-4000-8000-000000000001", "bbbbbbbb-0000-4000-8000-000000000002", "cccccccc-0000-4000-8000-000000000003")
        func build(_ f: UsageFilter, live: Set<String> = []) -> UsageReport {
            UsageReport.build(usage: all, info: [a: SessionInfo(title: "Fix the =SUM, \"bug\"", cwd: "/p/alpha")], live: live, filter: f,
                              now: now, calendar: cal)
        }
        let today = build(UsageFilter(range: .today))
        let rowA = today.rows.first { $0.id == a }, rowB = today.rows.first { $0.id == b }
        var out: [(String, Bool)] = [
            ("range: today counts only today's days", UsageRange.today.firstDay(now: now, calendar: cal) == "2026-11-03"
             && Set(today.rows.map(\.id)) == [a, b]),
            ("range: Claude Code's figure cut by the range is split by day (by the days' estimates), est.",
             rowA?.cost == 6 && rowA?.costKind == .claudeCodeSplit && rowA?.costEstimate == true && rowA?.costPartial == false
             && rowA?.dollarsText == "$6.00 est." && rowA?.written == 300 && rowA?.workSeconds == 1_200),
            ("range: lines of a session cut by the range are its days' share, scaled, est.",
             rowA?.linesAdded == 60 && rowA?.linesRemoved == 10 && rowA?.linesEstimate == true),
            ("range: compactions counted by their own time", rowA?.compactions == 1 && today.totals.compactions == 1
             && today.totals.autoCompactions == 1 && today.totals.manualCompactions == 0),
            ("cost: no price is unknown, never $0, and the total says it is at least what was priced",
             rowB?.cost == nil && rowB?.dollarsText == "Unknown" && today.totals.cost == 6 && today.totals.unknownSessions == 1
             && today.totals.costAtLeast && !today.totals.costUnknown && UsageTiles.costValue(today.totals, money: UsageFormat.usd) == "≥ $6.00"
             && today.unpriced == ["claude-3-7-sonnet-20250219"]),
        ]
        let week = build(UsageFilter(range: .week))
        let wA = week.rows.first { $0.id == a }
        out.append(("range: a session wholly inside the range keeps its own figures, Claude Code's as it is",
                    UsageRange.week.firstDay(now: now, calendar: cal) == "2026-10-28" && wA?.cost == 10 && wA?.costKind == .claudeCode
                    && wA?.dollarsText == "$10.00" && wA?.linesAdded == 80
                    && wA?.linesEstimate == false && wA?.compactions == 1 && week.rows.count == 2))
        let ever = build(UsageFilter(range: .all))
        out.append(("range: all time is every session's own totals", ever.rows.count == 3 && ever.totals.cost == 10.5
                    && ever.totals.costEstimate && ever.totals.written == 520 && ever.totals.compactions == 2 && ever.totals.workDays == 3
                    && ever.totals.linesAdded == 85 && ever.totals.sessions == 3 && ever.totals.projects == 3))
        out.append(("range: 30 days leaves out September", build(UsageFilter(range: .month)).rows.count == 2))
        out.append(("totals: an estimate or a split anywhere makes the total est.",
                    !week.totals.costEstimate && today.totals.costEstimate && ever.totals.costEstimate))
        out.append(("projects: named by their folder, by two parts where two share a name",
                    ever.rows.first { $0.id == a }?.projectName == "p/alpha" && ever.rows.first { $0.id == b }?.projectName == "q/alpha"
                    && ever.rows.first { $0.id == c }?.projectName == "gamma"))
        out.append(("projects: your home folder is ~, not your account name",
                    UsageReport.projectNames(keys: ["-h-me", "-h-me-x"], folders: ["-h-me": "/h/me", "-h-me-x": "/h/me/x"], home: "/h/me")
                    == ["-h-me": "~", "-h-me-x": "x"]))
        let gamma = ever.projects.first { $0.key == "-p-gamma" }?.slot
        out.append(("colours: the range's costliest projects; a project filter never repaints one",
                    ever.projects.first?.slot == 0 && gamma == 1
                    && build(UsageFilter(range: .all, project: "-p-gamma")).projects.first?.slot == gamma))
        out.append(("filters: project, model and find", build(UsageFilter(range: .all, project: "-q-alpha")).rows.map(\.id) == [b]
                    && build(UsageFilter(range: .all, model: "Haiku 4.5")).rows.map(\.id) == [a]
                    && build(UsageFilter(range: .all, find: "sum")).rows.map(\.id) == [a]
                    && build(UsageFilter(range: .all, find: "cccccccc")).rows.map(\.id) == [c]))
        out.append(("near the limit: running sessions at 80% or more, whatever the range",
                    build(UsageFilter(range: .today)).near.isEmpty && build(UsageFilter(range: .today), live: [a, b]).near.map(\.id) == [a]
                    && build(UsageFilter(range: .all), live: [a]).near.first?.contextLine == "85% · 850K of 1M"))
        let parts = today.days.filter { $0.day == UsageDay.date("2026-11-03", cal) }
        out.append(("chart: a day's parts stack in the legend's order, keyed by project key", parts.count == 1 && parts.first?.cost == 6
                    && parts.first?.start == 0 && parts.first?.series == "-p-alpha" && today.series.first?.key == "-p-alpha"
                    && today.series.first?.name == "p/alpha" && today.dayDomain?.lowerBound == UsageDay.date("2026-11-03", cal)))
        let models = Dictionary(today.models.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        out.append(("by model: a session's cost split by its models' estimates; no price stays unknown",
                    models["Opus 5.5"]?.cost.map { abs($0 - 4.8) < 1e-9 } == true && models["Haiku 4.5"]?.cost.map { abs($0 - 1.2) < 1e-9 } == true
                    && models["Sonnet 3.7"]?.cost == nil && models["Sonnet 3.7"]?.written == 50))
        let weekday = cal.component(.weekday, from: now) - 1
        out.append(("when Claude works: the range's working time by weekday and hour",
                    today.heat[weekday][14] == 1_200 && today.heat[weekday][9] == 300 && today.heat[weekday][10] == 0
                    && ever.heat.flatMap { $0 }.reduce(0, +) == 2_220))
        let qAlpha = ever.projects.first { $0.key == "-q-alpha" }
        out.append(("by project: sorted by cost, shares of the total; a project with no price is Unknown, never $0",
                    ever.projects.first?.key == "-p-alpha" && ever.projects.first.map { abs($0.share - 10 / 10.5) < 1e-9 } == true
                    && qAlpha?.incomplete == true && qAlpha?.known == false
                    && qAlpha.map { ByProjectSection.costText($0, money: UsageFormat.usd) } == "Unknown"
                    && ever.projects.first.map { ByProjectSection.costText($0, money: UsageFormat.usd) } == "$10.00"))
        let rows = ever.rows.sorted(using: [KeyPathComparator(\UsageRow.costKey, order: .reverse)])
        out.append(("table: sorts by cost, unknown last", rows.map(\.id) == [a, c, b]))
        out.append(("lines: a zero side is left out", UsageRow.lines(120, 0) == "+120" && UsageRow.lines(0, 8) == "−8"
                    && UsageRow.lines(0, 0) == "0" && UsageRow.lines(1_204, 8) == "+\(1_204.formatted(.number)) −8"))
        return out
    }

    // MARK: Names that collide, Claude Code's figure with no estimate, the words around a filter

    static func rules() -> [(String, Bool)] {
        let cal = calendar
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 18))!
        var out: [(String, Bool)] = []

        // Two folders with the same last parts, two sessions in the home folder under two project keys,
        // and a folder named like the chart's own "Other projects": once a trap on opening the window.
        let home = Paths.home
        let folders = ["-c1": "/w/client1/app/web", "-c2": "/w/client2/app/web", "-h1": home, "-h2": home,
                       "-op": "/x/Other projects", "-solo": "/y/solo", "-z": "/z/zeta"]
        let names = UsageReport.projectNames(keys: Set(folders.keys), folders: folders, home: home)
        out.append(("projects: names grow until they differ; never two alike, never \"Other projects\"",
                    names["-c1"] == "client1/app/web" && names["-c2"] == "client2/app/web" && names["-op"] == "x/Other projects"
                    && names["-solo"] == "solo" && Set(names.values).count == names.count
                    && Set([names["-h1"], names["-h2"]]) == Set(["~", "~ (2)"])))
        // The colliding ones cost most, so they are the chart's five coloured series.
        let costs = ["-c1": 20.0, "-c2": 19, "-h1": 18, "-h2": 17, "-op": 16, "-solo": 2, "-z": 1]
        var usage: [String: SessionUsage] = [:]
        for (n, (key, folder)) in folders.sorted(by: { $0.key < $1.key }).enumerated() {
            let id = String(format: "%08x-0000-4000-8000-%012x", n + 1, n + 1)
            var u = SessionUsage(sessionID: id, projectDir: key)
            u.folder = folder
            u.lastActive = now
            u.cost = .init(usd: costs[key]!, source: .estimate, estimateUSD: costs[key]!)
            var d = SessionUsage.Day(date: "2026-11-03", weekday: 3)
            d.estimatedUSD = costs[key]!
            d.replies = 2
            d.tokens.output = 100
            u.days = [d]
            usage[id] = u
        }
        let r = UsageReport.build(usage: usage, info: [:], live: [], filter: UsageFilter(range: .all), now: now, calendar: cal)
        out.append(("projects: the chart's series are keyed by project key and named uniquely (no trap on duplicates)",
                    r.series.count == 6 && Set(r.series.map(\.key)).count == 6 && Set(r.series.map(\.name)).count == 6
                    && r.series.last?.key == UsageReport.otherKey && r.series.filter { $0.name == UsageReport.otherSeries }.count == 1
                    && Set(r.days.map(\.series)).isSubset(of: Set(r.series.map(\.key)))
                    && Set(r.allProjects.map(\.name)).count == r.allProjects.count))

        // Claude Code's figure where nothing could be priced here: its own figure, split by working time
        // when a range cuts it, and never "at least".
        var d1 = SessionUsage.Day(date: "2026-11-01", weekday: 1)
        d1.replies = 4
        d1.workSeconds[10] = 600
        var d2 = SessionUsage.Day(date: "2026-11-03", weekday: 3)
        d2.replies = 4
        d2.workSeconds[11] = 1_800
        var cc = SessionUsage(sessionID: "dddddddd-0000-4000-8000-000000000004", projectDir: "-p-delta")
        cc.folder = "/p/delta"
        cc.lastActive = now
        cc.models = ["claude-x-1"]
        cc.byModel = ["claude-x-1": .init(tokens: .init(output: 80), replies: 8, unpricedReplies: 8)]
        cc.cost = .init(usd: 8, source: .claudeCode, estimateUSD: nil, unpriced: ["claude-x-1"])
        cc.days = [d1, d2]
        func row(_ range: UsageRange) -> UsageRow? {
            UsageReport.build(usage: [cc.sessionID: cc], info: [:], live: [], filter: UsageFilter(range: range), now: now, calendar: cal).rows.first
        }
        let whole = row(.all), cut = row(.today), inside = row(.week)
        out.append(("cost: Claude Code's figure with no estimate: as it is for all time or a range that holds it, split by working time (est.) when cut",
                    whole?.cost == 8 && whole?.costKind == .claudeCode && whole?.costPartial == false && whole?.dollarsText == "$8.00"
                    && inside?.cost == 8 && inside?.costKind == .claudeCode
                    && cut?.cost == 6 && cut?.costKind == .claudeCodeSplit && cut?.costPartial == false && cut?.dollarsText == "$6.00 est."))
        let ccModels = UsageReport.build(usage: [cc.sessionID: cc], info: [:], live: [], filter: UsageFilter(range: .all), now: now, calendar: cal).models
        out.append(("by model: Claude Code's figure also covers models with no price (split by output)",
                    ccModels.first?.cost == 8 && ccModels.first?.name == "claude-x-1"))

        var unknown = UsageTotals()
        unknown.unknownSessions = 2
        var known = UsageTotals()
        known.cost = 12.4
        known.pricedSessions = 3
        out.append(("tiles: nothing priced is Unknown, part priced is at least, the rest as it is",
                    UsageTiles.costValue(unknown, money: UsageFormat.usd) == "Unknown" && unknown.costUnknown
                    && UsageTiles.costValue(known, money: UsageFormat.usd) == "$12.40" && !known.costAtLeast))
        out.append(("model filter: the totals and By model say they are whole sessions, every model counted",
                    UsageTiles.heading(UsageFilter(range: .month, model: "Haiku 4.5"))
                    == "Totals for the last 30 days: sessions where Haiku 4.5 replied, all their models counted"
                    && UsageTiles.heading(UsageFilter(range: .all)) == "Totals for all time"
                    && ByModelSection.filterHelp("Haiku 4.5").contains("every model in them counted")
                    && ByModelSection.filterNote("Haiku 4.5").contains("not Haiku 4.5's cost alone")))
        return out
    }

    // MARK: The window's model: selection, Find, midnight

    @MainActor
    static func windowModel() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        let cal = Calendar.usage
        var clock = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 23, minute: 59))!
        func wait(_ seconds: Double, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(seconds)
            while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        func session(_ id: String, _ dir: String, day: String) -> SessionUsage {
            var u = SessionUsage(sessionID: id, projectDir: dir)
            u.folder = "/w/" + dir
            u.lastActive = clock
            var d = SessionUsage.Day(date: day, weekday: 3)
            d.replies = 2
            d.estimatedUSD = 1
            d.workSeconds[12] = 60
            u.days = [d]
            u.cost = .init(usd: 1, source: .estimate, estimateUSD: 1)
            return u
        }
        let a = "aaaaaaaa-1111-4000-8000-000000000001", b = "bbbbbbbb-1111-4000-8000-000000000002"
        let vm = UsageWindowModel(filter: UsageFilter(range: .all), remember: nil)
        vm.now = { clock }
        vm.load(usage: [a: session(a, "-w-alpha", day: "2026-11-03"), b: session(b, "-w-beta", day: "2026-11-03")], sessions: [], live: [])
        vm.selection = a
        let prepared = vm.preparations
        vm.filter.find = "beta"
        let before = vm.rows.count
        wait(1) { vm.rows.count == 1 }
        out.append(("find: waits for typing to pause, then only filters (the rest is not worked out again)",
                    before == 2 && vm.rows.map(\.id) == [b] && vm.preparations == prepared))
        out.append(("selection: a row that is no longer shown is no longer selected, so nothing acts on it",
                    vm.selection == nil && vm.selectedRow == nil && vm.selectedSession == nil))
        vm.filter.find = ""
        vm.applyFind()
        vm.selection = b
        vm.filter.project = "-w-alpha"
        out.append(("selection: the same when another filter hides it", vm.selection == nil && vm.rows.map(\.id) == [a]))
        vm.filter.project = nil
        vm.filter.range = .today
        let todayBefore = vm.report.firstDay
        clock = clock.addingTimeInterval(120)     // past midnight
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        wait(1) { vm.report.firstDay != todayBefore }
        out.append(("today: moves on at midnight", todayBefore == "2026-11-03" && vm.report.firstDay == "2026-11-04" && vm.rows.isEmpty))
        clock = clock.addingTimeInterval(86_400)
        vm.dayMayHaveChanged()
        out.append(("today: and when the app comes forward on a later day", vm.report.firstDay == "2026-11-05"))
        return out
    }

    // MARK: CSV

    static func csv() -> [(String, Bool)] {
        let cal = calendar
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 18))!
        let r = UsageReport.build(usage: sessions(), info: ["aaaaaaaa-0000-4000-8000-000000000001": SessionInfo(title: "=SUM(1), \"x\"\nnext", cwd: "/p/alpha")],
                                  live: [], filter: UsageFilter(range: .all), now: now, calendar: cal)
        let text = UsageCSV.make(r.rows, second: .init(code: "INR", perUSD: 90, date: now), calendar: cal)
        let lines = text.dropFirst().components(separatedBy: "\r\n")
        let a = lines.first { $0.contains("aaaaaaaa-") } ?? ""
        let b = lines.first { $0.contains("bbbbbbbb-") } ?? ""
        return [
            ("csv: quotes, commas and line breaks escaped", UsageCSV.field("a,b") == "\"a,b\"" && UsageCSV.field("say \"hi\"") == "\"say \"\"hi\"\"\""
             && UsageCSV.field("a\nb") == "\"a\nb\"" && UsageCSV.field("plain") == "plain"),
            ("csv: text a spreadsheet would run as a formula gets an apostrophe",
             UsageCSV.field("=SUM(A1)", text: true) == "'=SUM(A1)" && UsageCSV.field("-rf", text: true) == "'-rf"
             && UsageCSV.field("@x", text: true) == "'@x" && UsageCSV.field("+1", text: true) == "'+1" && UsageCSV.field("-5") == "-5"),
            ("csv: also after leading spaces, after a tab or CR, and in the full-width forms",
             UsageCSV.field("  =1", text: true) == "'  =1" && UsageCSV.field("\t=1", text: true) == "'\t=1"
             && UsageCSV.field("\tplain", text: true) == "'\tplain" && UsageCSV.field("\r\n=1", text: true) == "\"'\r\n=1\""
             && UsageCSV.field("＝1", text: true) == "'＝1" && UsageCSV.field("＋1", text: true) == "'＋1"
             && UsageCSV.field("－1", text: true) == "'－1" && UsageCSV.field("＠x", text: true) == "'＠x"
             && UsageCSV.field("a = b", text: true) == "a = b"),
            ("csv: every text column is guarded, the session ID too",
             UsageCSV.make([UsageRow(id: "=id", title: "+t", folder: "@f", projectKey: "-k", projectName: "-p")], second: nil, calendar: cal)
                .contains("'+t,'-p,'@f,'=id,")),
            ("csv: byte order mark, a header, one CRLF line per row", text.hasPrefix("\u{FEFF}Session,Project,Folder,Session ID")
             && text.hasSuffix("\r\n") && lines.filter { !$0.isEmpty }.count == 1 + r.rows.count),
            ("csv: a row as plain numbers, with the second currency", a.hasPrefix("\"'=SUM(1), \"\"x\"\"\nnext\",p/alpha,/p/alpha,")
             && a.contains(",2026-11-03T12:00:00Z,850000,85,2,10,Claude Code,900,400,0.5,80,14,Claude Code")),
            ("csv: an unknown cost is empty, not 0", b.contains(",,unknown,,50,")),
            ("csv: the file is named after the range", UsageCSV.fileName(.month, now: now, calendar: cal) == "Claude Code usage, last 30 days, 2026-11-03.csv"),
        ]
    }

    // MARK: Claws' live session files, read-only

    static func live() -> [(String, Bool)] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("claws-live-\(getpid())", isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let now = 1_000_000.0
        func put(_ name: String, _ o: [String: Any]) {
            fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: try? JSONSerialization.data(withJSONObject: o))
        }
        func id(_ n: Int) -> String { String(format: "%08d-0000-4000-8000-000000000000", n) }
        put(id(1) + ".json", ["session_id": id(1), "claude_pid": 10, "claude_start": 5.0, "updated_ts": now - 9_000])     // alive
        put(id(2) + ".json", ["session_id": id(2), "claude_pid": 11, "claude_start": 5.0, "updated_ts": now])             // dead
        put(id(3) + ".json", ["session_id": id(3), "claude_pid": 10, "claude_start": 5.0, "ended_ts": now - 10])         // ended
        put(id(4) + ".json", ["session_id": id(4), "updated_ts": now - 60])                                               // no pid, fresh
        put(id(5) + ".json", ["session_id": id(5), "updated_ts": now - 3_600])                                            // no pid, stale
        put("x.json", ["session_id": "not-a-session", "claude_pid": 10, "claude_start": 5.0])
        put("." + id(6) + ".tmp", ["session_id": id(6), "claude_pid": 10, "claude_start": 5.0])
        fm.createFile(atPath: dir.appendingPathComponent("broken.json").path, contents: Data("{".utf8))
        let before = (try? fm.contentsOfDirectory(atPath: dir.path))?.sorted()
        let running = LiveSessions.running(in: dir, now: now) { pid, start in pid == 10 && start == 5 }
        let me = LiveSessions.Proc.start(getpid())
        return [
            ("live: running = not ended and its Claude process alive, or a file without one changed in 5 min",
             running == [id(1), id(4)]),
            ("live: the folder is only read", (try? fm.contentsOfDirectory(atPath: dir.path))?.sorted() == before),
            ("live: the liveness check matches the process and its start time",
             me.map { LiveSessions.Proc.isAlive(getpid(), $0) && !LiveSessions.Proc.isAlive(getpid(), $0 + 5) } == true
             && !LiveSessions.Proc.isAlive(-1, nil)),
            ("live: Claws' own folder, unless CLAWS_HOME says otherwise",
             ProcessInfo.processInfo.environment["CLAWS_HOME"] != nil
             || LiveSessions.folder.path == Paths.realHome + "/Library/Application Support/Claws for Concern/sessions"),
        ]
    }

    // MARK: Which window, and Claws' requests

    static func windows() -> [(String, Bool)] {
        [
            ("windows: --window usage opens only Usage at launch; anything else Search",
             HelperWindow.atLaunch(["x", "--nonce", "n", "--window", "usage"]) == .usage && HelperWindow.atLaunch(["x", "--nonce", "n"]) == .search
             && HelperWindow.atLaunch(["x", "--window", "other"]) == .search && HelperWindow.atLaunch(["x", "--window"]) == .search),
            ("windows: the window asked for is the first scene", HelperWindow.order(first: .usage) == [.usage, .search]
             && HelperWindow.order(first: .search) == [.search, .usage] && HelperWindow.search.rawValue == "main"),
            ("windows: Claws' request names the window and this helper's PID",
             WindowRequest.note.rawValue == "io.github.patildhruv.claws-for-concern.search.openWindow"
             && WindowRequest.window(from: ["window": "usage", "pid": Int(getpid())]) == .usage
             && WindowRequest.window(from: ["window": "main"]) == .search
             && WindowRequest.window(from: ["window": "usage", "pid": Int(getpid()) + 1]) == nil
             && WindowRequest.window(from: ["window": "settings"]) == nil && WindowRequest.window(from: nil) == nil),
            ("windows: the helper answers with the window and its PID, so Claws stops asking",
             WindowRequest.answer.rawValue == "io.github.patildhruv.claws-for-concern.search.openedWindow"
             && WindowRequest.answer(.usage, pid: 42)["window"] as? String == "usage" && WindowRequest.answer(.usage, pid: 42)["pid"] as? Int == 42),
            ("windows: ⌘F goes to the Find field of the window in front",
             FindTarget.note(usageInFront: true) == .focusUsageFind && FindTarget.note(usageInFront: false) == .focusSearch),
        ]
    }

    // MARK: Open in Search

    /// Two made-up transcripts; the search field matches only one, yet the window knows both, and Open in
    /// Search hands Search the session and its project folder. Then the demo: its live files stay in its home.
    @MainActor
    static func reveal() -> [(String, Bool)] {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("claws-reveal-\(getpid())")
        defer { try? fm.removeItem(at: base) }
        let ids = ["2f1e2d3c-4b5a-6978-8a9b-acbdcedfe001", "2f1e2d3c-4b5a-6978-8a9b-acbdcedfe002"]
        for (i, prompt) in ["the zebra crossing", "a quiet afternoon"].enumerated() {
            let folder = base.appendingPathComponent("p\(i)").path
            try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let dir = base.appendingPathComponent("projects").appendingPathComponent(ProjectDirs.name(for: folder))
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let line = #"{"type":"user","cwd":"\#(folder)","timestamp":"2026-11-0\#(i + 1)T10:00:00.000Z","message":{"content":"\#(prompt)"}}"#
            fm.createFile(atPath: dir.appendingPathComponent(ids[i] + ".jsonl").path, contents: Data((line + "\n").utf8))
        }
        let model = AppModel(store: SessionStore(root: base.appendingPathComponent("projects")))
        model.resumer = { _ in }
        func wait(_ seconds: Double, until done: () -> Bool) {
            let end = Date().addingTimeInterval(seconds)
            while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        wait(10) { !model.indexing && model.indexedSessions.count == 2 }
        model.query = "zebra"
        wait(2) { !model.indexing }
        let known = model.indexedSessions.map(\.id).sorted() == ids
        // The window's side: Search's entry point gets the ID and the project folder of its figures.
        let vm = UsageWindowModel(filter: UsageFilter(range: .all), remember: nil)
        var calls: [String] = []
        var opened = 0
        vm.showInSearch = { calls.append("\($0) \($1 ?? "-")") }
        let dir = ProjectDirs.name(for: base.appendingPathComponent("p1").path)
        var u = SessionUsage(sessionID: ids[1], projectDir: dir)
        u.lastActive = Date()
        vm.load(usage: [ids[1]: u], sessions: model.indexedSessions, live: [])
        vm.openInSearch(ids[1]) { opened += 1 }
        vm.openInSearch("2f1e2d3c-4b5a-6978-8a9b-acbdcedfe0ff") { opened += 1 }
        var out: [(String, Bool)] = [
            ("open in Search: every indexed session is known, not only what the field matches", known),
            ("open in Search: the window comes up and Search is asked for that copy of the session",
             calls == ["\(ids[1]) \(dir)"] && opened == 1),
            ("open in Search: a session Search has not read says so and opens nothing",
             vm.flash == "Search has not read this session yet." && calls.count == 1),
            ("table: named and placed from Search's index", vm.rows.first?.title == "a quiet afternoon" && vm.rows.first?.known == true),
        ]

        let root = Demo.activate()
        let running = LiveSessions.running()
        let folder = LiveSessions.folder.path
        Demo.deactivate()
        out.append(("demo: its running sessions are made-up files in its own home",
                    folder.hasPrefix(root.path + "/home/") && running == Set(LiveSessions.DemoFiles.running)
                    && !fm.fileExists(atPath: root.path)))
        return out
    }
}
