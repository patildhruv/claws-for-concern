import AppKit
import SwiftUI

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
        // One ID filed twice: /b's copy has figures, /a's has none (no replies yet, or not read yet).
        var busy = usage(model: "claude-opus-5-5", now: 500_000)
        busy.cost = .init(usd: 50, source: .claudeCode, estimateUSD: 50)
        let byFile = ["/b/s.jsonl": busy, "/a/s.jsonl": SessionUsage(sessionID: "s", projectDir: "-a")]
        let both = UsageRank.ranks(byID: ["s": busy], byFile: byFile)
        check("ranks: by transcript, and a copy without figures never borrows the other copy's",
              both["/b/s.jsonl"]?.cost == 50 && both["/a/s.jsonl"] == nil && both["s"] == nil && both.count == 1)
        check("ranks: by ID only when there are no per-transcript figures (the demo)",
              UsageRank.ranks(byID: ["s": busy])["s"]?.cost == 50)

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
        check("cost: the row's tooltip names the unpriced model as the panel does",
              UsageText.rowCostHelp(opus).hasPrefix("No price for Sonnet 3.7. "))
        opus.cost = .init(usd: nil, source: .estimate, estimateUSD: nil, unpriced: [])
        check("cost: unknown with no model named says the panel's words, never \"No price for .\"",
              UsageText.rowCostHelp(opus).hasPrefix("Nothing in this session could be priced. ")
              && UsageText.cost(opus, money: money).note == "Nothing in this session could be priced")

        // Under half a cent: never "$0.00", in either window (both write through UsageFormat.usd).
        check("dollars: under half a cent is <$0.01, zero is $0.00, a cent is $0.01",
              UsageFormat.usd(0.002761) == "<$0.01" && UsageFormat.usd(0.0049) == "<$0.01" && UsageFormat.usd(0) == "$0.00"
              && UsageFormat.usd(0.006) == "$0.01" && UsageFormat.usd(12.4) == "$12.40" && UsageFormat.usd(1284.4) == "$1,284")
        var tiny = usage(model: "claude-opus-5-5", now: 1)
        tiny.cost = .init(usd: 0.002761, source: .estimate, estimateUSD: 0.002761)
        check("dollars: a tiny estimate reads <$0.01 est.", UsageText.rowCost(tiny, money: UsageFormat.usd) == "<$0.01 est."
              && UsageText.cost(tiny, money: UsageFormat.usd).value == "<$0.01 est.")

        // By model: keyed by the model ID, as two IDs can read the same.
        var twins = usage(model: "claude-haiku-4-5", now: 1)
        twins.models = ["claude-haiku-4-5", "claude-haiku-4-5-20251001"]
        twins.byModel = ["claude-haiku-4-5": .init(replies: 1, estimatedUSD: 0.1), "claude-haiku-4-5-20251001": .init(replies: 1, estimatedUSD: 0.2)]
        let rows = UsageText.byModel(twins, money: UsageFormat.usd)
        check("by model: two IDs with one name are two rows with their own keys",
              rows.map(\.name) == ["Haiku 4.5", "Haiku 4.5"] && Set(rows.map(\.id)).count == 2)

        var timed = usage(model: "claude-opus-5-5", now: 100_000)
        timed.cost = .init(usd: 10, source: .claudeCode, estimateUSD: 10)
        timed.turns = .init(count: 4, seconds: 7200, longestSeconds: 1800, source: .claudeCode)
        check("per hour: Claude Code's cost and turn times, no est.", UsageText.perHour(timed, money: money) == "M5.00 per hour of Claude's work")
        timed.turns.source = .estimate
        check("per hour and turns: est. when the turn times are worked out",
              UsageText.perHour(timed, money: money) == "M5.00 est. per hour of Claude's work"
              && UsageText.turns(timed) == "4 est. · longest 30m est." && UsageText.worked(timed).hasPrefix("2h 00m est."))
        check("folded line: estimated turns say est. there too", UsageText.summary(timed, money: money).hasSuffix("4 turns est."))
        timed.turns.source = .claudeCode
        check("turns: Claude Code's own, no est.", UsageText.turns(timed) == "4 · longest 30m"
              && UsageText.summary(timed, money: money).hasSuffix("4 turns"))
        timed.toolSeconds = 1800
        check("worked: tool time inside the turns is \"of it\"", UsageText.worked(timed) == "2h 00m · tools ran 30m of it")
        timed.turns.seconds = 809
        timed.toolSeconds = 46_260
        check("worked: tool time longer than the turns is never \"of it\"", UsageText.worked(timed) == "13m · tools ran 12h 51m")
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
        let recent = model.hits.map(\.session.id)
        model.sort = .cost
        wait(2) { model.hits.map(\.session.id) != recent }
        check("window: without figures, Cost keeps the newest first", model.hits.map(\.session.id) == recent)
        model.setUsage(figures)
        wait(5) { byCost(model.hits.map(\.session.id)) }
        check("window: figures arriving re-sort the list by cost, unknown last",
              byCost(model.hits.map(\.session.id)) && model.hits.last?.session.id == "3e8a2c6f-9b14-4d7e-b2a5-7f0c1e9d4b68")
        let costOrder = model.hits.map(\.session.id)
        model.refresh()
        wait(5) { !model.indexing }
        wait(0.5) { false }
        check("window: the sort survives a refresh", model.sort == .cost && model.hits.map(\.session.id) == costOrder)
        model.query = "rate limit"
        wait(5) { model.hits.count < sessions.count && byCost(model.hits.map(\.session.id)) }
        check("window: a search's hits sort by cost too", model.hits.count < sessions.count && byCost(model.hits.map(\.session.id)))
        model.query = ""
        model.sort = .context
        wait(5) { model.hits.first?.session.id == "b1f7e3a9-4c62-4e8d-95b0-6a3d8c2f1e74" }
        check("window: Context puts the session near its limit first", model.hits.first?.session.id == "b1f7e3a9-4c62-4e8d-95b0-6a3d8c2f1e74")
        return out
    }

    static let dup = "2c2b2a29-2827-4625-a423-222120191817", other = "3d3c3b3a-3938-4736-b534-333231302f2e"
    static let tie = "4e4d4c4b-4a49-4847-8645-444342414039"

    /// Made-up transcripts under `base`: `dup` filed under "first" (1 Oct) and "second" (2 Oct), `other`
    /// under "third" (3 Oct, "zebra"), and with `ties`, `tie` filed under "fourth" and "fifth" with the
    /// very same lines. Returns the projects folder and the working folders by name.
    static func makeStore(_ base: URL, ties: Bool) -> (projects: URL, folder: (String) -> String) {
        let fm = FileManager.default
        try? fm.removeItem(at: base)
        let projects = base.appendingPathComponent("projects")
        func folder(_ name: String) -> String { base.appendingPathComponent(name).path }
        // Folder, session ID, day in October, the prompt, output tokens.
        var files = [("first", dup, "01", "alpha copy", 100), ("second", dup, "02", "beta copy", 200), ("third", other, "03", "zebra crossing", 300)]
        if ties { files += [("fourth", tie, "04", "twin lines", 50), ("fifth", tie, "04", "twin lines", 50)] }
        for (name, id, day, words, output) in files {
            let cwd = folder(name)
            try? fm.createDirectory(atPath: cwd, withIntermediateDirectories: true)
            let dir = projects.appendingPathComponent(ProjectDirs.name(for: cwd))
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let user = #"{"type":"user","cwd":"\#(cwd)","timestamp":"2026-10-\#(day)T10:00:00.000Z","message":{"content":"\#(words)"}}"#
            let reply = #"{"type":"assistant","cwd":"\#(cwd)","timestamp":"2026-10-\#(day)T10:01:00.000Z","message":{"id":"msg_\#(day)","#
                + #""model":"claude-opus-5-5","role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":5,"#
                + #""output_tokens":\#(output),"cache_read_input_tokens":0,"cache_creation_input_tokens":1000}}}"#
            fm.createFile(atPath: dir.appendingPathComponent(id + ".jsonl").path, contents: Data((user + "\n" + reply + "\n").utf8))
        }
        return (projects, folder)
    }

    @MainActor
    static func wait(_ seconds: Double, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// One session ID filed under two project folders (a copied transcript), and a third session: two
    /// rows the list tells apart, each with its own figures, and `show(sessionID:projectDir:)` picks the
    /// copy asked for, clearing a query that hides it.
    @MainActor
    static func copies() -> [(String, Bool)] {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("claws-copies-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        let (projects, folder) = makeStore(base, ties: true)
        let folders = ["first", "second", "third"].map(folder)
        let dup = dup
        var out: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { out.append(("usage panel: copies: " + name, ok)) }
        let model = AppModel(store: SessionStore(root: projects))
        model.remembers = false
        let usage = UsageModel(store: UsageStore(root: projects, cache: nil))
        model.attach(usage)
        // Asked for before the first read is done: it waits for it.
        model.show(sessionID: dup, projectDir: ProjectDirs.name(for: folders[0]))
        wait(10) { !model.indexing && usage.updated != nil && model.hits.count == 5 && model.selectedSession?.cwd == folders[0] }
        let twins = model.hits.filter { $0.session.id == dup }
        check("one ID filed twice is two rows, each its own identity",
              model.hits.count == 5 && twins.count == 2 && Set(model.hits.map(\.id)).count == 5)
        check("shown before the first read: the copy asked for", model.selectedSession?.cwd == folders[0])
        let second = twins.first { $0.session.cwd == folders[1] }?.session
        if let second { model.selection = second.key }
        check("the second copy can be selected and shown", second != nil && model.selectedSession?.cwd == folders[1]
              && model.selectedSession?.projectDir == ProjectDirs.name(for: folders[1]))
        wait(5) { model.excerptKey == second?.key }
        check("its excerpts are its own", model.excerptKey == second?.key && model.excerpts.contains { String($0.text.characters).contains("beta") })
        let figures = twins.map { usage.usage(for: $0.session)?.tokens.output }
        check("each copy has its own figures", Set(figures.compactMap { $0 }) == [100, 200])
        if let s = twins.first?.session {
            check("a copy not read yet shows nothing, never the other copy's; by ID only with no per-transcript figures",
                  UsageModel.usage(for: s, byFile: ["/elsewhere/x.jsonl": SessionUsage(sessionID: s.id, projectDir: "-e")],
                                   bySession: [s.id: SessionUsage(sessionID: s.id, projectDir: "-e")]) == nil
                  && UsageModel.usage(for: s, byFile: [:], bySession: [s.id: SessionUsage(sessionID: s.id, projectDir: "-e")]) != nil)
        }

        model.show(sessionID: dup, projectDir: ProjectDirs.name(for: folders[0]))
        check("show picks the copy filed under the folder asked for", model.selectedSession?.cwd == folders[0])
        model.show(sessionID: dup, projectDir: nil)
        check("with no folder, the most recently active copy", model.selectedSession?.cwd == folders[1])
        model.show(sessionID: tie, projectDir: nil)
        let first = model.selection
        model.show(sessionID: dup, projectDir: nil)
        model.show(sessionID: tie, projectDir: nil)
        let tied = model.hits.filter { $0.session.id == tie }.map(\.id)
        let tiedSessions = model.hits.filter { $0.session.id == tie }.map(\.session)
        check("two copies alike to the second: the same one every time, by path, in any order",
              tied.count == 2 && first == tied.max() && model.selection == first
              && AppModel.pick(tiedSessions, projectDir: nil)?.key == first && AppModel.pick(tiedSessions.reversed(), projectDir: nil)?.key == first)
        model.query = "zebra"
        wait(5) { model.hits.count == 1 }
        model.show(sessionID: dup, projectDir: ProjectDirs.name(for: folders[0]))
        check("a query that hides it is cleared and the copy selected, at once",
              model.query.isEmpty && model.hits.count == 5 && model.selectedSession?.cwd == folders[0])
        model.show(sessionID: "00000000-0000-4000-8000-000000000000", projectDir: nil)
        check("an ID Search does not know says so, the selection stays",
              model.flash?.contains("not in Search") == true && model.selectedSession?.cwd == folders[0])
        return out
    }

    /// `show(sessionID:projectDir:)` against Return and typing (the independent review's harness): it is
    /// done in one go, Return resumes only the session on screen, and typing cancels a show still waiting.
    @MainActor
    static func races() -> [(String, Bool)] {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("claws-races-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        let (projects, folder) = makeStore(base, ties: false)
        let (first, second, third) = (folder("first"), folder("second"), folder("third"))
        let firstDir = ProjectDirs.name(for: first)
        var out: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { out.append(("usage panel: show: " + name, ok)) }
        var resumed: [String] = []
        func model() -> AppModel {
            let m = AppModel(store: SessionStore(root: projects))
            m.remembers = false
            m.resumer = { resumed.append($0.cwd ?? "?") }
            return m
        }
        let m = model()
        wait(10) { !m.indexing && m.hits.count == 3 }
        func searched(_ q: String, _ n: Int) {
            m.query = q
            wait(5) { m.hits.count == n && m.selectedSession != nil }
            wait(0.3) { false }
        }

        // (a) Return right after Open in Search from a query that hid the session.
        searched("zebra", 1)
        resumed = []
        m.show(sessionID: dup, projectDir: firstDir)
        m.resumeSelected()
        wait(1) { false }
        check("Return right after it resumes the session it selected, nothing else", resumed == [first] && m.selectedSession?.cwd == first)

        // (b) Typing right after it: the new search is yours, nothing stays waiting.
        searched("zebra", 1)
        m.show(sessionID: dup, projectDir: firstDir)
        m.query = "beta"
        wait(5) { m.hits.count == 1 && m.selectedSession?.cwd == second }
        check("typing right after it: the new results, their first hit selected", m.hits.count == 1 && m.selectedSession?.cwd == second)
        resumed = []
        m.resumeSelected()
        check("then Return resumes what is selected", resumed == [second])
        searched("copy", 2)
        check("a later search that holds the old request does not jump to it", m.selectedSession?.cwd == second)

        // (c) Open in Search while a typed query's search is still on its way: the show wins, at once.
        searched("", 3)
        m.query = "zebra"
        m.show(sessionID: dup, projectDir: firstDir)
        let atOnce = m.query.isEmpty && m.selectedSession?.cwd == first
        wait(1) { false }
        check("show while a search is on its way: that search is dropped",
              atOnce && m.query.isEmpty && m.hits.count == 3 && m.selectedSession?.cwd == first)

        // (d) Return waiting for a typed query's results, then Open in Search: nothing is resumed.
        searched("", 3)
        resumed = []
        m.query = "zebra"
        m.resumeSelected()
        m.show(sessionID: dup, projectDir: firstDir)
        wait(1) { false }
        check("a Return waiting for results resumes nothing once show comes", resumed.isEmpty && m.selectedSession?.cwd == first)

        // (e) Before the first read: typing cancels a waiting show; a waiting Return resumes nothing.
        let early = model()
        early.show(sessionID: dup, projectDir: firstDir)
        early.query = "zebra"
        wait(10) { !early.indexing && early.hits.count == 1 && early.selectedSession != nil }
        check("typing before the first read cancels a waiting show", early.query == "zebra" && early.selectedSession?.cwd == third)
        resumed = []
        let early2 = model()
        early2.resumeSelected()
        early2.show(sessionID: dup, projectDir: firstDir)
        wait(10) { !early2.indexing && early2.selectedSession != nil }
        wait(0.5) { false }
        check("Return before the first read, then show: the show is done, nothing resumed",
              resumed.isEmpty && early2.selectedSession?.cwd == first)
        return out
    }

    /// One reply draws a dot: a line with one point draws nothing. Rendered offscreen, as Snapshot does.
    @MainActor
    static func chart() -> [(String, Bool)] {
        NSApplication.shared.setActivationPolicy(.prohibited)
        func ink(_ replies: Int) -> Int {
            var u = SessionUsage(sessionID: "s", projectDir: "-p")
            u.replies = replies
            u.models = ["claude-opus-5-5"]
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            u.context.replies = (0..<replies).map { .init(at: t0 + Double($0) * 60, tokens: 300_000 + $0 * 30_000) }
            u.context.now = u.context.replies.last?.tokens
            u.context.model = "claude-opus-5-5"
            let size = NSSize(width: 520, height: 160)
            let host = NSHostingView(rootView: ContextChart(u: u).padding(10).background(Color.white).frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return -1 }
            host.cacheDisplay(in: host.bounds, to: rep)
            // The plot's marks are the bar grey (#808080): count grey pixels of about that shade inside the
            // plot, away from the axis labels (right and bottom) and the clay 80% line.
            var n = 0
            let w = rep.pixelsWide, h = rep.pixelsHigh
            for y in stride(from: h * 8 / 100, to: h * 60 / 100, by: 1) {
                for x in stride(from: w * 4 / 100, to: w * 80 / 100, by: 1) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
                    if abs(r - g) < 0.04 && abs(g - b) < 0.04 && r > 0.35 && r < 0.65 { n += 1 }
                }
            }
            return n
        }
        let one = ink(1), two = ink(2)
        return [("usage panel: chart: one reply draws a dot (\(one) grey pixels), two a line (\(two))", one > 20 && two > 20)]
    }
}
