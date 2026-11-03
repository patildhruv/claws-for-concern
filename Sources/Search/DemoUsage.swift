import Foundation

/// Usage figures for `--demo`'s made-up sessions, so Search's panel and the Usage window render with
/// none of your data. Made from code, like the transcripts: each session's spec is played through
/// `UsageBuilder`, the reader's own fold, as replies, turns, tool calls, compactions and errors spread
/// over the session's hours. Deterministic (a seeded generator), relative to the demo's start.
extension Demo {
    struct UsageSpec {
        var model: String
        /// How long the session ran, ending at its last transcript line.
        var hours: Double
        var replies: Int
        /// Context before each compaction (and the curve's top).
        var peak: Int
        var compactions = 0
        /// Where the context ends, as a share of `peak`.
        var endShare = 0.6
        /// A second model for some replies (a /model switch), and its share.
        var otherModel: String?
        var otherShare = 0.0
        /// Claude Code's cost-state: current (its figure is used), stale (written before the last
        /// replies), or none (the session is still running, or ran before Claude Code wrote one).
        enum Record { case current, stale, none }
        var record = Record.current
        var subagents = 0
        var subagentModel: String?
        var errors: [String] = []
        var lines = (added: 0, removed: 0)
        var output = 300...2_800
    }

    static let usageSpecs: [String: UsageSpec] = [
        "7c1e4b2a-93d5-4f0e-8a6b-2d9f1c3e5a71": UsageSpec(model: "claude-opus-5-5", hours: 2.5, replies: 140, peak: 610_000,
                                                          endShare: 1, subagents: 1, errors: ["rate_limit"], lines: (182, 41)),
        "2b8f6d14-0a7e-4c39-b5d2-91e3f07a6c48": UsageSpec(model: "claude-opus-5", hours: 1.2, replies: 70, peak: 240_000,
                                                          endShare: 1, record: .none, lines: (96, 12)),
        "e5a03c97-6f21-48bd-9e0c-3d7b2a8f1e65": UsageSpec(model: "claude-opus-4-8", hours: 3.5, replies: 260, peak: 870_000,
                                                          compactions: 1, endShare: 0.35, subagents: 2,
                                                          subagentModel: "claude-haiku-4-5-20251001",
                                                          errors: ["server_error", "server_error"], lines: (64, 23)),
        "91d4f2b6-3c8a-4e07-a1f5-6b2e9d0c7a34": UsageSpec(model: "claude-sonnet-5", hours: 0.6, replies: 35, peak: 120_000,
                                                          endShare: 1, record: .none, lines: (44, 44)),
        "4f6a8e20-b7c3-4d91-8e5f-0c2d7b9a1e83": UsageSpec(model: "claude-opus-5-5", hours: 1.8, replies: 120, peak: 380_000,
                                                          endShare: 1, subagents: 1, subagentModel: "claude-haiku-4-5-20251001",
                                                          lines: (210, 8)),
        "c38b1e7d-5a24-49f6-b0d3-8e1f6a2c9b57": UsageSpec(model: "claude-fable-5-1", hours: 4, replies: 300, peak: 900_000,
                                                          compactions: 2, endShare: 0.55, otherModel: "claude-opus-5-5",
                                                          otherShare: 0.3, errors: ["rate_limit", "rate_limit", "rate_limit"],
                                                          lines: (340, 120)),
        "a7e25f93-1d6c-4b80-9f3a-5c0e8d2b7f16": UsageSpec(model: "claude-opus-5-5", hours: 0.8, replies: 30, peak: 90_000,
                                                          endShare: 1, record: .none, lines: (120, 0), output: 600...4_000),
        "5d9c7a31-e2f8-4a6b-83d0-b4f1c6e9a205": UsageSpec(model: "claude-haiku-5-5", hours: 0.2, replies: 8, peak: 30_000,
                                                          endShare: 1, record: .none),
        "f0b6d8e4-7a39-4c25-ae1b-2d8c5f7e9031": UsageSpec(model: "claude-opus-4-7", hours: 1, replies: 50, peak: 200_000,
                                                          endShare: 1, record: .stale, lines: (6, 2)),
        // A model the price table does not know: its cost is unknown and its context has no percentage.
        "3e8a2c6f-9b14-4d7e-b2a5-7f0c1e9d4b68": UsageSpec(model: "claude-3-7-sonnet-20250219", hours: 0.5, replies: 25,
                                                          peak: 60_000, endShare: 1, record: .none, lines: (31, 0)),
        // Still running, near its context limit, and with no cost-state yet.
        "b1f7e3a9-4c62-4e8d-95b0-6a3d8c2f1e74": UsageSpec(model: "claude-opus-5-5", hours: 5, replies: 420, peak: 900_000,
                                                          compactions: 1, endShare: 0.95, record: .none, subagents: 1,
                                                          errors: ["rate_limit"], lines: (77, 19)),
        "68c0d5b2-af47-4193-8e6c-c9b2f4a70d1e": UsageSpec(model: "claude-opus-4-6", hours: 0.4, replies: 20, peak: 70_000,
                                                          endShare: 1, lines: (14, 3)),
    ]

    /// Figures for each made-up session, keyed by ID; filled by `activate()`, empty otherwise.
    private(set) static var usage: [String: SessionUsage] = [:]

    static func loadUsage(home: URL, now: Date) { usage = makeUsage(home: home, now: now) }
    static func dropUsage() { usage = [:] }

    static func makeUsage(home: URL, now: Date, calendar: Calendar = .usage) -> [String: SessionUsage] {
        var out: [String: SessionUsage] = [:]
        for (i, s) in sessions.enumerated() {
            guard let spec = usageSpecs[s.id] else { continue }
            let folder = home.appendingPathComponent(s.folder).path
            out[s.id] = play(s, spec, folder: folder, end: now.addingTimeInterval(-s.hoursAgo * 3600),
                             seed: UInt64(i + 1), calendar: calendar)
        }
        return out
    }

    /// SplitMix64: the same figures on every run.
    private struct Seeded {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
    }

    private static func play(_ s: Session, _ spec: UsageSpec, folder: String, end: Date, seed: UInt64,
                             calendar: Calendar) -> SessionUsage {
        var rng = Seeded(state: seed)
        var b = UsageBuilder(sessionID: s.id, projectDir: ProjectDirs.name(for: folder), calendar: calendar)
        b.noteCwd(folder)
        b.subagentCount = spec.subagents
        let start = end.addingTimeInterval(-spec.hours * 3600)
        let subReplies = spec.subagents * 16
        let main = max(1, spec.replies - subReplies)
        let turns = max(1, main / 10)
        let slot = spec.hours * 3600 / Double(turns)

        // Context along the main thread: a rising curve that falls back after each compaction.
        let segment = Double(main) / (Double(spec.compactions) + spec.endShare)
        let afterCompaction = Int(Double(spec.peak) * 0.07) + 20_000
        func context(_ j: Int) -> (tokens: Int, segment: Int) {
            let seg = min(spec.compactions, Int(Double(j) / segment))
            let pos = (Double(j) - Double(seg) * segment) / segment
            let base = seg == 0 ? 24_000 : afterCompaction
            return (base + Int(Double(spec.peak - base) * pow(min(pos, 1), 1.15)), seg)
        }

        var j = 0, previous = 0, lastSegment = 0, tool = 0, agentsLeft = spec.subagents
        let toolNames = ["Read", "Read", "Bash", "Edit", "Grep", "Read", "Bash", "Edit", "Glob", "TodoWrite", "Write", "WebFetch"]
        var errorTimes = spec.errors.indices.map { _ in start.addingTimeInterval(rng.unit() * spec.hours * 3600) }.sorted()
        for t in 0..<turns {
            let turnStart = start.addingTimeInterval(Double(t) * slot + (t == 0 ? 0 : rng.unit() * slot * 0.3))
            let turnEnd = t == turns - 1 ? end : turnStart.addingTimeInterval(slot * (0.45 + rng.unit() * 0.3))
            b.prompt(at: turnStart)
            let count = t == turns - 1 ? main - j : min(main - j, 10)
            let step = turnEnd.timeIntervalSince(turnStart) / Double(max(count, 1))
            for k in 0..<count {
                let at = turnStart.addingTimeInterval(step * Double(k + 1))
                let c = context(j)
                if c.segment != lastSegment {
                    b.compaction(.init(at: at.addingTimeInterval(-step / 2), trigger: c.segment == 2 ? "manual" : "auto",
                                       preTokens: previous, postTokens: afterCompaction,
                                       droppedTokens: (previous - afterCompaction) * c.segment, seconds: 40 + rng.unit() * 50))
                    lastSegment = c.segment
                    previous = 18_000       // the cache did not survive the compaction
                }
                let write = min(c.tokens - 2_000, max(c.tokens - previous, 0) + rng.int(200...1_500))
                let input = rng.int(3...9)
                let model = spec.otherModel != nil && rng.unit() < spec.otherShare ? spec.otherModel! : spec.model
                b.reply(id: "msg_demo_\(j)", .init(at: at, model: model,
                                                    tokens: .init(output: rng.int(spec.output), cacheRead: c.tokens - write - input,
                                                                  cacheWrite: write, cacheWrite1h: write, input: input),
                                                    subagent: false))
                previous = c.tokens
                j += 1
                // Most replies end in a tool call that runs until shortly before the next reply.
                if k < count - 1, rng.unit() < 0.8 {
                    tool += 1
                    let id = "toolu_demo_\(tool)"
                    if agentsLeft > 0, t == turns / 2, k == 0 {
                        agentsLeft -= 1
                        b.toolUse(id: id, name: "Agent", at: at, subagent: false)
                        subagent(&b, &rng, spec, index: agentsLeft, from: at, to: at.addingTimeInterval(step * 0.9))
                    } else {
                        b.toolUse(id: id, name: toolNames[rng.int(0...toolNames.count - 1)], at: at, subagent: false)
                    }
                    b.toolResult(id: id, at: at.addingTimeInterval(step * (0.2 + rng.unit() * 0.7)))
                }
                while let e = errorTimes.first, e <= at {
                    errorTimes.removeFirst()
                    let kind = spec.errors[spec.errors.count - errorTimes.count - 1]
                    b.apiError(.init(at: e, kind: kind, status: kind == "rate_limit" ? 429 : 500,
                                     message: kind == "rate_limit" ? "API Error: Rate limit reached" : "API Error: 500 Internal server error"))
                }
            }
            b.turn(end: turnEnd, seconds: turnEnd.timeIntervalSince(turnStart))
        }
        while agentsLeft > 0 {     // sessions too short for one in the middle turn
            agentsLeft -= 1
            subagent(&b, &rng, spec, index: agentsLeft, from: start.addingTimeInterval(60), to: start.addingTimeInterval(400))
        }

        // Counted from the calls, on the session's last day; Claude Code's own figure, where it has one,
        // is a few lines more (it also counts edits whose results were not written).
        if spec.record != .stale { b.editedLines(added: spec.lines.added, removed: spec.lines.removed, at: end) }
        let sofar = b.build()
        switch spec.record {
        case .current:
            // Claude Code's figure is a little higher: it also counts its own small Haiku requests.
            b.costState(.init(usd: (sofar.cost.estimateUSD ?? 0) * 1.011, output: sofar.tokens.output + 40,
                              cacheRead: sofar.tokens.cacheRead, linesAdded: spec.lines.added + spec.lines.added / 25,
                              linesRemoved: spec.lines.removed))
        case .stale:
            // Written an hour before the last replies: kept, shown nowhere but `claudeCodeUSD`.
            b.costState(.init(usd: (sofar.cost.estimateUSD ?? 0) * 0.7, output: sofar.tokens.output * 7 / 10,
                              cacheRead: sofar.tokens.cacheRead * 7 / 10, linesAdded: 4, linesRemoved: 1))
            b.reply(id: "msg_demo_late", .init(at: end, model: spec.model,
                                               tokens: .init(output: 900, cacheRead: previous, cacheWrite: 1_200, cacheWrite1h: 1_200, input: 4),
                                               subagent: false))
            b.editedLines(added: spec.lines.added, removed: spec.lines.removed, at: end)
        case .none:
            break
        }
        return b.build()
    }

    /// One subagent's replies, between `from` and `to`, in its own small context.
    private static func subagent(_ b: inout UsageBuilder, _ rng: inout Seeded, _ spec: UsageSpec, index: Int,
                                 from: Date, to: Date) {
        let n = 16
        let step = to.timeIntervalSince(from) / Double(n + 1)
        var previous = 0
        for k in 0..<n {
            let at = from.addingTimeInterval(step * Double(k + 1))
            let c = 14_000 + k * 3_600
            let write = max(c - previous, 0) + rng.int(100...600)
            b.reply(id: "msg_demo_agent\(index)_\(k)", .init(at: at, model: spec.subagentModel ?? spec.model,
                                                             tokens: .init(output: rng.int(150...1_400), cacheRead: max(0, c - write - 4),
                                                                           cacheWrite: write, cacheWrite1h: 0, input: 4),
                                                             subagent: true))
            previous = c
            if k < n - 1 {
                let id = "toolu_demo_agent\(index)_\(k)"
                b.toolUse(id: id, name: ["Read", "Grep", "Glob", "Bash"][rng.int(0...3)], at: at, subagent: true)
                b.toolResult(id: id, at: at.addingTimeInterval(step * 0.5))
            }
        }
    }
}
