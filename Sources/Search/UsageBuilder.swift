import Foundation

/// Folds one session's records into a `SessionUsage`. Pure and order-sensitive: `UsageReader` feeds it
/// the main transcript's lines in order, then each subagent's; the demo feeds it made-up ones.
struct UsageBuilder {
    let sessionID: String
    let projectDir: String
    var calendar: Calendar

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

    private var replies: [String: Reply] = [:]
    private var replyFile: [String: Int] = [:]
    private var replyOrder: [String] = []
    private var errorIDs = Set<String>()
    /// Main-thread events in transcript order, for the context curve and "context now".
    private enum Mark { case reply(String), compaction(Int) }
    private var mainMarks: [Mark] = []
    private var compactions: [SessionUsage.Compaction] = []
    private var turnRecords: [(end: Date, seconds: Double)] = []
    private var prompts: [Date] = []
    private var lastMainReplyAt: [Date] = []    // per prompt: the last main-thread reply after it
    private var toolNames: [String: String] = [:]
    private var toolStarts: [String: Date] = [:]
    private var toolIntervals: [(Date, Date)] = []
    private var errors: [SessionUsage.APIError] = []
    private var costState: CostState?
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
        guard let at else { return }
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
            if !r.subagent { mainMarks.append(.reply(id)) }
        }
        replies[id] = r
        if !r.subagent {
            costStateCurrent = false
            if !prompts.isEmpty, let at = r.at { lastMainReplyAt[prompts.count - 1] = at }
        }
    }

    /// A prompt you typed (or one Claude Code sent for you): where an estimated turn begins.
    mutating func prompt(at: Date?) {
        saw(at)
        guard let at else { return }
        prompts.append(at)
        lastMainReplyAt.append(.distantPast)
    }

    mutating func compaction(_ c: SessionUsage.Compaction) {
        saw(c.at)
        mainMarks.append(.compaction(compactions.count))
        compactions.append(c)
    }

    /// Claude Code's `turn_duration`: written when a turn ends, with how long it took.
    mutating func turn(end: Date, seconds: Double) {
        saw(end)
        turnRecords.append((end, max(0, seconds)))
    }

    /// Each `tool_use` block once, by its ID; only the main thread's count towards tool time.
    mutating func toolUse(id: String, name: String, at: Date?, subagent: Bool) {
        guard toolNames[id] == nil else { return }
        toolNames[id] = name
        if !subagent, let at { toolStarts[id] = at }
    }

    mutating func toolResult(id: String, at: Date?) {
        guard let at, let start = toolStarts.removeValue(forKey: id), at >= start else { return }
        toolIntervals.append((start, at))
    }

    /// Claude Code's "API Error: …" line, once per `id` (its message ID) when it has one.
    mutating func apiError(_ e: SessionUsage.APIError, id: String? = nil) {
        if let id { guard errorIDs.insert(id).inserted else { return } }
        saw(e.at)
        errors.append(e)
    }

    /// Claude Code's `cost-state`, main thread only. It stays current until a main-thread reply follows.
    mutating func costState(_ c: CostState) {
        costState = c
        costStateCurrent = true
    }

    /// Lines one Edit or Write changed, on the day of `at` (its tool result).
    mutating func editedLines(added: Int, removed: Int, at: Date? = nil) {
        estimatedLines.added += added
        estimatedLines.removed += removed
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
        if let c = costState, costStateCurrent, Self.covers(c, output: u.tokens.output, cacheRead: u.tokens.cacheRead) {
            u.cost.usd = c.usd
            u.cost.source = .claudeCode
        } else {
            u.cost.usd = u.cost.estimateUSD
            u.cost.source = .estimate
        }

        // Context: the main thread's, reply by reply; a compaction after the last reply sets "now".
        for mark in mainMarks {
            switch mark {
            case .reply(let id):
                guard let r = replies[id] else { continue }
                if let at = r.at { u.context.replies.append(.init(at: at, tokens: r.tokens.prompt)) }
                u.context.now = r.tokens.prompt
                u.context.model = r.model
            case .compaction(let i):
                if let post = compactions[i].postTokens { u.context.now = post }
            }
        }
        u.context.compactions = compactions

        // Turns: Claude Code's own durations, else from each prompt to the last reply before the next one.
        var intervals: [(Date, Date)] = []
        if !turnRecords.isEmpty {
            u.turns.source = .claudeCode
            for t in turnRecords {
                u.turns.count += 1
                u.turns.seconds += t.seconds
                u.turns.longestSeconds = max(u.turns.longestSeconds, t.seconds)
                intervals.append((t.end.addingTimeInterval(-t.seconds), t.end))
            }
        } else {
            u.turns.source = .estimate
            for (start, end) in zip(prompts, lastMainReplyAt) where end > start {
                let secs = end.timeIntervalSince(start)
                u.turns.count += 1
                u.turns.seconds += secs
                u.turns.longestSeconds = max(u.turns.longestSeconds, secs)
                intervals.append((start, end))
            }
        }
        for (start, end) in intervals { spread(start, end, into: &days) }
        for e in lineEdits {
            let key = dayKey(e.at)
            var d = days[key.date] ?? SessionUsage.Day(date: key.date, weekday: key.weekday)
            d.linesAdded += e.added
            d.linesRemoved += e.removed
            days[key.date] = d
        }
        u.days = days.values.sorted { $0.date < $1.date }

        u.toolSeconds = Self.union(toolIntervals)
        for name in toolNames.values { u.tools[name, default: 0] += 1 }
        u.apiErrors = errors.sorted { $0.at < $1.at }

        if let c = costState, costStateCurrent, let added = c.linesAdded, let removed = c.linesRemoved,
           Self.covers(c, output: u.tokens.output, cacheRead: u.tokens.cacheRead) {
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

    /// Adds working time to each local day and hour it falls in.
    private func spread(_ start: Date, _ end: Date, into days: inout [String: SessionUsage.Day]) {
        var t = start
        while t < end {
            guard let hour = calendar.dateInterval(of: .hour, for: t) else { return }
            let stop = min(end, hour.end)
            let key = dayKey(t)
            var d = days[key.date] ?? SessionUsage.Day(date: key.date, weekday: key.weekday)
            let h = calendar.component(.hour, from: t)
            if (0..<24).contains(h) { d.workSeconds[h] += stop.timeIntervalSince(t) }
            days[key.date] = d
            t = stop > t ? stop : end
        }
    }

    /// Total length of a set of intervals, overlaps counted once.
    static func union(_ intervals: [(Date, Date)]) -> Double {
        var total = 0.0
        var current: (Date, Date)?
        for (a, b) in intervals.sorted(by: { $0.0 < $1.0 }) {
            if let c = current, a <= c.1 {
                current = (c.0, max(c.1, b))
            } else {
                if let c = current { total += c.1.timeIntervalSince(c.0) }
                current = (a, b)
            }
        }
        if let c = current { total += c.1.timeIntervalSince(c.0) }
        return total
    }
}

extension SessionUsage {
    init(sessionID: String, projectDir: String) {
        self.sessionID = sessionID
        self.projectDir = projectDir
    }
}
