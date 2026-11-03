import Foundation

/// The self-test's checks for Search's usage panel and list: the Cost and Context sorts, and how each
/// figure is worded (est. marks, unknown and partly priced costs, no zeros), on made-up figures and on
/// the demo's. Called from `SelfTest.run`.
enum UsagePanelTests {
    static func run() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { out.append(("usage panel: " + name, ok)) }

        // Sorting
        let now = Date()
        typealias Item = (id: String, modified: Date)
        let items: [Item] = [("a", now - 50), ("b", now - 10), ("c", now - 30), ("d", now - 20), ("e", now - 40), ("f", now - 20)]
        let ranks: [String: UsageRank] = [
            "a": .init(cost: 5, context: 0.2), "b": .init(cost: nil, context: 0.9), "c": .init(cost: 12, context: nil),
            "e": .init(cost: 5, context: 0.95), "f": .init(cost: 1, context: 0.1),
        ]
        func sorted(_ mode: SortMode) -> String {
            var list = items
            UsageRank.order(&list, by: mode, rank: { ranks[$0.id] }, id: \.id, modified: \.modified)
            return list.map(\.id).joined()
        }
        check("cost: highest first, ties newest first, sessions without a cost last (newest first)", sorted(.cost) == "ceafbd")
        check("context: fullest first, sessions without figures last", sorted(.context) == "ebafdc")
        check("relevance and recent leave the order to the search", sorted(.relevance) == "abcdef" && sorted(.recent) == "abcdef")
        var same = [Item]([("y", now), ("x", now)])
        UsageRank.order(&same, by: .cost, rank: { _ in nil }, id: \.id, modified: \.modified)
        check("equal and without figures: by ID, the same on every run", same.map(\.id) == ["x", "y"])
        let both = UsageRank.ranks(byID: ["s": usage(model: "claude-opus-5-5", now: 100_000)],
                                   byFile: ["/p/a/s.jsonl": usage(model: "claude-opus-5-5", now: 500_000)])
        check("ranks: a transcript's own figures win over its ID's", both["/p/a/s.jsonl"]?.context == 0.5 && both["s"]?.context == 0.1)

        var opus = usage(model: "claude-opus-5-5", now: 849_000)
        check("rank: a known window gives the share", UsageRank(opus)?.context == 0.849)
        let sonnet37 = usage(model: "claude-3-7-sonnet-20250219", now: 400_000)
        check("rank: no known window counts against 1M (800K = 80%)", UsageRank(sonnet37)?.context == 0.4)
        check("rank: no replies yet sorts with no figures", UsageRank(SessionUsage(sessionID: "x", projectDir: "-x")) == nil)

        // Cost wording: every cost goes through `money`, every estimate says est., unknown is never $0.
        let money: (Double) -> String = { "M" + String(format: "%.2f", $0) }
        opus.cost = .init(usd: 12.4, source: .claudeCode, estimateUSD: 12.1)
        check("cost: Claude Code's figure has no est.", UsageText.rowCost(opus, money: money) == "M12.40"
              && UsageText.cost(opus, money: money) == ("M12.40", "Claude Code's own figure"))
        opus.cost = .init(usd: 12.4, source: .estimate, estimateUSD: 12.4)
        check("cost: an estimate says est.", UsageText.rowCost(opus, money: money) == "M12.40 est."
              && UsageText.cost(opus, money: money).value == "M12.40 est.")
        opus.cost.claudeCodeUSD = 9
        check("cost: a Claude Code figure not used is named", UsageText.cost(opus, money: money).note.contains("M9.00"))
        opus.cost = .init(usd: 3, source: .estimate, estimateUSD: 3, unpriced: ["claude-3-7-sonnet-20250219"])
        opus.turns = .init(count: 1, seconds: 3600, longestSeconds: 3600, source: .claudeCode)
        check("cost: partly priced is never shown as complete",
              UsageText.rowCost(opus, money: money) == "M3.00+ est." && UsageText.cost(opus, money: money).value == "At least M3.00 est."
              && UsageText.cost(opus, money: money).note.contains("Sonnet 3.7") && UsageText.perHour(opus, money: money).hasPrefix("At least"))
        opus.cost = .init(usd: nil, source: .estimate, estimateUSD: nil, unpriced: ["claude-3-7-sonnet-20250219"])
        check("cost: unknown says so, never $0", UsageText.rowCost(opus, money: money) == "Cost unknown"
              && UsageText.cost(opus, money: money).value == "Unknown" && !UsageText.perHour(opus, money: money).contains("M"))

        var timed = usage(model: "claude-opus-5-5", now: 100_000)
        timed.cost = .init(usd: 10, source: .claudeCode, estimateUSD: 10)
        timed.turns = .init(count: 4, seconds: 7200, longestSeconds: 1800, source: .claudeCode)
        check("per hour: Claude Code's cost and turn times, no est.", UsageText.perHour(timed, money: money) == "M5.00 per hour of Claude's work")
        timed.turns.source = .estimate
        check("per hour and turns: est. when the turn times are worked out",
              UsageText.perHour(timed, money: money) == "M5.00 est. per hour of Claude's work"
              && UsageText.turns(timed) == "4 est. · longest 30m" && UsageText.worked(timed).hasPrefix("2h 00m est."))
        timed.turns.seconds = 30
        check("per hour: under a minute of work is said in words", UsageText.perHour(timed, money: money) == "Under a minute of work")

        // Context wording
        check("context: tokens of the window and the share", UsageText.context(usage(model: "claude-opus-5-5", now: 236_000))
              == "236K of 1M tokens · 24%" && UsageText.rowContext(usage(model: "claude-opus-5-5", now: 236_000)) == "24% context")
        check("context: an unknown window gives tokens and no share",
              UsageText.context(sonnet37) == "400K tokens · window size unknown for Sonnet 3.7" && UsageText.rowContext(sonnet37) == "400K context"
              && sonnet37.contextFraction == nil)
        check("context: none yet is nil, not zero", UsageText.context(SessionUsage(sessionID: "x", projectDir: "-x")) == nil)

        // Errors, tools, compactions
        var e = usage(model: "claude-opus-5-5", now: 1)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        e.apiErrors = (0..<7).map { .init(at: t0 + Double($0) * 60, kind: $0 < 5 ? "rate_limit" : "server_error", status: $0 < 5 ? 429 : 500) }
        let errs = UsageText.errors(e)
        check("errors: counted by kind, latest five listed, the rest counted",
              errs.summary == "7 · rate limit\u{00A0}×5, server error\u{00A0}×2" && errs.lines.count == 5 && errs.more == 2
              && errs.lines[0].text.hasSuffix("server error (500)"))
        e.apiErrors = [.init(at: t0, kind: "rate_limit"), .init(at: t0 + 1, kind: "server_error"), .init(at: t0 + 2, kind: "rate_limit")]
        check("errors: several kinds, and never ×1", UsageText.errors(e).summary == "3 · rate limit\u{00A0}×2, server error")
        e.apiErrors = [.init(at: t0, kind: "overloaded_error", subagent: true)]
        check("errors: one kind needs no count", UsageText.errors(e).summary == "1 · overloaded"
              && UsageText.errors(e).lines[0].text.hasSuffix("overloaded · in a subagent"))
        check("errors: none", UsageText.errors(usage(model: "claude-opus-5-5", now: 1)).summary == "None")
        e.tools = ["Read": 9, "Bash": 9, "Edit": 3, "mcp__claude-in-chrome__computer": 2, "Glob": 1]
        let tools = UsageText.tools(e, limit: 3)
        check("tools: most used first, a name and its count never wrap apart, the rest counted",
              tools.text == ["24 calls", "Bash\u{00A0}9", "Read\u{00A0}9", "Edit\u{00A0}3", "+2\u{00A0}more"].joined(separator: "\u{00A0}· ")
              && tools.all.contains("chrome:\u{00A0}computer\u{00A0}2"))
        check("tools: eight shown by default", UsageText.tools(e).text.hasSuffix("Glob\u{00A0}1"))
        let nb = "\u{00A0}"
        check("MCP tools as server: tool, without Claude Code's prefixes, never broken after the colon",
              UsageFormat.tool("mcp__srv__do__it") == "srv:\(nb)do__it" && UsageFormat.tool("mcp__claude-in-chrome__computer") == "chrome:\(nb)computer"
              && UsageFormat.tool("mcp__plugin_firebase_firebase__firebase_init") == "firebase:\(nb)firebase_init"
              && UsageFormat.tool("mcp__claude_ai_Google_Drive__authenticate") == "Google Drive:\(nb)authenticate"
              && UsageFormat.tool("mcp__playwright__browser_click") == "playwright:\(nb)browser_click"
              && UsageFormat.tool("Bash") == "Bash" && UsageFormat.tool("mcp__") == "mcp__" && UsageFormat.tool("mcp__x__") == "mcp__x__")
        check("error kinds in words", UsageFormat.errorKind("rate_limit") == "rate limit" && UsageFormat.errorKind("some_new_kind") == "some new kind"
              && UsageFormat.errorKind("authentication_failed") == "sign-in failed" && UsageFormat.errorKind("unknown") == "unknown error"
              && UsageFormat.errorKind("billing_error") == "billing error")
        let c = SessionUsage.Compaction(at: t0, trigger: "auto", preTokens: 948_000, postTokens: 31_000, droppedTokens: nil, seconds: 75)
        check("compaction: how, before → after, how long", UsageText.compaction(c).hasSuffix(" · automatic · 948K → 31K · took 1m"))

        // Context over time
        let flat = UsageText.downsample(Array(1...10), limit: 600)
        check("chart: a short session keeps every reply", flat.map(\.tokens) == Array(1...10) && flat.first?.x == 1)
        let wave = (0..<5000).map { i in i == 3333 ? 999_999 : i == 4000 ? 7 : 100_000 + i % 997 }
        let small = UsageText.downsample(wave, limit: 600)
        check("chart: a long session fits the limit and keeps its peak, its low, the first and last",
              small.count <= 600 && small.contains { $0.tokens == 999_999 } && small.contains { $0.tokens == 7 }
              && small.first?.x == 1 && small.last?.x == 5000 && zip(small, small.dropFirst()).allSatisfy { $0.x < $1.x })
        var compacted = usage(model: "claude-opus-5-5", now: 30_000)
        compacted.context.replies = [.init(at: t0, tokens: 500_000), .init(at: t0 + 60, tokens: 900_000)]
        compacted.context.compactions = [.init(at: t0 + 30), .init(at: t0 + 120, trigger: "manual", postTokens: 30_000)]
        let pts = UsageText.chartPoints(compacted)
        check("chart: a compaction after the last reply ends the curve at its after figure",
              pts.map(\.tokens) == [500_000, 900_000, 30_000] && pts.last?.x == 2.5)
        check("chart: compactions sit between the replies they came between",
              UsageText.compactionMarks(compacted).map(\.x) == [1.5, 2.5])
        check("chart: VoiceOver gets a sentence", UsageText.chartSummary(compacted).contains("Compacted 2 times"))
        return out
    }

    /// One main-thread reply with `now` tokens in context.
    private static func usage(model: String, now: Int) -> SessionUsage {
        var u = SessionUsage(sessionID: "s", projectDir: "-p")
        u.replies = 1
        u.models = [model]
        u.context.now = now
        u.context.model = model
        return u
    }

    /// The demo's figures and the window's model: every demo session renders a figure for each field,
    /// and Cost sorts the list, re-sorts when the figures change and survives a refresh.
    @MainActor
    static func window() -> [(String, Bool)] {
        Demo.activate()
        defer { Demo.deactivate() }
        var out: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { out.append(("usage panel: " + name, ok)) }
        let figures = Demo.usage
        let sessions = SessionStore().load().sessions
        check("demo: every session has figures", sessions.allSatisfy { figures[$0.id].map { $0.replies > 0 } ?? false })
        check("demo: one running session near its limit, with a compaction",
              figures.values.filter(\.isNearContextLimit).map(\.sessionID) == ["b1f7e3a9-4c62-4e8d-95b0-6a3d8c2f1e74"]
              && figures["b1f7e3a9-4c62-4e8d-95b0-6a3d8c2f1e74"]?.context.compactions.count == 1)
        check("demo: Claude Code's figure and estimates both show",
              Set(figures.values.map { UsageText.rowCost($0, money: UsageFormat.usd).hasSuffix(" est.") }) == [true, false])
        check("demo: the unpriced model's cost is unknown and its context has no share",
              figures["3e8a2c6f-9b14-4d7e-b2a5-7f0c1e9d4b68"].map {
                  UsageText.rowCost($0, money: UsageFormat.usd) == "Cost unknown" && $0.contextFraction == nil
              } ?? false)
        check("demo: MCP tools by their server, and more tools than fit",
              figures["4f6a8e20-b7c3-4d91-8e5f-0c2d7b9a1e83"].map {
                  let t = UsageText.tools($0)
                  return t.text.contains("chrome:\u{00A0}") && t.text.hasSuffix("\u{00A0}more") && t.all.contains("chrome:\u{00A0}read_page")
              } ?? false)
        check("demo: no row or panel figure reads $0.00",
              figures.values.allSatisfy { u in
                  ([UsageText.rowCost(u, money: UsageFormat.usd), UsageText.cost(u, money: UsageFormat.usd).value,
                    UsageText.perHour(u, money: UsageFormat.usd), UsageText.subagents(u, money: UsageFormat.usd)]
                   + UsageText.byModel(u, money: UsageFormat.usd).map(\.cost)).allSatisfy { !$0.contains("$0.00") }
              })

        let model = AppModel()
        func wait(_ seconds: Double, until done: () -> Bool) {
            let end = Date().addingTimeInterval(seconds)
            while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        func byCost(_ ids: [String]) -> Bool {
            let costs = ids.map { figures[$0]?.cost.usd }
            let known = costs.prefix { $0 != nil }.map { $0! }
            return zip(known, known.dropFirst()).allSatisfy { $0 >= $1 } && costs.dropFirst(known.count).allSatisfy { $0 == nil }
        }
        wait(10) { !model.indexing && model.hits.count == sessions.count }
        let recent = model.hits.map(\.id)
        model.sort = .cost
        wait(2) { model.hits.map(\.id) != recent }
        check("window: without figures, Cost keeps the newest first", model.hits.map(\.id) == recent)
        model.setUsage(figures)
        wait(5) { byCost(model.hits.map(\.id)) }
        check("window: figures arriving re-sort the list by cost, unknown last",
              byCost(model.hits.map(\.id)) && model.hits.last?.id == "3e8a2c6f-9b14-4d7e-b2a5-7f0c1e9d4b68")
        let costOrder = model.hits.map(\.id)
        model.refresh()
        wait(5) { !model.indexing }
        wait(0.5) { false }
        check("window: the sort survives a refresh", model.sort == .cost && model.hits.map(\.id) == costOrder)
        model.query = "rate limit"
        wait(5) { model.hits.count < sessions.count && byCost(model.hits.map(\.id)) }
        check("window: a search's hits sort by cost too", model.hits.count < sessions.count && byCost(model.hits.map(\.id)))
        model.query = ""
        model.sort = .context
        wait(5) { model.hits.first?.id == "b1f7e3a9-4c62-4e8d-95b0-6a3d8c2f1e74" }
        check("window: Context puts the session near its limit first", model.hits.first?.id == "b1f7e3a9-4c62-4e8d-95b0-6a3d8c2f1e74")
        return out
    }
}
