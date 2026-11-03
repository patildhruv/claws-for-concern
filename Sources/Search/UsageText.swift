import Foundation

/// What the list sorts by for Cost and Context (`SortMode`), worked out from each session's figures.
struct UsageRank: Equatable {
    /// Dollars at API prices, as `SessionUsage.Cost.usd`; nil when unknown.
    var cost: Double?
    /// How full the context is now, 0…1: the share of the model's window, or, for a model with no
    /// known window, tokens against the 1M the near-limit rule implies (800K counts as 80%).
    var context: Double?

    init(cost: Double?, context: Double?) {
        self.cost = cost
        self.context = context
    }

    /// nil for a session Claude has not replied in yet: it sorts with the sessions that have no figures.
    init?(_ u: SessionUsage) {
        guard u.replies > 0 else { return nil }
        cost = u.cost.usd
        if let f = u.contextFraction {
            context = f
        } else if let now = u.context.now {
            context = Double(now) / (Double(ContextWindows.nearLimitWithoutWindow) / 0.8)
        }
    }

    /// Keyed by transcript path (`UsageModel.byFile`: a session ID filed in two project folders is two
    /// rows, each with its own figures), or by session ID when there are no per-transcript figures at
    /// all (the demo). Never both: a copy without figures of its own must not borrow the other copy's.
    /// A path starts with "/", an ID never does.
    static func ranks(byID: [String: SessionUsage], byFile: [String: SessionUsage] = [:]) -> [String: UsageRank] {
        (byFile.isEmpty ? byID : byFile).compactMapValues(UsageRank.init)
    }

    /// The rank for one of Search's sessions: its own transcript's (keyed by path), else by ID (keyed by ID).
    static func rank(_ s: Session, in ranks: [String: UsageRank]) -> UsageRank? { ranks[s.key] ?? ranks[s.id] }

    /// Highest first; sessions without the figure last. Ties, and the sessions without figures, newest
    /// first, then by ID, so the order is the same on every run.
    static func order<T>(_ items: inout [T], by sort: SortMode, rank: (T) -> UsageRank?,
                         id: (T) -> String, modified: (T) -> Date) {
        guard sort.usesFigures else { return }
        let keyed = items.map { item -> (item: T, key: Double?, modified: Date, id: String) in
            let r = rank(item)
            return (item, sort == .cost ? r?.cost : r?.context, modified(item), id(item))
        }
        items = keyed.sorted { a, b in
            switch (a.key, b.key) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.modified != b.modified ? a.modified > b.modified : a.id < b.id
            }
        }.map(\.item)
    }

    static func order(_ hits: inout [Hit], by sort: SortMode, ranks: [String: UsageRank]) {
        order(&hits, by: sort, rank: { rank($0.session, in: ranks) }, id: \.id, modified: \.session.modified)
    }
}

/// How Search's panel and list word one session's figures. Pure, so the self-test checks it; every
/// cost goes through `money` (`UsageModel.money`, which adds the second currency when it is on).
/// Figures that are not Claude Code's own say "est.".
enum UsageText {
    static let est = " est."

    /// "30 Oct, 01:40" in your locale's way.
    static func when(_ d: Date) -> String { d.formatted(.dateTime.day().month(.abbreviated).hour().minute()) }

    static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n.formatted(.number)) \(n == 1 ? one : many ?? one + "s")"
    }

    private static func models(_ ids: [String]) -> String { ids.map(UsageFormat.model).joined(separator: ", ") }

    /// Part of the session could not be priced: the estimate leaves those replies out.
    static func isPartial(_ c: SessionUsage.Cost) -> Bool { c.source == .estimate && c.usd != nil && !c.unpriced.isEmpty }

    // MARK: Cost

    /// The Cost field: the amount and one line on where it comes from.
    static func cost(_ u: SessionUsage, money: (Double) -> String) -> (value: String, note: String) {
        let c = u.cost
        guard let usd = c.usd else { return ("Unknown", unknownNote(c)) }
        if c.source == .claudeCode { return (money(usd), "Claude Code's own figure") }
        if isPartial(c) { return ("At least \(money(usd))\(est)", "No price for \(models(c.unpriced)), so those replies are left out") }
        var note = "Estimated from this session's tokens"
        if let cc = c.claudeCodeUSD { note += ". Claude Code's own figure, \(money(cc)), does not cover all of it" }
        return (money(usd) + est, note)
    }

    /// A list row's cost: "$12.40", "$12.40 est.", "$12.40+ est." (part could not be priced), "Cost unknown".
    static func rowCost(_ u: SessionUsage, money: (Double) -> String) -> String {
        guard let usd = u.cost.usd else { return "Cost unknown" }
        if u.cost.source == .claudeCode { return money(usd) }
        return money(usd) + (isPartial(u.cost) ? "+" : "") + est
    }

    static let pricesHelp = "What these tokens cost at Anthropic's API prices. On a subscription plan this is not your bill."

    /// Why a cost is unknown, in the panel and the row's tooltip alike.
    private static func unknownNote(_ c: SessionUsage.Cost) -> String {
        c.unpriced.isEmpty ? "Nothing in this session could be priced" : "No price for \(models(c.unpriced))"
    }

    static func rowCostHelp(_ u: SessionUsage) -> String {
        if u.cost.usd == nil { return unknownNote(u.cost) + ". " + pricesHelp }
        if isPartial(u.cost) { return "At least this much: no price for \(models(u.cost.unpriced)). " + pricesHelp }
        return (u.cost.source == .claudeCode ? "Claude Code's own figure. " : "Estimated from this session's tokens. ") + pricesHelp
    }

    /// Each model that replied, most output first: its estimate, or "no price". `id` is the model ID:
    /// two IDs can read the same ("claude-haiku-4-5" and its dated "-20251001" are both "Haiku 4.5").
    static func byModel(_ u: SessionUsage, money: (Double) -> String) -> [(id: String, name: String, cost: String, replies: String)] {
        u.models.compactMap { id in
            guard let m = u.byModel[id] else { return nil }
            let cost = m.estimatedUSD.map { money($0) + (m.unpricedReplies > 0 ? "+" : "") + est } ?? "No price"
            return (id, UsageFormat.model(id), cost, plural(m.replies, "reply", "replies"))
        }
    }

    /// Cost per hour of Claude's work.
    static func perHour(_ u: SessionUsage, money: (Double) -> String) -> String {
        guard u.cost.usd != nil else { return "Unknown, since the cost is unknown" }
        guard let h = u.costPerHour else { return "Under a minute of work" }
        let mark = u.cost.source == .estimate || u.turns.source == .estimate ? est : ""
        return (isPartial(u.cost) ? "At least " : "") + money(h) + mark + " per hour of Claude's work"
    }

    // MARK: Context

    /// "849K of 1M tokens · 85%"; a model with no known window gets tokens only.
    static func context(_ u: SessionUsage) -> String? {
        guard let now = u.context.now else { return nil }
        if let w = u.contextWindow, let f = u.contextFraction {
            return "\(UsageFormat.tokens(now)) of \(UsageFormat.tokens(w)) tokens · \(UsageFormat.percent(f))"
        }
        return "\(UsageFormat.tokens(now)) tokens · window size unknown for \(u.context.model.map(UsageFormat.model) ?? "this model")"
    }

    /// A list row's: "85% context", or "58.3K context" with no known window.
    static func rowContext(_ u: SessionUsage) -> String? {
        guard let now = u.context.now else { return nil }
        if let f = u.contextFraction { return UsageFormat.percent(f) + " context" }
        return UsageFormat.tokens(now) + " context"
    }

    /// "30 Oct, 01:40 · automatic · 894K → 83K · took 1m".
    static func compaction(_ c: SessionUsage.Compaction) -> String {
        var parts = [when(c.at)]
        switch c.trigger {
        case "auto"?: parts.append("automatic")
        case "manual"?: parts.append("manual")
        case let other?: parts.append(other)
        case nil: break
        }
        if c.preTokens != nil || c.postTokens != nil {
            parts.append("\(c.preTokens.map(UsageFormat.tokens) ?? "?") → \(c.postTokens.map(UsageFormat.tokens) ?? "?")")
        }
        if let s = c.seconds { parts.append("took " + UsageFormat.duration(s)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Time and work

    /// Claude worked: time across turns, the days it fell on, and the time tools ran.
    static func worked(_ u: SessionUsage) -> String {
        guard u.turns.count > 0 else { return "No turns recorded" }
        var parts = [UsageFormat.duration(u.turns.seconds) + (u.turns.source == .estimate ? est : "")]
        let days = u.days.filter { $0.workSeconds.reduce(0, +) > 0 }.count
        if days > 1 { parts.append("on \(days) days") }
        // "Of it" only when it is part of it: tool time measured over more than the turns (a tool
        // waiting on you, say) is its own figure.
        if u.toolSeconds >= 1 {
            parts.append("tools ran \(UsageFormat.duration(u.toolSeconds))" + (u.toolSeconds <= u.turns.seconds ? " of it" : ""))
        }
        return parts.joined(separator: " · ")
    }

    static func turns(_ u: SessionUsage) -> String {
        guard u.turns.count > 0 else { return "None recorded" }
        let mark = u.turns.source == .estimate ? est : ""
        return u.turns.count.formatted(.number) + mark + " · longest \(UsageFormat.duration(u.turns.longestSeconds))" + mark
    }

    /// "418 calls · Read 71 · Edit 50 · … · +4 more", the first `limit` tools by count; `all` lists
    /// every one, a line each, for the tooltip.
    static func tools(_ u: SessionUsage, limit: Int = 8) -> (text: String, all: String) {
        guard !u.tools.isEmpty else { return ("None", "") }
        // A no-break space, so a name and its count never wrap apart.
        let sorted = u.tools.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { "\(UsageFormat.tool($0.key))\u{00A0}\($0.value.formatted(.number))" }
        let total = u.tools.values.reduce(0, +)
        // A no-break space before each dot, so a wrapped line never starts with one.
        let dot = "\u{00A0}· "
        var text = ([plural(total, "call")] + sorted.prefix(limit)).joined(separator: dot)
        if sorted.count > limit { text += dot + "+\(sorted.count - limit)\u{00A0}more" }
        return (text, sorted.joined(separator: "\n"))
    }

    static func subagents(_ u: SessionUsage, money: (Double) -> String) -> String {
        guard u.subagents.count > 0 else { return "None" }
        let cost = u.subagents.estimatedUSD.map { money($0) + est } ?? "cost unknown"
        return "\(u.subagents.count.formatted(.number)) · \(UsageFormat.tokens(u.subagents.tokens.total)) tokens · \(cost)"
    }

    /// API errors: a count by kind, then the latest `limit` with when and what, and how many more.
    static func errors(_ u: SessionUsage, limit: Int = 5) -> (summary: String, lines: [(text: String, message: String?)], more: Int) {
        let all = u.apiErrors
        guard !all.isEmpty else { return ("None", [], 0) }
        let kinds = Dictionary(grouping: all, by: \.kind).map { (UsageFormat.errorKind($0.key), $0.value.count) }
            .sorted { ($0.1, $1.0) > ($1.1, $0.0) }
        // One kind: its name says it all. Several: how many of each, and never "×1".
        let summary = all.count.formatted(.number) + " · "
            + (kinds.count == 1 ? kinds[0].0 : kinds.map { $0.1 > 1 ? "\($0.0)\u{00A0}×\($0.1)" : $0.0 }.joined(separator: ", "))
        let latest = all.sorted { $0.at > $1.at }.prefix(limit)
        let lines = latest.map { e -> (text: String, message: String?) in
            var t = when(e.at) + " · " + UsageFormat.errorKind(e.kind)
            if let s = e.status { t += " (\(s))" }
            if e.subagent { t += " · in a subagent" }
            return (t, e.message)
        }
        return (summary, lines, all.count - lines.count)
    }

    /// The Usage heading's line while the section is folded away.
    static func summary(_ u: SessionUsage, money: (Double) -> String) -> String {
        var parts = [rowCost(u, money: money)]
        if let c = rowContext(u) { parts.append(c) }
        if u.turns.count > 0 { parts.append(plural(u.turns.count, "turn") + (u.turns.source == .estimate ? est : "")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Context over time

    struct ChartPoint: Identifiable, Equatable {
        /// The reply's number, 1 for the first; a half step for a compaction after the last reply.
        var x: Double
        var tokens: Int
        var id: Double { x }
    }

    /// The main thread's context after each reply, at most `limit` points: a long session keeps each
    /// stretch's lowest and highest, so peaks and compactions still show.
    static func chartPoints(_ u: SessionUsage, limit: Int = 600) -> [ChartPoint] {
        let replies = u.context.replies
        var points = downsample(replies.map(\.tokens), limit: limit)
        // A compaction after the last reply: the context is now its "after" figure.
        if let now = u.context.now, let last = replies.last, now != last.tokens,
           let c = u.context.compactions.last, c.at >= last.at {
            points.append(ChartPoint(x: Double(replies.count) + 0.5, tokens: now))
        }
        return points
    }

    static func downsample(_ values: [Int], limit: Int) -> [ChartPoint] {
        func point(_ i: Int) -> ChartPoint { ChartPoint(x: Double(i + 1), tokens: values[i]) }
        guard values.count > limit, limit >= 6 else { return values.indices.map(point) }
        let buckets = (limit - 2) / 2
        let size = Double(values.count) / Double(buckets)
        var keep = Set([0, values.count - 1])
        for b in 0..<buckets {
            let lo = Int(Double(b) * size), hi = min(values.count, Int(Double(b + 1) * size))
            guard lo < hi else { continue }
            var low = lo, high = lo
            for i in lo..<hi {
                if values[i] < values[low] { low = i }
                if values[i] > values[high] { high = i }
            }
            keep.insert(low)
            keep.insert(high)
        }
        return keep.sorted().map(point)
    }

    /// Where each compaction falls between the replies, on the chart's reply axis.
    static func compactionMarks(_ u: SessionUsage) -> [(x: Double, compaction: SessionUsage.Compaction)] {
        let times = u.context.replies.map(\.at)
        return u.context.compactions.map { c in (Double(times.filter { $0 <= c.at }.count) + 0.5, c) }
    }

    /// For VoiceOver: what the chart shows, in a sentence.
    static func chartSummary(_ u: SessionUsage) -> String {
        let n = u.context.replies.count
        let peak = u.context.replies.map(\.tokens).max() ?? 0
        var s = "Context after each of \(plural(n, "reply", "replies")), highest \(UsageFormat.tokens(peak))"
        if let now = context(u) { s += ", now \(now)" }
        let c = u.context.compactions.count
        if c > 0 { s += ". Compacted \(c == 1 ? "once" : "\(c) times")" }
        return s + "."
    }
}

extension UsageFormat {
    /// Claude Code's error kinds in words: "rate limit", "server error", "overloaded".
    static func errorKind(_ kind: String) -> String {
        switch kind {
        case "rate_limit", "rate_limit_error": return "rate limit"
        case "overloaded", "overloaded_error": return "overloaded"
        case "api_error": return "API error"
        case "invalid_request", "invalid_request_error": return "invalid request"
        case "authentication_failed", "authentication_error": return "sign-in failed"
        case "oauth_org_not_allowed": return "not allowed for this organisation"
        case "unknown": return "unknown error"
        default: return kind.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// A tool's name: MCP tools (`mcp__<server>__<tool>`) as "server: tool", the rest as Claude Code
    /// names them. The server loses the prefixes Claude Code adds: `plugin_<plugin>_` for a plugin's
    /// server (`plugin_firebase_firebase` → firebase), `claude_ai_` for a claude.ai connector
    /// (`claude_ai_Google_Drive` → Google Drive), and `claude-in-` (`claude-in-chrome` → chrome).
    static func tool(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst("mcp__".count).components(separatedBy: "__")
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return name }
        var server = parts[0]
        if server.hasPrefix("plugin_") {
            let rest = server.dropFirst("plugin_".count).split(separator: "_", maxSplits: 1).map(String.init)
            server = rest.count == 2 ? rest[1] : rest.first ?? server
        } else if server.hasPrefix("claude_ai_"), server.count > "claude_ai_".count {
            server = String(server.dropFirst("claude_ai_".count))
        } else if server.hasPrefix("claude-in-"), server.count > "claude-in-".count {
            server = String(server.dropFirst("claude-in-".count))
        }
        // A no-break space: "server:" never ends a line without its tool.
        return server.replacingOccurrences(of: "_", with: " ") + ":\u{00A0}" + parts.dropFirst().joined(separator: "__")
    }
}
