import Foundation

/// Folds one session's records into a `SessionUsage`. Pure and order-sensitive: `UsageReader` feeds it
/// the main transcript's lines in order, then each subagent's; the demo feeds it made-up ones.
struct UsageBuilder {
    let sessionID: String
    let projectDir: String
    var calendar: Calendar
    /// Main transcripts among the files (several for copies of one conversation): their context points
    /// are put in time order.
    var mains = 1

    /// One API call. A reply is written as several lines, each repeating its usage as it stood when the
    /// line was written: the output count grows, so the last line's is the reply's.
    struct Reply {
        var at: Date?
        var model: String
        var tokens: SessionUsage.Tokens
        /// `usage.speed == "fast"` and `usage.inference_geo == "us"`: both change the price.
        var fast = false
        var usOnly = false
        var webSearches = 0
        var subagent: Bool
    }

    struct CostState {
        var usd: Double
        var output: Int
        var cacheRead: Int
        var linesAdded: Int?
        var linesRemoved: Int?
        var unknownModelCost = false
    }

    /// Tools whose call waits for you (a question, a plan to approve): never tool time.
    static let waitingTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    private var replies: [String: Reply] = [:]
    private var replyFile: [String: Int] = [:]
    private var replyOrder: [String] = []
    private var errorIDs = Set<String>()
    /// Main-thread events in transcript order, for the context curve and "context now".
    private enum Mark { case reply(String), compaction(Int) }
    private var mainMarks: [(mark: Mark, at: Date?)] = []
    private var compactions: [SessionUsage.Compaction] = []
    /// A turn: from a prompt (or a reply with no prompt before it) to the next; Claude Code's
    /// `turn_duration` when it wrote one, else from the prompt to its last reply.
    private struct Turn {
        var start: Date?
        var lastReply: Date?
        var record: (end: Date, seconds: Double)?
    }
    private var turns: [Turn] = []
    private var toolNames: [String: String] = [:]
    private var toolStarts: [String: Date] = [:]
    private var toolIntervals: [(start: Date, end: Date, name: String)] = []
    private var errors: [SessionUsage.APIError] = []
    private var costState: CostState?
    private var costStateFile = 0
    private var costStateCurrent = false
    private var estimatedLines = (added: 0, removed: 0)
    private var lineEdits: [(at: Date, added: Int, removed: Int)] = []
    private var cwds: [String] = []
    private var first: Date?
    private var last: Date?
    var subagentCount = 0

    init(sessionID: String, projectDir: String, calendar: Calendar = .usage) {
        self.sessionID = sessionID
        self.projectDir = projectDir
        self.calendar = calendar
    }

    mutating func saw(_ at: Date?) {
        guard let at, at != .distantPast else { return }
        if first.map({ at < $0 }) ?? true { first = at }
        if last.map({ at > $0 }) ?? true { last = at }
    }

    mutating func noteCwd(_ cwd: String) {
        if !cwd.isEmpty, !cwds.contains(cwd) { cwds.append(cwd) }
    }

    /// One assistant line's usage. Lines of the same reply share `id` (Claude Code's `message.id`,
    /// else its `requestId`); the last one seen wins. A reply belongs to the file it first appears in:
    /// a forked subagent's transcript starts with copies of the main thread's replies.
    mutating func reply(id: String, _ r: Reply, file: Int = 0) {
        saw(r.at)
        if let owner = replyFile[id] {
            guard owner == file else { return }
        } else {
            replyFile[id] = file
            replyOrder.append(id)
            if !r.subagent { mainMarks.append((.reply(id), r.at)) }
        }
        replies[id] = r
        guard !r.subagent else { return }
        if file == costStateFile { costStateCurrent = false }
        if let at = r.at {
            if let i = turns.indices.last, turns[i].record == nil {
                turns[i].lastReply = max(turns[i].lastReply ?? at, at)
            } else {
                turns.append(Turn(start: at, lastReply: at))     // Claude went on without a prompt
            }
        }
    }

    /// A prompt you typed (or one Claude Code sent for you): where a turn begins.
    mutating func prompt(at: Date?) {
        saw(at)
        guard let at else { return }
        turns.append(Turn(start: at))
    }

    mutating func compaction(_ c: SessionUsage.Compaction) {
        saw(c.at)
        mainMarks.append((.compaction(compactions.count), c.at))
        compactions.append(c)
    }

    /// Claude Code's `turn_duration`: written when a turn ends, with how long Claude worked in it.
    mutating func turn(end: Date, seconds: Double) {
        saw(end)
        let s = min(max(0, seconds), UsageLine.Limits.seconds)
        if let i = turns.indices.last, turns[i].record == nil, (turns[i].start ?? .distantPast) <= end {
            turns[i].record = (end, s)
        } else {
            turns.append(Turn(record: (end, s)))
        }
    }

    /// Each `tool_use` block once, by its ID; only the main thread's count towards tool time.
    mutating func toolUse(id: String, name: String, at: Date?, subagent: Bool) {
        guard toolNames[id] == nil else { return }
        toolNames[id] = name
        if !subagent, let at { toolStarts[id] = at }
    }

    mutating func toolResult(id: String, at: Date?) {
        guard let at, let start = toolStarts.removeValue(forKey: id), at >= start else { return }
        toolIntervals.append((start, at, toolNames[id] ?? ""))
    }

    /// Claude Code's "API Error: …" line, once per `id` (its message ID) when it has one. One without
    /// a timestamp keeps `at == .distantPast` and moves neither end of the session.
    mutating func apiError(_ e: SessionUsage.APIError, id: String? = nil) {
        if let id { guard errorIDs.insert(id).inserted else { return } }
        saw(e.at)
        errors.append(e)
    }

    /// Claude Code's `cost-state`, main thread only. It stays current until a reply follows in the same
    /// transcript (a copy of the conversation filed elsewhere has records of its own).
    mutating func costState(_ c: CostState, file: Int = 0) {
        costState = c
        costStateFile = file
        costStateCurrent = true
    }

    /// Lines one Edit or Write changed, on the day of `at` (its tool result).
    mutating func editedLines(added: Int, removed: Int, at: Date? = nil) {
        estimatedLines.added = estimatedLines.added.addingSaturating(added)
        estimatedLines.removed = estimatedLines.removed.addingSaturating(removed)
        if let at { lineEdits.append((at, added, removed)) }
    }

    /// Whether Claude Code's figure is this transcript's: written after the last main-thread reply, and
    /// counting at least (within 1%) the output and cache reads of every reply here. A resumed process
    /// starts its counter again from zero, so its record covers only its own part (docs/usage.md).
    static func covers(_ c: CostState, output: Int, cacheRead: Int) -> Bool {
        !c.unknownModelCost && Double(c.output) >= Double(output) * 0.99 - 100
            && Double(c.cacheRead) >= Double(cacheRead) * 0.99 - 1000
    }

    func build() -> SessionUsage {
        var u = SessionUsage(sessionID: sessionID, projectDir: projectDir)
        u.folder = cwds.first { ProjectDirs.matches($0, projectDir) } ?? cwds.first
        u.firstActive = first
        u.lastActive = last
        u.subagents.count = subagentCount

        // Tokens and estimates, per reply: Haiku 5.5's price depends on each call's prompt length.
        var days: [String: SessionUsage.Day] = [:]
        var estimate = 0.0, subEstimate = 0.0
        var anyPriced = false, anySubPriced = false
        var unpriced = Set<String>()
        for id in replyOrder {
            guard let r = replies[id] else { continue }
            u.replies += 1
            u.tokens.add(r.tokens)
            var m = u.byModel[r.model] ?? SessionUsage.ModelUsage()
            m.tokens.add(r.tokens)
            m.replies += 1
            let usd = Pricing.cost(model: r.model, r.tokens, speed: r.fast ? "fast" : nil, geo: r.usOnly ? "us" : nil, webSearches: r.webSearches)
            if let usd {
                m.estimatedUSD = (m.estimatedUSD ?? 0) + usd
                estimate += usd; anyPriced = true
            } else {
                m.unpricedReplies += 1
                unpriced.insert(r.model)
            }
            u.byModel[r.model] = m
            if r.subagent {
                u.subagents.tokens.add(r.tokens)
                if let usd { subEstimate += usd; anySubPriced = true }
            }
            if let at = r.at {
                let key = dayKey(at)
                var d = days[key.date] ?? SessionUsage.Day(date: key.date, weekday: key.weekday)
                d.tokens.add(r.tokens)
                d.replies += 1
                if let usd { d.estimatedUSD = (d.estimatedUSD ?? 0) + usd }
                days[key.date] = d
            }
        }
        u.models = u.byModel.sorted { ($0.value.tokens.output, $1.key) > ($1.value.tokens.output, $0.key) }.map(\.key)
        u.subagents.estimatedUSD = anySubPriced ? subEstimate : nil
        u.cost.estimateUSD = anyPriced ? estimate : (u.replies == 0 ? 0 : nil)
        u.cost.unpriced = unpriced.sorted()
        u.cost.claudeCodeUSD = costState?.usd
        let claudeCode = costState.flatMap { c in
            costStateCurrent && Self.covers(c, output: u.tokens.output, cacheRead: u.tokens.cacheRead) ? c : nil
        }
        if let c = claudeCode {
            u.cost.usd = c.usd
            u.cost.source = .claudeCode
        } else {
            u.cost.usd = u.cost.estimateUSD
            u.cost.source = .estimate
        }

        // Context: the main thread's, reply by reply; a compaction after the last reply sets "now"
        // (unknown when it did not say how much it kept). Copies of one conversation: in time order.
        var marks = mainMarks
        if mains > 1 {
            var key = Date.distantPast
            let keyed = marks.enumerated().map { i, m -> (Date, Int) in key = m.at ?? key; return (key, i) }
            marks = keyed.sorted { $0 < $1 }.map { marks[$0.1] }
        }
        for (mark, _) in marks {
            switch mark {
            case .reply(let id):
                guard let r = replies[id] else { continue }
                if let at = r.at { u.context.replies.append(.init(at: at, tokens: r.tokens.prompt)) }
                u.context.now = r.tokens.prompt
                u.context.model = r.model
            case .compaction(let i):
                u.context.now = compactions[i].postTokens
            }
        }
        u.context.compactions = compactions

        // Turns: each one Claude Code's own `turn_duration` when it wrote one, else from its prompt to
        // its last reply (not where a recorded turn already covers that time, as when a prompt you
        // queued splits one turn in two). An estimate longer than any turn can be is left out.
        let recorded = Self.merge(turns.compactMap { t in t.record.map { ($0.end.addingTimeInterval(-$0.seconds), $0.end) } })
        var working: [(Date, Date)] = []
        var estimatedTurns = 0
        for t in turns {
            if let r = t.record {
                u.turns.count += 1
                u.turns.seconds += r.seconds
                u.turns.longestSeconds = max(u.turns.longestSeconds, r.seconds)
                working.append((r.end.addingTimeInterval(-r.seconds), r.end))
            } else if let start = t.start, let end = t.lastReply, end > start,
                      end.timeIntervalSince(start) <= UsageLine.Limits.seconds {
                let pieces = Self.subtract((start, end), recorded)
                let secs = Self.length(pieces)
                guard secs > 0 else { continue }
                u.turns.count += 1
                u.turns.seconds += secs
                u.turns.longestSeconds = max(u.turns.longestSeconds, secs)
                working += pieces
                estimatedTurns += 1
            }
        }
        u.turns.source = estimatedTurns > 0 || recorded.isEmpty ? .estimate : .claudeCode
        for (start, end) in working { spread(start, end, into: &days) }
        for e in lineEdits {
            let key = dayKey(e.at)
            var d = days[key.date] ?? SessionUsage.Day(date: key.date, weekday: key.weekday)
            d.linesAdded = d.linesAdded.addingSaturating(e.added)
            d.linesRemoved = d.linesRemoved.addingSaturating(e.removed)
            days[key.date] = d
        }
        u.days = days.values.sorted { $0.date < $1.date }

        // Tool time: the main thread's calls, never one that waits for you, and only while Claude was
        // working (a permission prompt sits inside its call's interval, outside the turn's work).
        let calls = Self.merge(toolIntervals.filter { !Self.waitingTools.contains($0.name) }.map { ($0.start, $0.end) })
        u.toolSeconds = Self.length(Self.intersect(calls, Self.merge(working)))
        for name in toolNames.values { u.tools[name, default: 0] += 1 }
        u.apiErrors = errors.sorted { $0.at < $1.at }

        if let c = claudeCode, let added = c.linesAdded, let removed = c.linesRemoved {
            u.lines = .init(added: added, removed: removed, source: .claudeCode)
        } else {
            u.lines = .init(added: estimatedLines.added, removed: estimatedLines.removed, source: .estimate)
        }
        return u
    }

    private func dayKey(_ at: Date) -> (date: String, weekday: Int) {
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: at)
        return (String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0), c.weekday ?? 1)
    }

    /// Adds working time to each local day and hour it falls in (at most one turn's worth).
    private func spread(_ start: Date, _ end: Date, into days: inout [String: SessionUsage.Day]) {
        var t = start
        let stopAt = min(end, start.addingTimeInterval(UsageLine.Limits.seconds))
        while t < stopAt {
            guard let hour = calendar.dateInterval(of: .hour, for: t) else { return }
            let stop = min(stopAt, hour.end)
            let key = dayKey(t)
            var d = days[key.date] ?? SessionUsage.Day(date: key.date, weekday: key.weekday)
            let h = calendar.component(.hour, from: t)
            if (0..<24).contains(h) { d.workSeconds[h] += stop.timeIntervalSince(t) }
            days[key.date] = d
            t = stop > t ? stop : stopAt
        }
    }

    /// Intervals sorted and joined where they overlap or touch.
    static func merge(_ intervals: [(Date, Date)]) -> [(Date, Date)] {
        var out: [(Date, Date)] = []
        for (a, b) in intervals.filter({ $0.1 > $0.0 }).sorted(by: { $0.0 < $1.0 }) {
            if let l = out.last, a <= l.1 { out[out.count - 1].1 = max(l.1, b) } else { out.append((a, b)) }
        }
        return out
    }

    static func length(_ intervals: [(Date, Date)]) -> Double {
        merge(intervals).reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
    }

    /// Total length of a set of intervals, overlaps counted once.
    static func union(_ intervals: [(Date, Date)]) -> Double { length(intervals) }

    /// Where two merged sets of intervals overlap.
    static func intersect(_ a: [(Date, Date)], _ b: [(Date, Date)]) -> [(Date, Date)] {
        var out: [(Date, Date)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            let lo = max(a[i].0, b[j].0), hi = min(a[i].1, b[j].1)
            if hi > lo { out.append((lo, hi)) }
            if a[i].1 < b[j].1 { i += 1 } else { j += 1 }
        }
        return out
    }

    /// An interval without the parts a merged set covers.
    static func subtract(_ x: (Date, Date), _ cover: [(Date, Date)]) -> [(Date, Date)] {
        var out: [(Date, Date)] = []
        var start = x.0
        for (a, b) in cover where b > start && a < x.1 {
            if a > start { out.append((start, a)) }
            start = max(start, b)
        }
        if x.1 > start { out.append((start, x.1)) }
        return out
    }
}

extension SessionUsage {
    init(sessionID: String, projectDir: String) {
        self.sessionID = sessionID
        self.projectDir = projectDir
    }
}
