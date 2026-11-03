import Foundation

/// `ClawsSearch --usage <session id prefix>`: one session's figures, readably.
/// `ClawsSearch --usage-dump`: every session's `SessionUsage` as JSON (dates ISO 8601), for
/// tools/usage-crosscheck.py. Both read made-up sessions under `--demo`.
enum UsageCLI {
    static func dump() -> Int32 {
        let t0 = CFAbsoluteTimeGetCurrent()
        let all = UsageStore().load()
        let t1 = CFAbsoluteTimeGetCurrent()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(all.values.sorted { $0.sessionID < $1.sessionID }) else { return 1 }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        FileHandle.standardError.write(Data(String(format: "%d sessions · read %.2fs\n", all.count, t1 - t0).utf8))
        return 0
    }

    static func show(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--usage"), i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
            print("usage: ClawsSearch [--demo] --usage <session id prefix>"); return 2
        }
        let prefix = args[i + 1]
        let all = UsageStore().load()
        let matches = all.values.filter { $0.sessionID.hasPrefix(prefix) }
        guard matches.count == 1, let u = matches.first else {
            print(matches.isEmpty ? "no session \(prefix)" : "\(matches.count) sessions start with \(prefix)"); return 1
        }
        let title = SessionStore().load().sessions.first { $0.id == u.sessionID }?.title
        print(lines(u, title: title).joined(separator: "\n"))
        return 0
    }

    static func lines(_ u: SessionUsage, title: String?) -> [String] {
        func n(_ v: Int) -> String { v.formatted(.number) }
        func usd(_ v: Double?) -> String { v.map { String(format: "$%.2f", $0) } ?? "unknown" }
        func dur(_ s: Double) -> String {
            let m = Int(s / 60)
            return m >= 60 ? "\(m / 60)h \(m % 60)m" : m > 0 ? "\(m)m" : String(format: "%.0fs", s)
        }
        func when(_ d: Date?) -> String { d?.formatted(date: .abbreviated, time: .shortened) ?? "?" }
        func tokens(_ t: SessionUsage.Tokens) -> String {
            "written \(n(t.output)) · read from cache \(n(t.cacheRead)) · written to cache \(n(t.cacheWrite))"
                + (t.cacheWrite1h > 0 ? " (1 h: \(n(t.cacheWrite1h)))" : "") + " · fresh input \(n(t.input))"
        }
        var out = [title ?? u.sessionID, "  \(u.sessionID)  \(u.folder.map(Paths.abbreviate) ?? u.projectDir)",
                   "  Active       \(when(u.firstActive)) to \(when(u.lastActive)) · \(n(u.replies)) replies"]
        var cost = "\(usd(u.cost.usd)) at API prices" + (u.cost.source == .claudeCode ? " (Claude Code's figure)" : " (est.)")
        if u.cost.source == .claudeCode { cost += " · est. \(usd(u.cost.estimateUSD))" }
        if u.cost.source == .estimate, let cc = u.cost.claudeCodeUSD { cost += " · Claude Code's last figure \(usd(cc)), not used" }
        if !u.cost.unpriced.isEmpty { cost += " · no price for \(u.cost.unpriced.joined(separator: ", "))" }
        if let h = u.costPerHour { cost += String(format: " · $%.2f per hour of Claude's work", h) }
        out.append("  Cost         " + cost)
        var context = u.context.now.map { n($0) } ?? "none"
        if let w = u.contextWindow, let f = u.contextFraction { context += " of \(n(w)) (\(Int((f * 100).rounded()))%)" }
        if let m = u.context.model { context += " · \(m)" }
        if u.isNearContextLimit { context += " · near the limit" }
        context += " · \(u.context.replies.count) points"
        out.append("  Context      " + context)
        for c in u.context.compactions {
            out.append("  Compaction   \(when(c.at)) \(c.trigger ?? "?"): \(c.preTokens.map(n) ?? "?") → \(c.postTokens.map(n) ?? "?")"
                       + (c.seconds.map { " in \(dur($0))" } ?? ""))
        }
        out.append("  Tokens       " + tokens(u.tokens))
        for m in u.models {
            guard let mu = u.byModel[m] else { continue }
            out.append("  \(m): \(n(mu.replies)) replies, \(tokens(mu.tokens)), est. \(usd(mu.estimatedUSD))"
                       + (mu.unpricedReplies > 0 ? ", \(mu.unpricedReplies) unpriced" : ""))
        }
        out.append("  Turns        \(u.turns.count)\(u.turns.source == .estimate ? " (est.)" : ""), Claude worked \(dur(u.turns.seconds))"
                   + " (longest \(dur(u.turns.longestSeconds))), tool time \(dur(u.toolSeconds))")
        let tools = u.tools.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { "\($0.key) \($0.value)" }
        out.append("  Tools        " + (tools.isEmpty ? "none" : tools.joined(separator: ", ")))
        out.append("  Subagents    \(u.subagents.count)" + (u.subagents.count > 0 ? ": \(tokens(u.subagents.tokens)), est. \(usd(u.subagents.estimatedUSD))" : ""))
        let kinds = Dictionary(grouping: u.apiErrors, by: \.kind).map { "\($0.key) \($0.value.count)" }.sorted()
        out.append("  API errors   \(u.apiErrors.count)" + (kinds.isEmpty ? "" : ": " + kinds.joined(separator: ", ")
                   + " (last \(when(u.apiErrors.last?.at)))"))
        out.append("  Lines        +\(n(u.lines.added)) −\(n(u.lines.removed))" + (u.lines.source == .estimate ? " (est.)" : " (Claude Code's figure)"))
        let busiest = u.days.max { $0.workSeconds.reduce(0, +) < $1.workSeconds.reduce(0, +) }
        out.append("  Days         \(u.days.count)" + (busiest.map { ", busiest \($0.date): \(dur($0.workSeconds.reduce(0, +))) of work" } ?? ""))
        return out
    }
}
