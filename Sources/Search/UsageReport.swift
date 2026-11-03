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

    /// A day of the figures ("yyyy-MM-dd", local) back as its start in `calendar` (`Calendar.usage`).
    static func date(_ key: String, _ calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
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
    /// How a row's cost was arrived at.
    enum CostKind: Equatable {
        /// Claude Code's own figure, as it is.
        case claudeCode
        /// Claude Code's figure, split by day because the range cuts the session: est.
        case claudeCodeSplit
        /// Worked out here from the tokens: est.
        case estimate
    }

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
    var costKind = CostKind.estimate
    /// Some replies could not be priced: the cost is at least this. Never for Claude Code's figure, which
    /// covers every reply.
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

    /// Not Claude Code's own figure as it is: "est.".
    var costEstimate: Bool { costKind != .claudeCode }

    // Sort keys (Table sorts by key paths to Comparable values).
    var lastActiveKey: Date { lastActive ?? .distantPast }
    var contextKey: Double { contextFraction ?? contextNow.map { Double($0) / 1_000_000 } ?? -1 }
    var costKey: Double { cost ?? -1 }
    var linesKey: Int { linesAdded + linesRemoved }
}

struct UsageTotals: Equatable {
    /// What could be priced.
    var cost = 0.0
    var costEstimate = false
    /// Sessions with a cost, with none (unknown), and priced only in part.
    var pricedSessions = 0
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

    /// None of it could be priced: the cost is unknown, never $0.
    var costUnknown: Bool { pricedSessions == 0 && unknownSessions > 0 }
    /// Part of it could not be priced: the cost is at least `cost`.
    var costAtLeast: Bool { !costUnknown && (unknownSessions > 0 || partialSessions > 0) }
}

/// How a cost reads wherever part or all of it may be unknown: "Unknown", "≥ $12.40", "$12.40".
enum UsageCost {
    static func text(_ usd: Double?, atLeast: Bool, money: (Double) -> String) -> String {
        guard let usd else { return "Unknown" }
        return (atLeast ? "≥ " : "") + money(usd)
    }
}

struct UsageReport {
    struct DayCost: Identifiable, Equatable {
        var day: Date
        /// The series' key: a project key, or `otherKey`.
        var series: String
        var cost: Double
        /// Where this part starts in the day's stack: the series before it (in `series` order) below.
        var start = 0.0
        var id: String { "\(day.timeIntervalSince1970)|\(series)" }
    }

    struct Series: Equatable {
        /// A project key, or `otherKey`: what the chart's marks and colours are keyed by.
        var key: String
        /// Unique among the series (`projectNames`).
        var name: String
        /// 0…4 for the five projects that cost most in the range; nil for "Other projects".
        var slot: Int?
    }

    struct ProjectTotal: Identifiable, Equatable {
        var key: String
        var name: String
        /// What could be priced.
        var cost: Double
        var share: Double
        var sessions: Int
        var estimate: Bool
        /// Some of its sessions could be priced.
        var known: Bool
        /// Some of its sessions could not be priced, or only in part.
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
    /// The "Other projects" series' key: not a project key (those start with "-").
    static let otherKey = "\u{1}other"

    /// A series' name by its key.
    func seriesName(_ key: String) -> String { series.first { $0.key == key }?.name ?? (key == Self.otherKey ? Self.otherSeries : key) }

    // MARK: Building it, in two steps

    /// Everything but Find: worked out once per change of figures, names, running sessions, range,
    /// project or model, so typing in Find only filters and adds up (`finish`).
    struct Prepared {
        struct Item {
            var row: UsageRow
            var usage: SessionUsage
            /// Active in the range (always for all time).
            var inRange: Bool
            /// Title, folder and project, lowercased, for Find.
            var text: String
        }

        var filter = UsageFilter()
        var firstDay: String?
        var now = Date()
        var calendar = Calendar.usage
        var names: [String: String] = [:]
        var slots: [String: Int] = [:]
        var allProjects: [(key: String, name: String)] = []
        var allModels: [String] = []
        var sessionCount = 0
        /// Sessions that pass the project and model filters.
        var items: [Item] = []
    }

    static func build(usage: [String: SessionUsage], info: [String: SessionInfo], live: Set<String>,
                      filter: UsageFilter, now: Date, calendar: Calendar = .usage) -> UsageReport {
        finish(prepare(usage: usage, info: info, live: live, filter: filter, now: now, calendar: calendar), find: filter.find)
    }

    static func prepare(usage: [String: SessionUsage], info: [String: SessionInfo], live: Set<String>,
                        filter: UsageFilter, now: Date, calendar: Calendar = .usage) -> Prepared {
        var p = Prepared()
        p.filter = filter
        p.filter.find = ""
        p.now = now
        p.calendar = calendar
        p.sessionCount = usage.count
        let from = filter.range.firstDay(now: now, calendar: calendar)
        p.firstDay = from

        // Projects: named by their folder, with as many of its last parts as it takes to tell them apart.
        var folders: [String: String] = [:]
        for u in usage.values where folders[u.projectDir] == nil {
            if let f = info[u.sessionID]?.cwd ?? u.folder { folders[u.projectDir] = f }
        }
        let names = projectNames(keys: Set(usage.values.map(\.projectDir)), folders: folders)
        p.names = names
        p.allProjects = names.map { (key: $0.key, name: $0.value) }.sorted { a, b in
            let c = a.name.localizedStandardCompare(b.name)
            return c == .orderedSame ? a.key < b.key : c == .orderedAscending
        }

        // Each session's figures for the range, once.
        var costs: [String: Double] = [:]
        for u in usage.values {
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
            fill(&row, u, from: from, calendar: calendar)
            costs[u.projectDir, default: 0] += row.cost ?? 0
            if let pk = filter.project, row.projectKey != pk { continue }
            if let m = filter.model, !row.models.contains(m) { continue }
            let inRange = from.map { active(u, from: $0, calendar: calendar) } ?? true
            p.items.append(.init(row: row, usage: u, inRange: inRange,
                                 text: [row.title, row.folder, row.projectName].joined(separator: "\n").lowercased()))
        }
        // Colours: the five projects that cost most in the range get one each, whatever project, model or
        // Find show (they rank every session in the range); another range may pick others (ranked over all
        // time, a 30-day chart on real data was mostly grey).
        let ranked = costs.filter { $0.value > 0 }.sorted { ($0.value, names[$1.key] ?? "", $1.key) > ($1.value, names[$0.key] ?? "", $0.key) }
        for (i, kv) in ranked.prefix(5).enumerated() { p.slots[kv.key] = i }
        var modelCost: [String: Double] = [:]
        for u in usage.values {
            for (id, m) in u.byModel { modelCost[UsageFormat.model(id), default: 0] += m.estimatedUSD ?? 0 }
        }
        p.allModels = modelCost.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        return p
    }

    static func finish(_ p: Prepared, find: String) -> UsageReport {
        var r = UsageReport()
        r.filter = p.filter
        r.filter.find = find
        r.firstDay = p.firstDay
        r.sessionCount = p.sessionCount
        r.allProjects = p.allProjects
        r.allModels = p.allModels
        let from = p.firstDay, calendar = p.calendar
        let needle = find.trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ i: Prepared.Item) -> Bool {
            needle.isEmpty || i.text.contains(needle) || i.row.id.hasPrefix(needle)
        }
        var shown: [Prepared.Item] = []
        for i in p.items where matches(i) {
            if i.row.running && i.row.nearLimit { r.near.append(i.row) }
            if i.inRange { shown.append(i) }
        }
        shown.sort { ($0.row.lastActiveKey, $0.row.id) > ($1.row.lastActiveKey, $1.row.id) }
        r.rows = shown.map(\.row)
        r.near.sort { ($0.contextKey, $1.id) > ($1.contextKey, $0.id) }

        // Totals.
        var t = UsageTotals()
        var workDays = Set<String>()
        var unpriced = Set<String>()
        for row in r.rows {
            if let c = row.cost {
                t.cost += c
                t.pricedSessions += 1
                if row.costEstimate && c > 0 { t.costEstimate = true }
                if row.costPartial { t.partialSessions += 1; unpriced.formUnion(row.unpriced) }
            } else {
                t.unknownSessions += 1
                unpriced.formUnion(row.unpriced)
            }
            t.written += row.written
            t.workSeconds += row.workSeconds
            t.linesAdded += row.linesAdded
            t.linesRemoved += row.linesRemoved
            if row.linesEstimate && row.linesAdded + row.linesRemoved > 0 { t.linesEstimate = true }
        }
        for i in shown {
            for d in i.usage.days where from.map({ d.date >= $0 }) ?? true && d.workSeconds.reduce(0, +) > 0 { workDays.insert(d.date) }
            for c in i.usage.context.compactions where from.map({ UsageDay.key(c.at, calendar) >= $0 }) ?? true {
                t.compactions += 1
                if c.trigger == "auto" { t.autoCompactions += 1 } else if c.trigger == "manual" { t.manualCompactions += 1 }
            }
        }
        t.workDays = workDays.count
        t.sessions = r.rows.count
        t.projects = Set(r.rows.map(\.projectKey)).count
        r.totals = t
        r.unpriced = unpriced.sorted()

        // Cost per day, by project: the five with colours, the rest together. A session's days carry its
        // range cost in proportion to their own estimate (`dayShares`), so a day adds up to the rows.
        var perDay: [String: [String: Double]] = [:]
        var earliest: String?
        for i in shown {
            guard let cost = i.row.cost, cost > 0 else { continue }
            let key = p.slots[i.row.projectKey] != nil ? i.row.projectKey : otherKey
            for (day, share) in dayShares(i.usage, from: from, kind: i.row.costKind) where share > 0 {
                perDay[day, default: [:]][key, default: 0] += cost * share
                if earliest.map({ day < $0 }) ?? true { earliest = day }
            }
        }
        for (dayKey, byKey) in perDay {
            guard let day = UsageDay.date(dayKey, calendar) else { continue }
            for (k, c) in byKey where c > 0 { r.days.append(.init(day: day, series: k, cost: c)) }
        }
        if let start = (from ?? earliest).flatMap({ UsageDay.date($0, calendar) }) {
            let end = calendar.startOfDay(for: p.now)
            r.dayDomain = min(start, end)...max(start, end)
        }
        let present = Set(r.days.map(\.series))
        r.series = p.slots.sorted { $0.value < $1.value }.compactMap { k, s in
            present.contains(k) ? Series(key: k, name: p.names[k] ?? k, slot: s) : nil
        } + (present.contains(otherKey) ? [Series(key: otherKey, name: otherSeries, slot: nil)] : [])
        // Stacked in the legend's order, the same on every day.
        var rank: [String: Int] = [:]
        for (n, s) in r.series.enumerated() where rank[s.key] == nil { rank[s.key] = n }
        r.days.sort { ($0.day, rank[$0.series] ?? 99, $0.series) < ($1.day, rank[$1.series] ?? 99, $1.series) }
        var below: (day: Date, sum: Double)?
        for n in r.days.indices {
            let base = below.map { $0.day == r.days[n].day ? $0.sum : 0 } ?? 0
            r.days[n].start = base
            below = (r.days[n].day, base + r.days[n].cost)
        }

        // By project.
        var byProject: [String: ProjectTotal] = [:]
        for row in r.rows {
            var pt = byProject[row.projectKey] ?? ProjectTotal(key: row.projectKey, name: row.projectName, cost: 0, share: 0, sessions: 0,
                                                               estimate: false, known: false, incomplete: false, slot: p.slots[row.projectKey])
            pt.cost += row.cost ?? 0
            pt.sessions += 1
            if row.cost != nil { pt.known = true }
            if row.costEstimate && (row.cost ?? 0) > 0 { pt.estimate = true }
            if row.cost == nil || row.costPartial { pt.incomplete = true }
            byProject[row.projectKey] = pt
        }
        r.projects = byProject.values.map { pt in
            var pt = pt
            pt.share = t.cost > 0 ? pt.cost / t.cost : 0
            return pt
        }.sorted { ($0.cost, $1.name, $1.key) > ($1.cost, $0.name, $0.key) }

        // By model: each session's cost in the range split between its models (the days do not say which
        // model replied when): by their estimates, or by their output where Claude Code's figure also
        // covers models with no price.
        var byModel: [String: (cost: Double?, written: Int)] = [:]
        for i in shown {
            let u = i.usage
            let share = outputShare(u, from: from)
            let priced = u.byModel.values.compactMap(\.estimatedUSD).reduce(0, +)
            let byOutput = u.cost.source == .claudeCode && (priced <= 0 || u.byModel.values.contains { $0.estimatedUSD == nil })
            let output = u.byModel.values.reduce(0) { $0 + $1.tokens.output }
            for (id, m) in u.byModel {
                let name = UsageFormat.model(id)
                var e = byModel[name] ?? (nil, 0)
                e.written += Int((Double(m.tokens.output) * share).rounded())
                if let c = i.row.cost {
                    if byOutput, output > 0 {
                        e.cost = (e.cost ?? 0) + c * Double(m.tokens.output) / Double(output)
                    } else if !byOutput, let est = m.estimatedUSD, priced > 0 {
                        e.cost = (e.cost ?? 0) + c * est / priced
                    }
                }
                byModel[name] = e
            }
        }
        let modelTotal = byModel.values.compactMap(\.cost).reduce(0, +)
        r.models = byModel.map { ModelTotal(name: $0.key, cost: $0.value.cost, share: modelTotal > 0 ? ($0.value.cost ?? 0) / modelTotal : 0,
                                             written: $0.value.written) }
            .filter { $0.written > 0 || ($0.cost ?? 0) > 0 }
            .sorted { (($0.cost ?? -1), $0.written, $1.name) > (($1.cost ?? -1), $1.written, $0.name) }

        r.heat = SessionUsage.activity(shown.map(\.usage), from: from)
        return r
    }

    // MARK: One session in the range

    /// The session did something on or after `from`: a reply, working time or a compaction.
    static func active(_ u: SessionUsage, from: String, calendar: Calendar) -> Bool {
        u.days.contains { $0.date >= from && ($0.replies > 0 || $0.workSeconds.reduce(0, +) > 0) }
            || u.context.compactions.contains { UsageDay.key($0.at, calendar) >= from }
    }

    /// Every day of the session is on or after `from`: the range holds all of it.
    static func wholly(_ u: SessionUsage, from: String) -> Bool { u.days.allSatisfy { $0.date >= from } }

    /// Share of the session's output written on or after `from` (1 for all time).
    static func outputShare(_ u: SessionUsage, from: String?) -> Double {
        guard let from else { return 1 }
        let all = u.days.reduce(0) { $0 + $1.tokens.output }
        guard all > 0 else { return wholly(u, from: from) ? 1 : 0 }
        return Double(u.days.filter { $0.date >= from }.reduce(0) { $0 + $1.tokens.output }) / Double(all)
    }

    /// Each day's share of the session's cost in the range (its days on or after `from`). An estimate is
    /// its days' own estimates; Claude Code's figure goes by each day's estimate when every day with
    /// replies has one, else by working time, else by output, else by replies.
    static func dayShares(_ u: SessionUsage, from: String?, kind: UsageRow.CostKind) -> [(day: String, share: Double)] {
        let days = u.days.filter { d in from.map { d.date >= $0 } ?? true }
        let replying = u.days.filter { $0.replies > 0 }
        func by(_ weight: (SessionUsage.Day) -> Double) -> [(day: String, share: Double)]? {
            let all = u.days.reduce(0) { $0 + weight($1) }
            guard all > 0 else { return nil }
            let inside = days.reduce(0) { $0 + weight($1) }
            guard inside > 0 else { return [] }
            // Shares of what falls in the range, so a row's cost spreads over its days in it.
            return days.map { ($0.date, weight($0) / inside) }
        }
        if kind == .estimate { return by { $0.estimatedUSD ?? 0 } ?? [] }
        if !replying.isEmpty, replying.allSatisfy({ $0.estimatedUSD != nil }), let s = by({ $0.estimatedUSD ?? 0 }) { return s }
        return by { $0.workSeconds.reduce(0, +) } ?? by { Double($0.tokens.output) } ?? by { Double($0.replies) } ?? []
    }

    /// A session's cost in the range, and how it was arrived at:
    /// - all time, or a session wholly inside the range: its own cost (Claude Code's figure as it is);
    /// - Claude Code's figure cut by the range: split by day (by each day's estimate when every day has
    ///   one, else by working time), est.;
    /// - an estimate: its days' estimates; nil when none of them could be priced.
    static func cost(_ u: SessionUsage, from: String?) -> (usd: Double?, kind: UsageRow.CostKind) {
        let cc = u.cost.source == .claudeCode && u.cost.usd != nil
        guard let from, !wholly(u, from: from) else { return (u.cost.usd, cc ? .claudeCode : .estimate) }
        if cc, let usd = u.cost.usd {
            let replying = u.days.filter { $0.replies > 0 }
            if let total = u.cost.estimateUSD, total > 0, !replying.isEmpty, replying.allSatisfy({ $0.estimatedUSD != nil }) {
                return (u.days.filter { $0.date >= from }.compactMap { u.cost(of: $0) }.reduce(0, +), .claudeCodeSplit)
            }
            return (usd * timeShare(u, from: from), .claudeCodeSplit)
        }
        var sum = 0.0, priced = false, missing = false
        for d in u.days where d.date >= from && d.replies > 0 {
            if let e = d.estimatedUSD { sum += e; priced = true } else { missing = true }
        }
        return (priced ? sum : (missing ? nil : 0), .estimate)
    }

    /// Share of the session's working time on or after `from`; by output, then replies, when it has none.
    static func timeShare(_ u: SessionUsage, from: String) -> Double {
        for weight in [{ (d: SessionUsage.Day) in d.workSeconds.reduce(0, +) }, { Double($0.tokens.output) }, { Double($0.replies) }] {
            let all = u.days.reduce(0) { $0 + weight($1) }
            if all > 0 { return u.days.filter { $0.date >= from }.reduce(0) { $0 + weight($1) } / all }
        }
        return 0
    }

    /// A session's figures for the range (`cost(_:from:)` for its cost). Written, Claude's time and
    /// compactions: its days, or its own totals for all time. Lines: its own count when the range holds
    /// all of it, else its days' share (`lines(of:)`), est. (the split by day is counted here).
    static func fill(_ row: inout UsageRow, _ u: SessionUsage, from: String?, calendar: Calendar) {
        let c = cost(u, from: from)
        row.cost = c.usd
        row.costKind = c.kind
        // Claude Code's figure covers every reply, priced here or not.
        row.costPartial = c.kind == .estimate && c.usd != nil && !u.cost.unpriced.isEmpty
        guard let from else {
            row.written = u.tokens.output
            row.workSeconds = u.turns.seconds
            row.compactions = u.context.compactions.count
            row.linesAdded = u.lines.added
            row.linesRemoved = u.lines.removed
            row.linesEstimate = u.lines.source == .estimate
            return
        }
        for d in u.days where d.date >= from {
            row.written += d.tokens.output
            row.workSeconds += d.workSeconds.reduce(0, +)
        }
        row.compactions = u.context.compactions.filter { UsageDay.key($0.at, calendar) >= from }.count
        if wholly(u, from: from) {
            row.linesAdded = u.lines.added
            row.linesRemoved = u.lines.removed
            row.linesEstimate = u.lines.source == .estimate
        } else {
            for d in u.days where d.date >= from {
                let l = u.lines(of: d)
                row.linesAdded += l.added
                row.linesRemoved += l.removed
            }
            row.linesEstimate = true
        }
    }

    /// Each project's name, unique: the last part of its folder, with as many parts before it as it takes
    /// to tell projects apart ("web", then "app/web", then "client1/app/web"); "~" for your home folder,
    /// not your account name. "Other projects" is the chart's, never a project's. Whatever is still the
    /// same after that (no parts left) gets a number.
    static func projectNames(keys: Set<String>, folders: [String: String], home: String = Paths.home) -> [String: String] {
        let sorted = keys.sorted()
        var parts: [String: [String]] = [:]
        for k in sorted {
            guard let f = folders[k] else { parts[k] = [k]; continue }
            if f == home { parts[k] = ["~"]; continue }
            let p = f.split(separator: "/").map(String.init)
            parts[k] = p.isEmpty ? [k] : p
        }
        var depth = Dictionary(sorted.map { ($0, 1) }, uniquingKeysWith: { a, _ in a })
        func name(_ k: String) -> String { parts[k]!.suffix(depth[k]!).joined(separator: "/") }
        while true {
            var byName: [String: [String]] = [:]
            for k in sorted { byName[name(k), default: []].append(k) }
            var grew = false
            for (n, ks) in byName where ks.count > 1 || n == otherSeries {
                for k in ks where depth[k]! < parts[k]!.count { depth[k]! += 1; grew = true }
            }
            if !grew { break }
        }
        var out: [String: String] = [:]
        var taken: Set<String> = [otherSeries]
        var byName: [String: [String]] = [:]
        for k in sorted { byName[name(k), default: []].append(k) }
        for k in sorted {
            let n = name(k)
            if byName[n]!.count == 1 && !taken.contains(n) { out[k] = n; taken.insert(n) }
        }
        // Still alike: the first (by key) keeps the name, the others are numbered.
        for k in sorted where out[k] == nil {
            var n = name(k), i = 2
            while taken.contains(n) { n = "\(name(k)) (\(i))"; i += 1 }
            out[k] = n
            taken.insert(n)
        }
        return out
    }
}
/// Export CSV: the rows the filters show, figures as plain numbers (dot decimals, no symbols), UTF-8
/// with a byte order mark so Excel reads ₹ and accents, CRLF line ends (RFC 4180).
enum UsageCSV {
    static func make(_ rows: [UsageRow], second: UsageModel.SecondCurrency?, calendar: Calendar = .usage) -> String {
        var header = ["Session", "Project", "Folder", "Session ID", "Last active", "Context tokens", "Context %",
                      "Compactions", "Cost (USD at API prices)", "Cost source"]
        // The rate's own day, as the service gave it (a calendar day, not a moment in your time zone).
        if let s = second { header.append("Cost (\(s.code) at \(number(s.perUSD, 4)) per USD, \(RateRule.text(s.date)))") }
        header += ["Written by Claude (output tokens)", "Claude worked (hours)", "Lines added", "Lines removed", "Lines source"]
        let iso = ISO8601DateFormatter()
        iso.timeZone = calendar.timeZone
        iso.formatOptions = [.withInternetDateTime]
        var lines = [header.map { field($0, text: true) }.joined(separator: ",")]
        for r in rows {
            let source: String
            switch (r.cost, r.costKind) {
            case (nil, _): source = "unknown"
            case (_, .claudeCode): source = "Claude Code"
            case (_, .claudeCodeSplit): source = "Claude Code, split by day (estimate)"
            case (_, .estimate): source = r.costPartial ? "estimate, part unpriced" : "estimate"
            }
            let last: String = r.lastActive.map { iso.string(from: $0) } ?? ""
            let context: String = r.contextNow.map { String($0) } ?? ""
            let share: String = r.contextFraction.map { number($0 * 100, 1) } ?? ""
            let cost: String = r.cost.map { number($0, 4) } ?? ""
            // Every text column is guarded, the session ID too (it comes from a file name).
            var cells: [String] = [r.title, r.projectName, r.folder, r.id].map { field($0, text: true) }
            cells += [last, context, share, String(r.compactions), cost, field(source, text: true)]
            if let s = second {
                let converted: String = r.cost.map { number($0 * s.perUSD, 2) } ?? ""
                cells.append(converted)
            }
            cells += [String(r.written), number(r.workSeconds / 3600, 2), String(r.linesAdded), String(r.linesRemoved),
                      field(r.linesEstimate ? "estimate" : "Claude Code", text: true)]
            lines.append(cells.joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }

    /// What starts a formula in a spreadsheet, in ASCII and in the full-width forms Excel also reads.
    static let formulaStarts: Set<Character> = ["=", "+", "-", "@", "＝", "＋", "－", "＠"]

    /// Quoted when it holds a comma, a quote or a line break (quotes doubled). Text a spreadsheet would
    /// run as a formula gets a leading apostrophe: one that starts with a tab or CR, or whose first
    /// character after any leading spaces is =, +, -, @ or their full-width forms.
    static func field(_ s: String, text: Bool = false) -> String {
        var v = s
        if text {
            // By scalar: "\r\n" is one Character.
            let first = v.unicodeScalars.first
            let firstShown = v.first { !$0.isWhitespace }
            if first == "\t" || first == "\r" || firstShown.map(formulaStarts.contains) == true { v = "'" + v }
        }
        guard v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return v }
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
    static func fileName(_ range: UsageRange, now: Date, calendar: Calendar = .usage) -> String {
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
