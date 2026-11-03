import Foundation

// What the Usage window shows, worked out from every session's `SessionUsage` and the filters. Pure
// (no UI, an injected clock and calendar), so the self-test checks ranges, totals and the CSV.
// Guide: docs/usage-window.md.

/// The date filter. Each session's `days` (local calendar days) decide what falls inside.
enum UsageRange: String, CaseIterable, Identifiable {
    case today, week = "7d", month = "30d", all
    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 Days"
        case .month: return "30 Days"
        case .all: return "All Time"
        }
    }

    /// "today", "in the last 7 days", "in all"; for the tiles.
    var phrase: String {
        switch self {
        case .today: return "today"
        case .week: return "in the last 7 days"
        case .month: return "in the last 30 days"
        case .all: return "in all"
        }
    }

    var dayCount: Int? {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        case .all: return nil
        }
    }

    /// The first day counted ("yyyy-MM-dd"): today and the days before it; nil for all time.
    func firstDay(now: Date, calendar: Calendar) -> String? {
        guard let n = dayCount, let d = calendar.date(byAdding: .day, value: -(n - 1), to: calendar.startOfDay(for: now)) else { return nil }
        return UsageDay.key(d, calendar)
    }
}

enum UsageDay {
    static func key(_ d: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(_ key: String, _ calendar: Calendar) -> Date? { RateRule.day(key, calendar: calendar) }
}

struct UsageFilter: Equatable {
    var range = UsageRange.month
    /// A project key (Claude Code's folder name), nil for all.
    var project: String?
    /// A model's display name (`UsageFormat.model`), nil for all.
    var model: String?
    var find = ""
}

/// What the window knows of a session besides its usage: from Search's index.
struct SessionInfo: Equatable {
    var title: String
    var cwd: String?
}

/// One row of All sessions, its figures for the range.
struct UsageRow: Identifiable, Equatable {
    let id: String
    var title: String
    /// "~/code/payments-api".
    var folder: String
    var projectKey: String
    var projectName: String
    var lastActive: Date?
    var contextNow: Int?
    var contextFraction: Double?
    var contextWindow: Int?
    var nearLimit = false
    var running = false
    var compactions = 0
    /// In the range, at API prices; nil when none of it could be priced.
    var cost: Double?
    /// Not Claude Code's own figure.
    var costEstimate = true
    /// Some replies could not be priced: the cost is at least this.
    var costPartial = false
    var unpriced: [String] = []
    var written = 0
    var workSeconds = 0.0
    var linesAdded = 0
    var linesRemoved = 0
    var linesEstimate = true
    /// Display names of the models that replied.
    var models: [String] = []
    /// Search knows the session (Open in Search, Resume).
    var known = false

    // Sort keys (Table sorts by key paths to Comparable values).
    var lastActiveKey: Date { lastActive ?? .distantPast }
    var contextKey: Double { contextFraction ?? contextNow.map { Double($0) / 1_000_000 } ?? -1 }
    var costKey: Double { cost ?? -1 }
    var linesKey: Int { linesAdded + linesRemoved }
}

struct UsageTotals: Equatable {
    var cost = 0.0
    var costEstimate = false
    /// Sessions with no price at all, and with part unpriced.
    var unknownSessions = 0
    var partialSessions = 0
    var written = 0
    var workSeconds = 0.0
    var workDays = 0
    var sessions = 0
    var projects = 0
    var linesAdded = 0
    var linesRemoved = 0
    var linesEstimate = false
    var compactions = 0
    var autoCompactions = 0
    var manualCompactions = 0
}

struct UsageReport {
    struct DayCost: Identifiable, Equatable {
        var day: Date
        var series: String
        var cost: Double
        var id: String { "\(day.timeIntervalSince1970)|\(series)" }
    }

    struct Series: Equatable {
        var name: String
        /// 0…4 for the five projects that cost most over all time; nil for "Other projects".
        var slot: Int?
    }

    struct ProjectTotal: Identifiable, Equatable {
        var key: String
        var name: String
        var cost: Double
        var share: Double
        var sessions: Int
        var estimate: Bool
        var incomplete: Bool
        var slot: Int?
        var id: String { key }
    }

    struct ModelTotal: Identifiable, Equatable {
        var name: String
        /// nil when none of its replies could be priced.
        var cost: Double?
        var share: Double
        var written: Int
        var id: String { name }
    }

    var filter = UsageFilter()
    var firstDay: String?
    var rows: [UsageRow] = []
    /// Running sessions at 80% of their window or more (any date, the other filters applied).
    var near: [UsageRow] = []
    var totals = UsageTotals()
    var days: [DayCost] = []
    var dayDomain: ClosedRange<Date>?
    var series: [Series] = []
    var projects: [ProjectTotal] = []
    var models: [ModelTotal] = []
    /// Claude's working seconds, rows Sunday…Saturday, columns 0…23 (`SessionUsage.activity`).
    var heat: [[Double]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    /// Every project and model, for the pickers: all sessions, all time.
    var allProjects: [(key: String, name: String)] = []
    var allModels: [String] = []
    /// Model IDs some rows could not price.
    var unpriced: [String] = []
    /// Sessions with figures at all, before any filter.
    var sessionCount = 0

    static let otherSeries = "Other projects"

    static func build(usage: [String: SessionUsage], info: [String: SessionInfo], live: Set<String>,
                      filter: UsageFilter, now: Date, calendar: Calendar = .current) -> UsageReport {
        var r = UsageReport()
        r.filter = filter
        r.sessionCount = usage.count
        let from = filter.range.firstDay(now: now, calendar: calendar)
        r.firstDay = from

        // Projects: named by their folder's last part, or the last two when two share a name.
        var folders: [String: String] = [:]
        for u in usage.values where folders[u.projectDir] == nil {
            if let f = info[u.sessionID]?.cwd ?? u.folder { folders[u.projectDir] = f }
        }
        let names = projectNames(keys: Set(usage.values.map(\.projectDir)), folders: folders)
        // Colours follow the project, never its rank in a filtered view: the five that cost most over
        // all time keep their slots whatever the filters show.
        var allTime: [String: Double] = [:]
        for u in usage.values { allTime[u.projectDir, default: 0] += u.cost.usd ?? 0 }
        let ranked = allTime.sorted { ($0.value, names[$1.key] ?? "") > ($1.value, names[$0.key] ?? "") }.map(\.key)
        var slot: [String: Int] = [:]
        for (i, k) in ranked.prefix(5).enumerated() where (allTime[k] ?? 0) > 0 { slot[k] = i }
        r.allProjects = names.map { (key: $0.key, name: $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var modelCost: [String: Double] = [:]
        for u in usage.values {
            for (id, m) in u.byModel { modelCost[UsageFormat.model(id), default: 0] += m.estimatedUSD ?? 0 }
        }
        r.allModels = modelCost.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)

        let needle = filter.find.trimmingCharacters(in: .whitespaces).lowercased()
        func row(_ u: SessionUsage) -> UsageRow {
            let i = info[u.sessionID]
            var row = UsageRow(id: u.sessionID, title: i?.title ?? "Session \(u.sessionID.prefix(8))",
                               folder: Paths.abbreviate(i?.cwd ?? u.folder ?? u.projectDir),
                               projectKey: u.projectDir, projectName: names[u.projectDir] ?? u.projectDir)
            row.known = i != nil
            row.lastActive = u.lastActive
            row.contextNow = u.context.now
            row.contextWindow = u.contextWindow
            row.contextFraction = u.contextFraction
            row.nearLimit = u.isNearContextLimit
            row.running = live.contains(u.sessionID)
            row.models = Array(Set(u.models.map(UsageFormat.model))).sorted()
            row.unpriced = u.cost.unpriced
            row.costEstimate = u.cost.source == .estimate
            fill(&row, u, from: from, calendar: calendar)
            row.costPartial = row.cost != nil && !u.cost.unpriced.isEmpty
            return row
        }
        func passes(_ row: UsageRow) -> Bool {
            if let p = filter.project, row.projectKey != p { return false }
            if let m = filter.model, !row.models.contains(m) { return false }
            guard !needle.isEmpty else { return true }
            return row.title.lowercased().contains(needle) || row.folder.lowercased().contains(needle)
                || row.projectName.lowercased().contains(needle) || row.id.hasPrefix(needle)
        }
        var inRange: [SessionUsage] = []
        for u in usage.values {
            let rw = row(u)
            guard passes(rw) else { continue }
            if rw.running && rw.nearLimit { r.near.append(rw) }
            guard from == nil || active(u, from: from!, calendar: calendar) else { continue }
            r.rows.append(rw)
            inRange.append(u)
        }
        r.rows.sort { ($0.lastActiveKey, $0.id) > ($1.lastActiveKey, $1.id) }
        r.near.sort { $0.contextKey > $1.contextKey }

        // Totals.
        var t = UsageTotals()
        var workDays = Set<String>()
        var unpriced = Set<String>()
        for row in r.rows {
            if let c = row.cost {
                t.cost += c
                if row.costEstimate && c > 0 { t.costEstimate = true }
                if row.costPartial { t.partialSessions += 1; unpriced.formUnion(row.unpriced) }
            } else if row.written > 0 || row.workSeconds > 0 {
                t.unknownSessions += 1
                unpriced.formUnion(row.unpriced)
            }
            t.written += row.written
            t.workSeconds += row.workSeconds
            t.linesAdded += row.linesAdded
            t.linesRemoved += row.linesRemoved
            if row.linesEstimate && row.linesAdded + row.linesRemoved > 0 { t.linesEstimate = true }
        }
        for u in inRange {
            for d in u.days where from.map({ d.date >= $0 }) ?? true && d.workSeconds.reduce(0, +) > 0 { workDays.insert(d.date) }
            for c in u.context.compactions where from.map({ UsageDay.key(c.at, calendar) >= $0 }) ?? true {
                t.compactions += 1
                if c.trigger == "auto" { t.autoCompactions += 1 } else if c.trigger == "manual" { t.manualCompactions += 1 }
            }
        }
        t.workDays = workDays.count
        t.sessions = r.rows.count
        t.projects = Set(r.rows.map(\.projectKey)).count
        r.totals = t
        r.unpriced = unpriced.sorted()

        // Cost per day, by project: the five with colours, the rest together.
        var perDay: [String: [String: Double]] = [:]
        var earliest: String?
        for u in inRange {
            let series = slot[u.projectDir] != nil ? (names[u.projectDir] ?? u.projectDir) : otherSeries
            for d in u.days where (from.map { d.date >= $0 } ?? true) && d.replies > 0 {
                perDay[d.date, default: [:]][series, default: 0] += u.cost(of: d) ?? 0
                if earliest.map({ d.date < $0 }) ?? true { earliest = d.date }
            }
        }
        for (key, bySeries) in perDay {
            guard let day = UsageDay.date(key, calendar) else { continue }
            for (s, c) in bySeries where c > 0 { r.days.append(.init(day: day, series: s, cost: c)) }
        }
        r.days.sort { ($0.day, $0.series) < ($1.day, $1.series) }
        if let start = (from ?? earliest).flatMap({ UsageDay.date($0, calendar) }) {
            let end = calendar.startOfDay(for: now)
            r.dayDomain = min(start, end)...max(start, end)
        }
        let present = Set(r.days.map(\.series))
        r.series = slot.sorted { $0.value < $1.value }.compactMap { k, i in
            let name = names[k] ?? k
            return present.contains(name) ? Series(name: name, slot: i) : nil
        } + (present.contains(otherSeries) ? [Series(name: otherSeries, slot: nil)] : [])

        // By project.
        var byProject: [String: ProjectTotal] = [:]
        for row in r.rows {
            var p = byProject[row.projectKey] ?? ProjectTotal(key: row.projectKey, name: row.projectName, cost: 0, share: 0, sessions: 0,
                                                              estimate: false, incomplete: false, slot: slot[row.projectKey])
            p.cost += row.cost ?? 0
            p.sessions += 1
            if row.costEstimate && (row.cost ?? 0) > 0 { p.estimate = true }
            if row.cost == nil || row.costPartial { p.incomplete = true }
            byProject[row.projectKey] = p
        }
        r.projects = byProject.values.map { p in
            var p = p
            p.share = t.cost > 0 ? p.cost / t.cost : 0
            return p
        }.sorted { ($0.cost, $1.name) > ($1.cost, $0.name) }

        // By model: each session's cost in the range, split by its models' share of its estimate (the
        // days do not say which model replied when).
        var byModel: [String: (cost: Double?, written: Int)] = [:]
        for u in inRange {
            guard let row = r.rows.first(where: { $0.id == u.sessionID }) else { continue }
            let share = outputShare(u, from: from)
            let priced = u.byModel.values.compactMap(\.estimatedUSD).reduce(0, +)
            for (id, m) in u.byModel {
                let name = UsageFormat.model(id)
                var e = byModel[name] ?? (nil, 0)
                e.written += Int((Double(m.tokens.output) * share).rounded())
                if let est = m.estimatedUSD, priced > 0, let c = row.cost {
                    e.cost = (e.cost ?? 0) + c * est / priced
                }
                byModel[name] = e
            }
        }
        let modelTotal = byModel.values.compactMap(\.cost).reduce(0, +)
        r.models = byModel.map { ModelTotal(name: $0.key, cost: $0.value.cost, share: modelTotal > 0 ? ($0.value.cost ?? 0) / modelTotal : 0,
                                             written: $0.value.written) }
            .filter { $0.written > 0 || ($0.cost ?? 0) > 0 }
            .sorted { (($0.cost ?? -1), $0.written, $1.name) > (($1.cost ?? -1), $1.written, $0.name) }

        r.heat = SessionUsage.activity(inRange, from: from)
        return r
    }

    /// The session did something on or after `from`: a reply, working time or a compaction.
    static func active(_ u: SessionUsage, from: String, calendar: Calendar) -> Bool {
        u.days.contains { $0.date >= from && ($0.replies > 0 || $0.workSeconds.reduce(0, +) > 0) }
            || u.context.compactions.contains { UsageDay.key($0.at, calendar) >= from }
    }

    /// Share of the session's output written on or after `from` (1 for all time).
    static func outputShare(_ u: SessionUsage, from: String?) -> Double {
        guard let from else { return 1 }
        let all = u.days.reduce(0) { $0 + $1.tokens.output }
        guard all > 0 else { return u.days.allSatisfy { $0.date >= from } ? 1 : 0 }
        return Double(u.days.filter { $0.date >= from }.reduce(0) { $0 + $1.tokens.output }) / Double(all)
    }

    /// A session's figures for the range. All time: its own totals. A range: its days on or after
    /// `from`; cost per day scaled to Claude Code's figure (`cost(of:)`). Lines have no per-day split:
    /// a session wholly inside the range keeps its own count, one that started earlier gets the share
    /// of its lines that matches the share of its output written in the range, marked est.
    static func fill(_ row: inout UsageRow, _ u: SessionUsage, from: String?, calendar: Calendar) {
        guard let from else {
            row.cost = u.cost.usd
            row.written = u.tokens.output
            row.workSeconds = u.turns.seconds
            row.compactions = u.context.compactions.count
            row.linesAdded = u.lines.added
            row.linesRemoved = u.lines.removed
            row.linesEstimate = u.lines.source == .estimate
            return
        }
        var sum = 0.0, priced = false, missing = false
        for d in u.days where d.date >= from {
            row.written += d.tokens.output
            row.workSeconds += d.workSeconds.reduce(0, +)
            guard d.replies > 0 else { continue }
            if let c = u.cost(of: d) { sum += c; priced = true } else { missing = true }
        }
        row.cost = priced ? sum : (missing ? nil : 0)
        row.compactions = u.context.compactions.filter { UsageDay.key($0.at, calendar) >= from }.count
        if u.days.allSatisfy({ $0.date >= from }) {
            row.linesAdded = u.lines.added
            row.linesRemoved = u.lines.removed
            row.linesEstimate = u.lines.source == .estimate
        } else {
            let share = outputShare(u, from: from)
            row.linesAdded = Int((Double(u.lines.added) * share).rounded())
            row.linesRemoved = Int((Double(u.lines.removed) * share).rounded())
            row.linesEstimate = true
        }
    }

    /// The last part of each project's folder; the last two parts where two projects share one.
    static func projectNames(keys: Set<String>, folders: [String: String]) -> [String: String] {
        func parts(_ k: String) -> [String] { (folders[k] ?? "").split(separator: "/").map(String.init) }
        var byLeaf: [String: [String]] = [:]
        for k in keys { byLeaf[parts(k).last ?? k, default: []].append(k) }
        var out: [String: String] = [:]
        for (leaf, ks) in byLeaf {
            for k in ks {
                let p = parts(k)
                out[k] = p.isEmpty ? k : (ks.count > 1 && p.count >= 2 ? p.suffix(2).joined(separator: "/") : leaf)
            }
        }
        return out
    }
}

/// Export CSV: the rows the filters show, figures as plain numbers (dot decimals, no symbols), UTF-8
/// with a byte order mark so Excel reads ₹ and accents, CRLF line ends (RFC 4180).
enum UsageCSV {
    static func make(_ rows: [UsageRow], second: UsageModel.SecondCurrency?, calendar: Calendar = .current) -> String {
        var header = ["Session", "Project", "Folder", "Session ID", "Last active", "Context tokens", "Context %",
                      "Compactions", "Cost (USD at API prices)", "Cost source"]
        if let s = second { header.append("Cost (\(s.code) at \(number(s.perUSD, 4)) per USD, \(UsageDay.key(s.date, calendar)))") }
        header += ["Written by Claude (output tokens)", "Claude worked (hours)", "Lines added", "Lines removed", "Lines source"]
        let iso = ISO8601DateFormatter()
        iso.timeZone = calendar.timeZone
        iso.formatOptions = [.withInternetDateTime]
        var lines = [header.map { field($0) }.joined(separator: ",")]
        for r in rows {
            let source: String
            if r.cost == nil { source = "unknown" } else { source = (r.costEstimate ? "estimate" : "Claude Code") + (r.costPartial ? ", part unpriced" : "") }
            var cells = [field(r.title, text: true), field(r.projectName, text: true), field(r.folder, text: true), field(r.id),
                         r.lastActive.map { iso.string(from: $0) } ?? "", r.contextNow.map(String.init) ?? "",
                         r.contextFraction.map { number($0 * 100, 1) } ?? "", String(r.compactions),
                         r.cost.map { number($0, 4) } ?? "", field(source)]
            if let s = second { cells.append(r.cost.map { number($0 * s.perUSD, 2) } ?? "") }
            cells += [String(r.written), number(r.workSeconds / 3600, 2), String(r.linesAdded), String(r.linesRemoved),
                      r.linesEstimate ? "estimate" : "Claude Code"]
            lines.append(cells.joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Quoted when it holds a comma, a quote or a line break (quotes doubled). Text that a spreadsheet
    /// would run as a formula (=, +, -, @, tab, CR first) gets a leading apostrophe.
    static func field(_ s: String, text: Bool = false) -> String {
        var v = s
        if text, let first = v.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) { v = "'" + v }
        guard v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func number(_ v: Double, _ digits: Int) -> String {
        var s = String(format: "%.\(digits)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    /// "Claude Code usage, last 30 days, 2026-11-03.csv".
    static func fileName(_ range: UsageRange, now: Date, calendar: Calendar = .current) -> String {
        let span: String
        switch range {
        case .today: span = "today"
        case .week: span = "last 7 days"
        case .month: span = "last 30 days"
        case .all: span = "all time"
        }
        return "Claude Code usage, \(span), \(UsageDay.key(now, calendar)).csv"
    }
}
