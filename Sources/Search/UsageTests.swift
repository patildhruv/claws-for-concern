import Foundation

/// The usage reader's checks for `--selftest`: made-up transcripts with every shape that matters
/// (duplicated reply lines, compactions, stale and current cost-states, API errors, subagents and
/// workflow agents, forks, missing and oddly typed fields), the price and window tables, the cache,
/// the demo figures, then a read of your own transcripts (with a cache of its own, not the real one).
enum UsageTests {
    static func run() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            let d = detail()
            out.append((name + (ok || d.isEmpty ? "" : "  [\(d)]"), ok))
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("claws-usage-\(getpid())", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let projects = base.appendingPathComponent("projects", isDirectory: true)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        // MARK: Prices and windows
        let t = SessionUsage.Tokens(output: 250, cacheRead: 1_000, cacheWrite: 2_000, cacheWrite1h: 2_000, input: 10)
        check("price: Opus 5.5 at $4 / $20, 1 h writes $8, reads $0.20",
              close(Pricing.cost(model: "claude-opus-5-5", t), (10 * 4 + 250 * 20 + 2_000 * 8 + 1_000 * 0.2) / 1e6))
        check("price: 5 m writes at 1.25x input",
              close(Pricing.cost(model: "claude-opus-4-8", .init(cacheWrite: 1_000_000)), 6.25))
        check("price: Haiku 5.5 over 100K prompt tokens uses the higher card",
              close(Pricing.cost(model: "claude-haiku-5-5", .init(output: 1_000_000, cacheRead: 100_001)), (100_001 * 0.05 + 1e6 * 2.5) / 1e6)
              && close(Pricing.cost(model: "claude-haiku-5-5", .init(output: 1_000_000, cacheRead: 100_000)), (100_000 * 0.01 + 1e6 * 0.5) / 1e6))
        check("price: Sonnet 4.5 over 200K is not priced (premium not stated)",
              Pricing.cost(model: "claude-sonnet-4-5-20250929", .init(input: 200_001)) == nil
              && Pricing.cost(model: "claude-sonnet-4-5-20250929", .init(input: 1_000_000 / 5)) != nil)
        check("price: fast mode and US-only inference",
              close(Pricing.cost(model: "claude-opus-5-5", .init(output: 1_000_000), speed: "fast"), 40)
              && close(Pricing.cost(model: "claude-opus-5-5", .init(output: 1_000_000), geo: "us"), 22)
              && close(Pricing.cost(model: "claude-opus-4-5", .init(output: 1_000_000), geo: "us"), 25))
        check("price: web searches at $10 per 1,000", close(Pricing.cost(model: "claude-opus-5", .init(), webSearches: 3), 0.03))
        check("price: IDs from Bedrock, Vertex, Claude Code's [1m] and dated ones",
              Pricing.key(for: "us.anthropic.claude-opus-4-1-20250805-v1:0") == "claude-opus-4-1"
              && Pricing.key(for: "claude-opus-4-5@20251101") == "claude-opus-4-5"
              && Pricing.key(for: "claude-opus-5[1m]") == "claude-opus-5"
              && Pricing.key(for: "claude-opus-4-20250514") == "claude-opus-4"
              && Pricing.key(for: "<synthetic>") == nil)
        check("price: an unknown model has none", Pricing.cost(model: "claude-3-7-sonnet-20250219", t) == nil)
        check("context window: 1M for Opus 5.5, 200K for Haiku 4.5 (dated ID) and Opus 4.5, none for a retired model",
              ContextWindows.size(for: "claude-opus-5-5") == 1_000_000
              && ContextWindows.size(for: "claude-haiku-4-5-20251001") == 200_000
              && ContextWindows.size(for: "claude-opus-4-5-20251101") == 200_000
              && ContextWindows.size(for: "claude-opus-4-1-20250805") == nil)

        // MARK: Small pieces
        let stamps = ["2026-11-02T10:00:00.000Z", "2026-11-02T10:00:00Z", "1999-12-31T23:59:59.999Z", "2024-02-29T12:30:05.5Z"]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        check("timestamps parse like ISO8601DateFormatter",
              stamps.allSatisfy { s in
                  guard let a = Timestamp.parse(s), let b = iso.date(from: s) ?? plain.date(from: s) else { return false }
                  return abs(a.timeIntervalSince(b)) < 0.0005
              } && Timestamp.parse("2026-11-02 10:00") == nil)
        let t0 = Date(timeIntervalSince1970: 1_000)
        check("tool time: overlapping calls count once",
              UsageBuilder.union([(t0, t0 + 10), (t0 + 2, t0 + 5), (t0 + 20, t0 + 22)]) == 12)
        check("lines from an Edit's input: the shared head and tail set aside",
              UsageReader.lineChange(old: "a\nb\nc", new: "a\nB\nc") == (1, 1)
              && UsageReader.lineChange(old: "x", new: "x\ny") == (1, 0))

        // MARK: A session with everything
        let folder = base.appendingPathComponent("proj").path
        let dir = projects.appendingPathComponent(ProjectDirs.name(for: folder), isDirectory: true)
        let id1 = "11111111-2222-4333-8444-555555555555"
        func usage(_ input: Int, _ output: Int, _ read: Int, _ write: Int, oneHour: Int? = nil) -> [String: Any] {
            var u: [String: Any] = ["input_tokens": input, "output_tokens": output, "cache_read_input_tokens": read,
                                    "cache_creation_input_tokens": write, "service_tier": "standard", "speed": "standard"]
            if let oneHour { u["cache_creation"] = ["ephemeral_1h_input_tokens": oneHour, "ephemeral_5m_input_tokens": write - oneHour] }
            return u
        }
        func reply(_ id: String, _ at: String, _ u: [String: Any], _ content: [[String: Any]], model: String = "claude-opus-5-5") -> [String: Any] {
            ["type": "assistant", "timestamp": at, "cwd": folder, "requestId": "req_" + id, "sessionId": id1,
             "message": ["id": id, "model": model, "role": "assistant", "usage": u, "content": content]]
        }
        func tool(_ id: String, _ name: String, _ input: [String: Any] = [:]) -> [String: Any] {
            ["type": "tool_use", "id": id, "name": name, "input": input]
        }
        func result(_ at: String, _ ids: [String], extra: [String: Any] = [:]) -> [String: Any] {
            ["type": "user", "timestamp": at, "cwd": folder, "message": ["role": "user", "content": ids.map {
                ["type": "tool_result", "tool_use_id": $0, "content": "ok \"quoted\" \"type\":\"assistant\""] }]].merging(extra) { $1 }
        }
        func prompt(_ at: String, _ text: String) -> [String: Any] {
            ["type": "user", "timestamp": at, "cwd": folder, "message": ["role": "user", "content": text]]
        }
        let main: [Any] = [
            prompt("2026-11-02T09:59:50.000Z", "Fix the bug"),
            // One reply in three lines; the output count grows to its final 250 on the last.
            reply("msg_A", "2026-11-02T10:00:00.000Z", usage(10, 10, 1_000, 2_000, oneHour: 2_000), [["type": "text", "text": "Looking"]]),
            reply("msg_A", "2026-11-02T10:00:01.000Z", usage(10, 10, 1_000, 2_000, oneHour: 2_000), [tool("tu1", "Read", ["file_path": "a"])]),
            reply("msg_A", "2026-11-02T10:00:02.000Z", usage(10, 250, 1_000, 2_000, oneHour: 2_000), [tool("tu2", "Bash", ["command": "ls"])]),
            result("2026-11-02T10:00:05.000Z", ["tu1"]),
            result("2026-11-02T10:00:12.000Z", ["tu2"]),
            reply("msg_B", "2026-11-02T10:00:20.000Z", usage(5, 100, 3_000, 500, oneHour: 500),
                  [tool("tu3", "Edit", ["file_path": "f", "old_string": "a\nb\nc", "new_string": "a\nB\nc\nd"])]),
            // Claude Code's own diff wins over the input's estimate (which would say +3 −2).
            result("2026-11-02T10:00:22.000Z", ["tu3"], extra: ["toolUseResult": ["filePath": "f", "originalFile": "a\nb\nc",
                                                                                  "structuredPatch": [["lines": [" a", "-b", "+B", " c", "+d"]]]]]),
            // A result with no diff (as subagents write them): the input counts (a final newline starts a line).
            reply("msg_C", "2026-11-02T10:00:30.000Z", usage(3, 50, 3_500, 200), [tool("tu4", "Write", ["file_path": "g", "content": "x\ny\n"])]),
            result("2026-11-02T10:00:31.000Z", ["tu4"]),
            ["type": "system", "subtype": "turn_duration", "durationMs": 45_000, "timestamp": "2026-11-02T10:00:35.000Z"],
            ["type": "system", "subtype": "compact_boundary", "timestamp": "2026-11-02T10:01:00.000Z", "content": "Conversation compacted",
             "compactMetadata": ["trigger": "auto", "preTokens": 3_753, "postTokens": 900, "cumulativeDroppedTokens": 2_853, "durationMs": 12_000]],
            ["type": "cost-state", "sessionId": id1, "totalCostUSD": 0.01, "totalLinesAdded": 1, "totalLinesRemoved": 0,
             "modelUsage": ["claude-opus-5-5": ["outputTokens": 410, "cacheReadInputTokens": 7_500]]],
            prompt("2026-11-02T10:59:30.000Z", "Next"),
            // After the cost-state: it is stale now.
            reply("msg_D", "2026-11-02T10:59:40.000Z", usage(2, 20, 0, 900, oneHour: 0), [["type": "text", "text": "Done"]]),
            ["type": "assistant", "timestamp": "2026-11-02T11:00:10.000Z", "isApiErrorMessage": true, "error": "rate_limit", "apiErrorStatus": 429,
             "message": ["id": "err1", "model": "<synthetic>", "role": "assistant", "usage": usage(0, 0, 0, 0),
                         "content": [["type": "text", "text": "API Error: Rate limit reached\nTry again later"]]]],
            ["type": "assistant", "timestamp": "2026-11-02T11:00:10.000Z", "isApiErrorMessage": true, "error": "rate_limit",
             "message": ["id": "err1", "model": "<synthetic>", "content": [["type": "text", "text": "API Error: Rate limit reached"]]]],
            ["type": "system", "subtype": "turn_duration", "durationMs": 60_000, "timestamp": "2026-11-02T11:00:30.000Z"],
            // Copied from the session this one was forked from: not this session's work.
            reply("msg_F", "2026-11-02T11:00:31.000Z", usage(1, 999, 0, 0), []).merging(["forkedFrom": ["sessionId": "x", "messageUuid": "y"]]) { $1 },
            "not json {",
            "",
            // No usage: a timestamp, nothing to count.
            ["type": "assistant", "timestamp": "2026-11-02T11:00:40.000Z", "message": ["id": "msg_E", "model": "claude-opus-5-5", "content": []]],
            ["type": "attachment", "timestamp": "2026-11-02T12:00:00.000Z", "attachment": ["type": "assistant"]],
        ]
        let agent: [Any] = [
            prompt("2026-11-02T10:00:03.000Z", "Find the callers"),
            reply("msg_A", "2026-11-02T10:00:02.000Z", usage(10, 250, 1_000, 2_000, oneHour: 2_000), []),    // a fork's copy
            reply("msg_S1", "2026-11-02T10:00:10.000Z", usage(100, 40, 0, 1_000), [tool("tu5", "Grep", ["pattern": "x"])],
                  model: "claude-haiku-4-5-20251001"),
            result("2026-11-02T10:00:11.000Z", ["tu5"]),
            ["type": "system", "subtype": "turn_duration", "durationMs": 99_000, "timestamp": "2026-11-02T10:00:12.000Z"],
            ["type": "cost-state", "totalCostUSD": 99, "modelUsage": [:] as [String: Any]],
        ]
        let workflow: [Any] = [reply("msg_W1", "2026-11-02T10:00:15.000Z", usage(1, 7, 10, 20), [])]
        let journal: [Any] = [["type": "started", "agentId": "w1", "key": "k"]]
        write(main, to: dir.appendingPathComponent(id1 + ".jsonl"))
        write(agent, to: dir.appendingPathComponent(id1 + "/subagents/agent-a1.jsonl"))
        write(workflow, to: dir.appendingPathComponent(id1 + "/subagents/workflows/wf_1/agent-w1.jsonl"))
        write(journal, to: dir.appendingPathComponent(id1 + "/subagents/workflows/wf_1/journal.jsonl"))
        fm.createFile(atPath: dir.appendingPathComponent(id1 + "/subagents/agent-a1.meta.json").path, contents: Data("{}".utf8))
        // A resumed session's link to the run of the session that started it: its agents count there.
        let elsewhereRun = base.appendingPathComponent("other-session/subagents/workflows/wf_2")
        write(workflow, to: elsewhereRun.appendingPathComponent("agent-w2.jsonl"))
        try? fm.createSymbolicLink(at: dir.appendingPathComponent(id1 + "/subagents/workflows/wf_2"), withDestinationURL: elsewhereRun)

        let file1 = dir.appendingPathComponent(id1 + ".jsonl")
        let subs = UsageReader.subagentFiles(for: file1)
        check("subagents: Agent calls and workflow agents, not journals, meta files or linked runs",
              subs.map(\.lastPathComponent) == ["agent-a1.jsonl", "agent-w1.jsonl"], "\(subs.map(\.lastPathComponent))")
        let u = UsageReader.read(transcript: file1, subagents: subs, projectDir: dir.lastPathComponent, calendar: utc)
        check("replies: each message.id once, a fork's copies and forked lines left out", u.replies == 6, "\(u.replies)")
        check("tokens: the last line's output, subagents included",
              u.tokens == .init(output: 467, cacheRead: 7_510, cacheWrite: 4_620, cacheWrite1h: 2_500, input: 121), "\(u.tokens)")
        check("by model: no <synthetic>, most output first",
              u.models == ["claude-opus-5-5", "claude-haiku-4-5-20251001"] && u.byModel["claude-opus-5-5"]?.replies == 5
              && u.byModel["claude-opus-5-5"]?.tokens.output == 427, "\(u.models)")
        check("subagents: two transcripts, their own tokens",
              u.subagents.count == 2 && u.subagents.tokens == .init(output: 47, cacheRead: 10, cacheWrite: 1_020, cacheWrite1h: 0, input: 101),
              "\(u.subagents)")
        check("context: main thread per reply, now after the last one",
              u.context.replies.map(\.tokens) == [3_010, 3_505, 3_703, 902] && u.context.now == 902
              && u.context.model == "claude-opus-5-5", "\(u.context.replies.map(\.tokens)) now \(u.context.now ?? -1)")
        check("compaction: when, how, before and after",
              u.context.compactions == [.init(at: Timestamp.parse("2026-11-02T10:01:00.000Z")!, trigger: "auto", preTokens: 3_753,
                                              postTokens: 900, droppedTokens: 2_853, seconds: 12)], "\(u.context.compactions)")
        check("turns: Claude Code's durations, main thread only",
              u.turns == .init(count: 2, seconds: 105, longestSeconds: 60, source: .claudeCode), "\(u.turns)")
        check("tool time: main thread, overlaps once", u.toolSeconds == 14, "\(u.toolSeconds)")
        check("tools: each call once, subagents included",
              u.tools == ["Read": 1, "Bash": 1, "Edit": 1, "Write": 1, "Grep": 1], "\(u.tools)")
        check("API errors: once per message, kind, status, first line",
              u.apiErrors.count == 1 && u.apiErrors.first?.kind == "rate_limit" && u.apiErrors.first?.status == 429
              && u.apiErrors.first?.message == "API Error: Rate limit reached", "\(u.apiErrors)")
        let expected = [usage(10, 250, 1_000, 2_000, oneHour: 2_000), usage(5, 100, 3_000, 500, oneHour: 500), usage(3, 50, 3_500, 200),
                        usage(2, 20, 0, 900, oneHour: 0), usage(1, 7, 10, 20)].map { Pricing.cost(model: "claude-opus-5-5", tokens($0))! }
            .reduce(0, +) + Pricing.cost(model: "claude-haiku-4-5", tokens(usage(100, 40, 0, 1_000)))!
        check("cost: a stale cost-state is kept but not used; the estimate prices every reply",
              u.cost.source == .estimate && close(u.cost.usd, expected) && close(u.cost.estimateUSD, expected)
              && u.cost.claudeCodeUSD == 0.01 && u.cost.unpriced.isEmpty, "\(u.cost) vs \(expected)")
        check("lines: Claude Code's diff, else the call's input", u.lines == .init(added: 5, removed: 1, source: .estimate), "\(u.lines)")
        let day = u.days.first
        check("days: one local day, weekday, working time per hour, lines",
              u.days.count == 1 && day?.date == "2026-11-02" && day?.weekday == 2 && day?.replies == 6
              && day?.workSeconds[9] == 10 && day?.workSeconds[10] == 65 && day?.workSeconds[11] == 30
              && day?.linesAdded == 5 && day?.linesRemoved == 1 && day?.tokens == u.tokens,
              "\(u.days.map { "\($0.date) \($0.weekday) \($0.workSeconds.enumerated().filter { $0.element > 0 })" })")
        check("activity: weekday x hour", SessionUsage.activity([u])[1][10] == 65 && SessionUsage.activity([u], from: "2026-11-03")[1][10] == 0)
        check("active: first and last timestamps, the folder that encodes to the project",
              u.firstActive == Timestamp.parse("2026-11-02T09:59:50.000Z") && u.lastActive == Timestamp.parse("2026-11-02T11:00:40.000Z")
              && u.folder == folder, "\(String(describing: u.lastActive))")
        let whole = Data((try? Data(contentsOf: file1)) ?? Data())
        let sizes = [7, 97, 1_024]
        let pieced = sizes.map { size -> SessionUsage in
            let n = UsageReader.pieces(size: whole.count, of: size)
            let events = (0..<n).flatMap { UsageReader.events(in: whole, piece: $0, last: $0 == n - 1, subagent: false, size: size) }
            let rest = subs.map { s in UsageReader.events(in: (try? Data(contentsOf: s)) ?? Data(), piece: 0, last: true, subagent: true) }
            return UsageReader.fold(sessionID: id1, projectDir: dir.lastPathComponent, files: [events] + rest, calendar: utc)
        }
        check("pieces: any piece size reads the same", pieced.allSatisfy { $0 == u })

        // MARK: Cost-states: current, a resumed counter, odd types
        func session(_ id: String, _ lines: [Any]) -> SessionUsage {
            let f = dir.appendingPathComponent(id + ".jsonl")
            write(lines, to: f)
            return UsageReader.read(transcript: f, subagents: [], projectDir: dir.lastPathComponent, calendar: utc)
        }
        let current = session("22222222-2222-4333-8444-555555555555", [
            prompt("2026-11-03T08:00:00.000Z", "Hi"),
            reply("msg_G", "2026-11-03T08:00:20.000Z", usage(1, 100, 1_000, 0), [], model: "claude-opus-4-8"),
            ["type": "cost-state", "totalCostUSD": 1.25, "totalLinesAdded": 7, "totalLinesRemoved": 2,
             "modelUsage": ["claude-opus-4-8[1m]": ["outputTokens": 100, "cacheReadInputTokens": 1_000],
                            "claude-haiku-4-5": ["outputTokens": 30, "cacheReadInputTokens": 0]]],
            ["type": "assistant", "timestamp": "2026-11-03T08:01:00.000Z", "isApiErrorMessage": true, "error": "server_error",
             "message": ["id": "err2", "model": "<synthetic>", "content": [["type": "text", "text": "API Error: 500"]]]],
        ])
        check("cost: a current cost-state that covers the transcript is Claude Code's figure; an error after it changes nothing",
              current.cost.source == .claudeCode && current.cost.usd == 1.25 && current.lines == .init(added: 7, removed: 2, source: .claudeCode),
              "\(current.cost) \(current.lines)")
        check("turns: from prompt to last reply when Claude Code wrote no durations",
              current.turns == .init(count: 1, seconds: 20, longestSeconds: 20, source: .estimate), "\(current.turns)")
        let resumed = session("33333333-2222-4333-8444-555555555555", [
            reply("msg_H", "2026-11-03T09:00:00.000Z", usage(1, 5_000, 100_000, 0), [], model: "claude-opus-5"),
            ["type": "cost-state", "totalCostUSD": 0, "modelUsage": [:] as [String: Any]],
        ])
        check("cost: a resumed process's counter (current, covering nothing) is not used",
              resumed.cost.source == .estimate && (resumed.cost.usd ?? 0) > 0 && resumed.cost.claudeCodeUSD == 0, "\(resumed.cost)")
        let odd = session("44444444-2222-4333-8444-555555555555", [
            ["type": "assistant", "timestamp": "2026-11-03T10:00:00Z",
             "message": ["id": "msg_I", "model": "claude-3-7-sonnet-20250219",
                         "usage": ["input_tokens": "4", "output_tokens": "10", "cache_read_input_tokens": NSNull()], "content": "plain"]],
            ["type": "system", "subtype": "compact_boundary", "timestamp": "2026-11-03T10:00:05Z"],
            ["type": "system", "subtype": "turn_duration", "durationMs": "1500", "timestamp": "2026-11-03T10:00:06Z"],
            ["type": "assistant", "message": ["id": "msg_J", "model": "claude-opus-5", "usage": usage(0, 1, 0, 0)]],
            ["type": "cost-state", "totalCostUSD": "2.5", "totalLinesAdded": "3", "totalLinesRemoved": 1,
             "modelUsage": "{'claude-3-7-sonnet': {'outputTokens': 11, 'cacheReadInputTokens': 0, 'webSearchRequests': None, 'ok': True}}"],
        ])
        check("odd types: numbers as strings, modelUsage as a Python-style dict, a compaction without metadata",
              odd.cost.usd == 2.5 && odd.cost.source == .claudeCode && odd.lines.added == 3 && odd.tokens.output == 11
              && odd.tokens.input == 4 && odd.context.compactions.count == 1 && odd.turns.seconds == 1.5, "\(odd.cost) \(odd.tokens)")
        check("missing fields: a reply without a timestamp counts, but is not on any day or on the context curve",
              odd.replies == 2 && odd.days.reduce(0) { $0 + $1.replies } == 1 && odd.context.replies.count == 1)
        check("an unknown model: not priced, said so, no context percentage, near the limit only at 800K",
              odd.cost.unpriced == ["claude-3-7-sonnet-20250219"] && odd.byModel["claude-3-7-sonnet-20250219"]?.estimatedUSD == nil
              && SessionUsage(sessionID: "x", projectDir: "y", context: .init(now: 800_000, model: "claude-x")).isNearContextLimit
              && !SessionUsage(sessionID: "x", projectDir: "y", context: .init(now: 799_999, model: "claude-x")).isNearContextLimit
              && SessionUsage(sessionID: "x", projectDir: "y", context: .init(now: 800_000, model: "claude-opus-5")).contextFraction == 0.8)

        // MARK: The cache
        let cacheURL = base.appendingPathComponent("cache/usage.json")
        let store = UsageStore(root: projects, cache: UsageCache(url: cacheURL))
        let first = store.load()
        let firstRead = store.lastRead
        let reopened = UsageStore(root: projects, cache: UsageCache(url: cacheURL))
        let again = reopened.load()
        // (The store's days are in your time zone, the reader's above in UTC: compare the rest.)
        check("cache: a reopen reads nothing that did not change, and gives the same figures",
              firstRead == 4 && reopened.lastRead == 0 && again == first && first[id1]?.tokens == u.tokens
              && first[id1]?.context == u.context && first[id1]?.cost == u.cost, "\(firstRead) then \(reopened.lastRead)")
        if let h = try? FileHandle(forWritingTo: dir.appendingPathComponent(id1 + "/subagents/agent-a1.jsonl")) {
            h.seekToEndOfFile()
            h.write(Data(("\n" + json(reply("msg_S2", "2026-11-02T10:00:13.000Z", usage(0, 3, 0, 0), [])) + "\n").utf8))
            try? h.close()
        }
        let changed = reopened.load()
        check("cache: a changed subagent file re-reads its session only",
              reopened.lastRead == 1 && changed[id1]?.tokens.output == 470, "\(reopened.lastRead) \(changed[id1]?.tokens.output ?? -1)")
        try? fm.removeItem(at: dir.appendingPathComponent("44444444-2222-4333-8444-555555555555.jsonl"))
        check("cache: a deleted transcript drops out", reopened.load().count == 3)
        check("lookup by transcript path, else by ID", reopened.usage(forTranscript: file1)?.tokens.output == 470
              && reopened.usage(forTranscript: URL(fileURLWithPath: "/elsewhere/\(id1).jsonl"))?.sessionID == id1)
        let elsewhere = TimeZone(identifier: TimeZone.current.identifier == "Asia/Tokyo" ? "Europe/Paris" : "Asia/Tokyo")!
        check("cache: another time zone starts afresh",
              !UsageCache(url: cacheURL).load().isEmpty && UsageCache(url: cacheURL, timeZone: elsewhere).load().isEmpty)
        check("cache: in the helper's own cache folder, never under ~/.claude",
              !UsageCache.defaultFolder.path.hasPrefix(Paths.realHome + "/.claude") && UsageCache.defaultFolder.path.contains("/Library/Caches/"))
        out += review()

        // MARK: The demo
        let root = Demo.activate()
        let demo = UsageStore(cache: UsageCache(url: base.appendingPathComponent("demo-cache.json"))).load()
        let ids = Set(Demo.sessions.map(\.id))
        let all = Array(demo.values)
        check("demo: figures for all 12 made-up sessions, read from nothing",
              Set(demo.keys) == ids && !fm.fileExists(atPath: base.appendingPathComponent("demo-cache.json").path))
        check("demo: Claude Code's figure and estimates, a stale record, an unpriced model",
              all.contains { $0.cost.source == .claudeCode } && all.contains { $0.cost.source == .estimate && $0.cost.claudeCodeUSD != nil }
              && all.contains { !$0.cost.unpriced.isEmpty && $0.contextFraction == nil })
        check("demo: compactions, a session near its limit, subagents, API errors, per-day lines",
              all.contains { !$0.context.compactions.isEmpty } && all.contains(where: \.isNearContextLimit)
              && all.contains { $0.subagents.count > 0 } && all.contains { !$0.apiErrors.isEmpty }
              && all.contains { s in s.lines.source == .claudeCode && s.days.reduce(0) { $0 + s.lines(of: $1).added } == s.lines.added })
        check("demo: each session's days add up to its tokens, and its last day is its transcript's",
              all.allSatisfy { s in s.days.reduce(SessionUsage.Tokens()) { $0 + $1.tokens } == s.tokens })
        let sessions = SessionStore().load().sessions
        check("demo: figures end when the made-up transcripts do",
              sessions.allSatisfy { s in demo[s.id].map { abs(($0.lastActive ?? .distantPast).timeIntervalSince(s.modified)) < 1 } ?? false },
              "\(sessions.map { s in (demo[s.id]?.lastActive ?? .distantPast).timeIntervalSince(s.modified) })")
        Demo.deactivate()
        check("demo: off again", Demo.usage.isEmpty && !fm.fileExists(atPath: root.path))
        return out
    }

    /// Your own transcripts, read twice with a cache of the test's own: the timings, and invariants
    /// that must hold for every session.
    static func real() -> [(String, Bool)] {
        let fm = FileManager.default
        let cacheURL = fm.temporaryDirectory.appendingPathComponent("claws-usage-real-\(getpid())/usage.json")
        defer { try? fm.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let t0 = CFAbsoluteTimeGetCurrent()
        let all = UsageStore(cache: UsageCache(url: cacheURL)).load()
        let t1 = CFAbsoluteTimeGetCurrent()
        let reopen = UsageStore(cache: UsageCache(url: cacheURL))
        _ = reopen.load()
        let t2 = CFAbsoluteTimeGetCurrent()
        let u = Array(all.values)
        let byKind = Dictionary(grouping: u, by: \.cost.source).mapValues(\.count)
        print(String(format: "info usage: %d sessions, %d replies; first read %.2fs, reopen %.2fs (%d re-read); cost: %d Claude Code's, %d est.",
                     u.count, u.reduce(0) { $0 + $1.replies }, t1 - t0, t2 - t1, reopen.lastRead,
                     byKind[.claudeCode] ?? 0, byKind[.estimate] ?? 0))
        func sum(_ t: [SessionUsage.Tokens]) -> SessionUsage.Tokens { t.reduce(.init(), +) }
        return [
            ("usage: transcripts read", !u.isEmpty),
            ("usage: a first read in 5 s or less", t1 - t0 <= 5),
            ("usage: a reopen in 1 s or less, re-reading only live sessions", t2 - t1 <= 1 && reopen.lastRead <= 5),
            ("usage: every session's models add up to its tokens", u.allSatisfy { s in sum(s.byModel.values.map(\.tokens)) == s.tokens }),
            ("usage: subagents' tokens are part of the total",
             u.allSatisfy { s in let m = s.mainTokens; return m.output >= 0 && m.cacheRead >= 0 && m.input >= 0 && m.cacheWrite >= 0 }),
            ("usage: no more context points than replies, none <synthetic>",
             u.allSatisfy { $0.context.replies.count <= $0.replies && !$0.models.contains("<synthetic>") }),
            ("usage: a cost for every session with a priced reply",
             u.allSatisfy { $0.cost.usd != nil || $0.byModel.values.allSatisfy { $0.estimatedUSD == nil } }),
            ("usage: turns no longer than Claude's working time", u.allSatisfy { $0.turns.longestSeconds <= $0.turns.seconds + 0.001 }),
        ]
    }

    private static func tokens(_ u: [String: Any]) -> SessionUsage.Tokens {
        let cc = u["cache_creation"] as? [String: Int]
        return .init(output: u["output_tokens"] as? Int ?? 0, cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
                     cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0, cacheWrite1h: cc?["ephemeral_1h_input_tokens"] ?? 0,
                     input: u["input_tokens"] as? Int ?? 0)
    }

    private static func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }

    private static func json(_ o: Any) -> String {
        if let s = o as? String { return s }
        return String(decoding: (try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
    }

    private static func write(_ lines: [Any], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data((lines.map(json).joined(separator: "\n") + "\n").utf8))
    }
}

extension UsageTests {
    /// The independent review of 2026-11-03: each finding as made-up transcripts (cases A to J are the
    /// reviewer's own), then lines no transcript should hold, at random.
    static func review() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            out.append((name + (ok ? "" : "  [\(detail())]"), ok))
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("claws-usage-review-\(getpid())", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let sid = "11111111-2222-4333-8444-555555555555"
        func u(_ i: Int, _ o: Int, _ r: Int, _ w: Int) -> [String: Any] {
            ["input_tokens": i, "output_tokens": o, "cache_read_input_tokens": r, "cache_creation_input_tokens": w,
             "cache_creation": ["ephemeral_1h_input_tokens": 0, "ephemeral_5m_input_tokens": w]]
        }
        func asst(_ id: String, _ ts: String, _ usage: [String: Any], _ content: [[String: Any]], _ extra: [String: Any] = [:]) -> [String: Any] {
            ["type": "assistant", "timestamp": ts, "cwd": "/tmp/proj", "sessionId": sid, "uuid": "u-\(id)-\(ts)",
             "message": ["id": id, "model": "claude-opus-4-6", "role": "assistant", "usage": usage, "content": content]]
                .merging(extra) { $1 }
        }
        func prompt(_ ts: String, _ text: String = "hello", uuid: String? = nil) -> [String: Any] {
            ["type": "user", "timestamp": ts, "cwd": "/tmp/proj", "uuid": uuid ?? "p-\(ts)", "message": ["role": "user", "content": text]]
        }
        func result(_ ts: String, _ id: String, _ tur: Any? = nil, error: Bool = false, text: String = "ok") -> [String: Any] {
            var d: [String: Any] = ["type": "user", "timestamp": ts, "cwd": "/tmp/proj", "uuid": "r-\(id)-\(ts)",
                                    "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": text,
                                                                             "is_error": error]]]]
            if let tur { d["toolUseResult"] = tur }
            return d
        }
        func edit(_ id: String, _ old: String, _ new: String) -> [String: Any] {
            ["type": "tool_use", "id": id, "name": "Edit", "input": ["file_path": "/tmp/proj/a.txt", "old_string": old, "new_string": new]]
        }
        func wr(_ id: String, _ content: String) -> [String: Any] {
            ["type": "tool_use", "id": id, "name": "Write", "input": ["file_path": "/tmp/proj/b.txt", "content": content]]
        }
        func call(_ id: String, _ name: String) -> [String: Any] { ["type": "tool_use", "id": id, "name": name, "input": [:] as [String: Any]] }
        func text(_ s: String) -> [[String: Any]] { [["type": "text", "text": s]] }
        func turn(_ ts: String, _ ms: Any) -> [String: Any] {
            ["type": "system", "subtype": "turn_duration", "timestamp": ts, "durationMs": ms, "uuid": "t-\(ts)"]
        }
        var n = 0
        func read(_ main: [Any], _ subagents: [[Any]] = [], calendar: Calendar? = nil) -> SessionUsage {
            n += 1
            let file = base.appendingPathComponent("s\(n)/-tmp-proj/\(sid).jsonl")
            write(main, to: file)
            for (i, s) in subagents.enumerated() {
                write(s, to: file.deletingPathExtension().appendingPathComponent("subagents/agent-a\(i).jsonl"))
            }
            return UsageReader.read(transcript: file, subagents: UsageReader.subagentFiles(for: file), projectDir: "-tmp-proj",
                                    calendar: calendar ?? utc)
        }
        let t = { (s: String) in "2026-11-02T\(s).000Z" }

        // 1. Failed and rejected Edit and Write calls change nothing.
        let a = read([prompt(t("10:00:00")),
                      asst("msg_1", t("10:00:05"), u(10, 50, 0, 1_000), [edit("toolu_1", "a\nb", "x\ny\nz")]),
                      result(t("10:00:06"), "toolu_1", "Error: String to replace not found in file.", error: true),
                      asst("msg_2", t("10:00:10"), u(10, 50, 1_000, 10), [wr("toolu_2", "1\n2\n3\n4\n5\n")]),
                      result(t("10:00:20"), "toolu_2", "User rejected tool use", error: true),
                      asst("msg_3", t("10:00:25"), u(10, 50, 1_000, 10), [wr("toolu_3", "1\n")]),
                      result(t("10:00:26"), "toolu_3", "Error: file was modified"),           // text only, no is_error
                      asst("msg_4", t("10:00:30"), u(10, 50, 1_000, 10), [edit("toolu_4", "p", "q\nr")]),
                      result(t("10:00:31"), "toolu_4", error: true),                           // is_error, no text
                      asst("msg_5", t("10:00:35"), u(10, 50, 1_000, 10), [edit("toolu_5", "s", "t")])])   // no result
        check("review 1: failed, rejected or unanswered Edit and Write calls count no lines (case A)",
              a.lines == .init(added: 0, removed: 0, source: .estimate) && a.days.allSatisfy { $0.linesAdded == 0 }, "\(a.lines)")

        // 2. A forked subagent's copy of the parent's Edit and its result count once.
        let patch: [String: Any] = ["filePath": "/tmp/proj/a.txt", "structuredPatch": [["oldStart": 1, "lines": ["-old", "+new"]]]]
        let parent: [Any] = [prompt(t("10:00:00")), asst("msg_1", t("10:00:05"), u(10, 50, 0, 1_000), [edit("toolu_1", "old", "new")]),
                             result(t("10:00:06"), "toolu_1", patch)]
        let b = read(parent + [asst("msg_2", t("10:00:30"), u(10, 20, 1_000, 10), text("done"))],
                     [parent.dropFirst().map { ($0 as! [String: Any]).merging(["isSidechain": true]) { $1 } }
                      + [asst("msg_s1", t("10:00:20"), u(5, 30, 1_000, 10), text("sub"))]])
        check("review 2: a forked subagent's copied diff counts once, by its call (case B)",
              b.lines.added == 1 && b.lines.removed == 1 && b.replies == 3, "\(b.lines) \(b.replies)")

        // 3. Tool time: never a question or a plan, and only while Claude worked.
        let wait = read([prompt(t("10:00:00")),
                         asst("msg_1", t("10:00:05"), u(1, 1, 0, 10), [call("tq", "AskUserQuestion")]),
                         result(t("10:30:05"), "tq"),                                   // 30 min for your answer
                         asst("msg_2", t("10:30:10"), u(1, 1, 0, 10), [call("tb", "Bash")]),
                         result(t("10:40:10"), "tb"),                                   // a permission prompt, then the run
                         asst("msg_3", t("10:40:15"), u(1, 1, 0, 10), text("done")),
                         turn(t("10:40:15"), 60_000)])
        check("review 3: tool time leaves out questions and plans, and stays within Claude's working time",
              wait.toolSeconds == 55 && wait.toolSeconds <= wait.turns.seconds && wait.turns.seconds == 60,
              "tool \(wait.toolSeconds) worked \(wait.turns.seconds)")

        // 4. No input traps (cases C, C2, C3), and impossible values count as missing.
        let huge = read([prompt(t("10:00:00")),
                         #"{"type":"assistant","timestamp":"2026-11-02T10:00:05.000Z","message":{"id":"msg_1","model":"claude-opus-4-6","usage":{"input_tokens":1,"output_tokens":1e19}}}"#,
                         #"{"type":"assistant","timestamp":"2026-11-02T10:00:06.000Z","message":{"id":"msg_2","model":"claude-opus-4-6","usage":{"input_tokens":1,"output_tokens":"inf","cache_read_input_tokens":"nan","cache_creation_input_tokens":-5}}}"#,
                         #"{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-02T10:00:07.000Z","compactMetadata":{"trigger":"auto","preTokens":1e20,"postTokens":"1e400","durationMs":"-inf"}}"#,
                         #"{"type":"assistant","timestamp":"2026-11-02T10:00:08.000Z","isApiErrorMessage":true,"error":"x","apiErrorStatus":1e30,"message":{"id":"e1","model":"<synthetic>"}}"#,
                         #"{"type":"cost-state","totalCostUSD":"1e400","totalLinesAdded":1e300,"totalLinesRemoved":-1,"modelUsage":{"m":{"outputTokens":1e300,"cacheReadInputTokens":"inf"}}}"#,
                         #"{"type":"system","subtype":"turn_duration","timestamp":"2026-11-02T10:00:09.000Z","durationMs":1e300}"#])
        check("review 4: numbers too big, negative, inf or nan are missing, and nothing traps (cases C, C2, C3)",
              huge.tokens == .init(output: 0, cacheRead: 0, cacheWrite: 0, cacheWrite1h: 0, input: 2)
              && huge.context.compactions.first?.preTokens == nil && huge.context.compactions.first?.seconds == nil
              && huge.apiErrors.first?.status == nil && huge.cost.claudeCodeUSD == nil, "\(huge.tokens)")
        check("review 4: sums saturate instead of trapping",
              Int.max.addingSaturating(1) == .max && Int.min.addingSaturating(-1) == .min && Int(saturating: .infinity) == .max
              && Int(saturating: .nan) == 0 && (SessionUsage.Tokens(output: .max) + .init(output: 5)).output == .max)
        let t0 = CFAbsoluteTimeGetCurrent()
        let fuzzed = fuzz(seed: 7, lines: 3_000, utc)
        check("review 4: 3,000 random lines (wrong types, huge and odd numbers, corrupt dates, cut lines) read without a trap",
              fuzzed.allSatisfy { $0 } && CFAbsoluteTimeGetCurrent() - t0 < 10,
              String(format: "%.1fs, %@", CFAbsoluteTimeGetCurrent() - t0, "\(fuzzed)"))

        // 5. Turns one by one: Claude Code's record where it wrote one, else an estimate (case I).
        let mixed = read([prompt(t("10:00:00")), asst("msg_1", t("10:10:00"), u(1, 1, 0, 10), text("a")),
                          prompt(t("11:00:00")), asst("msg_2", t("11:20:00"), u(1, 1, 0, 10), text("b")),
                          prompt(t("12:00:00")), asst("msg_3", t("12:01:00"), u(1, 1, 0, 10), text("c")),
                          turn(t("12:01:00"), 60_000)])
        check("review 5: a turn without a record is estimated even when others have one (case I)",
              mixed.turns == .init(count: 3, seconds: 1_860, longestSeconds: 1_200, source: .estimate), "\(mixed.turns)")
        let queued = read([prompt(t("10:00:00")), asst("msg_1", t("10:05:00"), u(1, 1, 0, 10), text("a")),
                           prompt(t("10:06:00"), "and also this"), asst("msg_2", t("10:10:00"), u(1, 1, 0, 10), text("b")),
                           turn(t("10:10:00"), 600_000)])
        check("review 5: a prompt queued inside a recorded turn adds no time of its own",
              queued.turns == .init(count: 1, seconds: 600, longestSeconds: 600, source: .claudeCode), "\(queued.turns)")
        let absurd = read([prompt(t("10:00:00")), asst("msg_1", t("10:00:05"), u(10, 50, 0, 1_000), text("hi")),
                           turn(t("10:00:06"), 3.6e12),
                           prompt("9999-12-31T23:59:59.999Z"), asst("msg_2", "9999-12-31T23:59:59.999Z", u(1, 1, 0, 1), text("x"))])
        check("review 5: an impossible duration or a year-9999 date is ignored, quickly (case D)",
              absurd.turns == .init(count: 1, seconds: 5, longestSeconds: 5, source: .estimate) && absurd.days.count == 1
              && absurd.lastActive == Timestamp.parse(t("10:00:05")), "\(absurd.turns) \(absurd.days.map(\.date))")

        // Low: context after a compaction that kept no count; identical writes; errors without a time.
        let e = read([prompt(t("10:00:00")), asst("msg_1", t("10:00:05"), u(10, 50, 900_000, 1_000), text("hi")),
                      ["type": "system", "subtype": "compact_boundary", "timestamp": t("10:01:00"),
                       "compactMetadata": ["trigger": "manual", "preTokens": 901_010]],
                      ["type": "assistant", "isApiErrorMessage": true, "error": "rate_limit",
                       "message": ["id": "e9", "model": "<synthetic>", "content": text("API Error")]]])
        check("review low: a compaction that says nothing of what it kept leaves context now unknown (case E)",
              e.context.now == nil && e.context.model == "claude-opus-4-6", "\(String(describing: e.context.now))")
        check("review low: an API error without a time moves neither end of the session",
              e.apiErrors.count == 1 && e.firstActive == Timestamp.parse(t("10:00:00")), "\(String(describing: e.firstActive))")
        let same = read([prompt(t("10:00:00")), asst("msg_1", t("10:00:05"), u(10, 50, 0, 1_000), [wr("toolu_1", "1\n2\n3\n")]),
                         result(t("10:00:06"), "toolu_1", ["type": "update", "filePath": "/tmp/proj/b.txt", "content": "1\n2\n3\n",
                                                          "structuredPatch": [] as [Any]])])
        check("review low: writing a file unchanged counts no lines (case J)", same.lines.added == 0 && same.lines.removed == 0,
              "\(same.lines)")
        let marks = read([prompt(t("10:00:00")), asst("msg_1", t("10:00:05"), u(10, 50, 0, 1_000), [edit("toolu_1", "a", "b")]),
                          result(t("10:00:06"), "toolu_1", ["structuredPatch": [["lines": ["-\u{0CBC}x", "+\u{0301}y", " z"]]]])])
        check("lines: a diff line that starts with a sign and a combining mark still counts (seen in a real diff)",
              marks.lines.added == 1 && marks.lines.removed == 1, "\(marks.lines)")
        let cut = read([prompt(t("10:00:00")), asst("msg_1", t("10:00:05"), u(10, 50, 0, 1_000), text("hi")),
                        #"{"type":"assistant","timestamp":"2026-11-02T10:00:09.000Z","message":{"id":"msg_2","model":"claude-opus-4-6","usage":{"input_tokens":1,"outp"#])
        check("review low: a line still being written is left out (case H)", cut.replies == 1)
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        let dst = read([prompt("2026-11-01T05:30:00.000Z"), asst("msg_1", "2026-11-01T06:30:00.000Z", u(10, 50, 0, 1_000), text("hi")),
                        turn("2026-11-01T06:30:00.000Z", 3_600_000),
                        prompt("2026-11-02T04:30:00.000Z"), asst("msg_2", "2026-11-02T05:30:00.000Z", u(10, 50, 0, 1_000), text("hi")),
                        turn("2026-11-02T05:30:00.000Z", 3_600_000)], calendar: ny)
        let nov1 = dst.days.first { $0.date == "2026-11-01" }, nov2 = dst.days.first { $0.date == "2026-11-02" }
        check("review low: the hour that repeats when clocks go back, and a turn across midnight (case G)",
              nov1?.workSeconds[1] == 3_600 && nov1?.workSeconds[23] == 1_800 && nov2?.workSeconds[0] == 1_800 && nov2?.weekday == 2,
              "\(dst.days.map { "\($0.date) \($0.workSeconds.enumerated().filter { $0.element > 0 })" })")
        var share = SessionUsage(sessionID: "x", projectDir: "y")
        share.lines = .init(added: 10, removed: 0, source: .claudeCode)
        share.days = [.init(date: "2026-11-01", weekday: 1, workSeconds: [600] + Array(repeating: 0, count: 23)),
                      .init(date: "2026-11-02", weekday: 2, workSeconds: [2_400] + Array(repeating: 0, count: 23))]
        check("review low: Claude Code's lines with none counted per day split as the working time did",
              share.days.map { share.lines(of: $0).added } == [2, 8], "\(share.days.map { share.lines(of: $0).added })")

        // 6 and 7, through the store: a transcript that is a link, and two diverged copies of one session.
        let root = base.appendingPathComponent("store/projects", isDirectory: true)
        let realFile = root.appendingPathComponent("-tmp-proj/\(sid).jsonl")
        write([prompt(t("10:00:00")), asst("msg_1", t("10:00:05"), u(10, 50, 0, 1_000), text("hi"))], to: realFile)
        let linkFile = root.appendingPathComponent("-tmp-other/\(sid).jsonl")
        try? fm.createDirectory(at: linkFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: linkFile, withDestinationURL: realFile)
        let guarded = root.appendingPathComponent("-tmp-guarded/22222222-2222-4333-8444-555555555555.jsonl")
        try? fm.createDirectory(at: guarded.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: guarded.path, withDestinationPath: Paths.realHome + "/Documents/never-read.jsonl")
        let cacheURL = base.appendingPathComponent("store/cache.json")
        let store = UsageStore(root: root, cache: UsageCache(url: cacheURL))
        // Listings may spell the temporary folder /private/var/…: find entries by their folder and name.
        func listed(_ s: UsageStore, _ tail: String) -> SessionUsage? { s.byTranscript.first { $0.key.hasSuffix(tail) }?.value }
        let once = store.load()
        check("review 6: a linked transcript is read once, through its target; a link into a protected folder is never followed (case F)",
              once.count == 1 && store.lastRead == 1 && listed(store, "-tmp-other/\(sid).jsonl") == listed(store, "-tmp-proj/\(sid).jsonl")
              && listed(store, "-tmp-other/\(sid).jsonl")?.replies == 1 && listed(store, "-tmp-guarded/22222222-2222-4333-8444-555555555555.jsonl") == nil,
              "\(once.count) read \(store.lastRead) \(store.byTranscript.keys.sorted())")
        if let h = try? FileHandle(forWritingTo: realFile) {
            h.seekToEndOfFile()
            h.write(Data((json(asst("msg_2", t("10:00:09"), u(1, 1, 0, 1), text("more"))) + "\n").utf8))
            try? h.close()
        }
        _ = store.load()
        check("review 6: the link refreshes when its target changes", listed(store, "-tmp-other/\(sid).jsonl")?.replies == 2)

        let copies = base.appendingPathComponent("copies/projects", isDirectory: true)
        let shared: [Any] = [prompt(t("09:00:00"), uuid: "p1"), asst("msg_1", t("09:00:05"), u(1, 10, 0, 100), text("a")),
                             turn(t("09:00:05"), 5_000), asst("msg_2", t("09:00:06"), u(1, 10, 100, 100), text("b"))]
        write(shared + [prompt(t("10:00:00"), uuid: "p2"), asst("msg_3", t("10:00:05"), u(1, 10, 200, 100), text("c"))],
              to: copies.appendingPathComponent("-tmp-one/\(sid).jsonl"))
        write(shared + [prompt(t("11:00:00"), uuid: "p3"), asst("msg_4", t("11:00:05"), u(1, 10, 300, 100), text("d")),
                        asst("msg_5", t("11:00:09"), u(1, 10, 400, 100), text("e"))],
              to: copies.appendingPathComponent("-tmp-two/\(sid).jsonl"))
        let both = UsageStore(root: copies, cache: UsageCache(url: base.appendingPathComponent("copies/cache.json")))
        let merged = both.load()[sid]
        let one = listed(both, "-tmp-one/\(sid).jsonl"), two = listed(both, "-tmp-two/\(sid).jsonl")
        check("review 7: a session filed twice gets figures from both copies, each reply and line once",
              merged?.replies == 5 && merged?.tokens.output == 50 && merged?.turns.count == 3 && one?.replies == 3 && two?.replies == 4
              && merged?.context.now == 501 && merged?.context.replies.count == 5,
              "merged \(merged?.replies ?? -1) turns \(merged?.turns.count ?? -1) now \(merged?.context.now ?? -1)")
        return out
    }

    /// Random lines that try every shape a field can take: each must read without a trap, and give
    /// figures that are finite and not negative.
    private static func fuzz(seed: UInt64, lines count: Int, _ calendar: Calendar) -> [Bool] {
        var state = seed
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        func pick<T>(_ xs: [T]) -> T { xs[Int(next() % UInt64(xs.count))] }
        let dates = ["2026-11-02T10:00:00.000Z", "2026-11-02T23:59:59.999Z", "9999-12-31T23:59:59.999Z", "0001-01-01T00:00:00Z",
                     "2026-13-45T25:61:61Z", "2026-11-02", "", "x", "2026-11-02T10:00:00+05:30"]
        let keys = ["type", "subtype", "timestamp", "uuid", "message", "toolUseResult", "durationMs", "compactMetadata", "totalCostUSD",
                    "modelUsage", "totalLinesAdded", "isApiErrorMessage", "error", "apiErrorStatus", "forkedFrom", "cwd", "isMeta",
                    "id", "model", "usage", "content", "input_tokens", "output_tokens", "cache_read_input_tokens",
                    "cache_creation_input_tokens", "cache_creation", "ephemeral_1h_input_tokens", "tool_use_id", "is_error", "name",
                    "input", "structuredPatch", "lines", "preTokens", "postTokens", "outputTokens", "cacheReadInputTokens", "old_string",
                    "new_string"]
        func value(_ depth: Int) -> Any {
            switch next() % 14 {
            case 0: return Int.max
            case 1: return -1
            case 2: return 1e19
            case 3: return 1e300
            case 4: return pick(["inf", "-inf", "nan", "1e400", "-0", "12abc", " 7 "])
            case 5: return NSNull()
            case 6: return next() % 2 == 0
            case 7: return depth > 2 ? 0 : (0..<Int(next() % 3)).map { _ in value(depth + 1) }
            case 8:
                guard depth <= 2 else { return "" }
                var d: [String: Any] = [:]
                for _ in 0..<Int(next() % 4) { d[pick(keys)] = value(depth + 1) }
                return d
            case 9: return pick(dates)
            case 10: return Int(next() % 100_000)
            case 11: return Double(next() % 1_000) / 7
            default: return pick(["assistant", "user", "system", "tool_use", "tool_result", "text", "Edit", "Write", "create", "+a", "-b"])
            }
        }
        var text = ""
        for _ in 0..<count {
            var line: [String: Any] = ["type": pick(["assistant", "user", "system", "cost-state", "attachment"]),
                                       "timestamp": pick(dates), "subtype": pick(["compact_boundary", "turn_duration", "x"])]
            line["message"] = ["id": "m\(next() % 50)", "model": pick(["claude-opus-4-6", "<synthetic>", "claude-x"]),
                               "usage": Dictionary(uniqueKeysWithValues: ["input_tokens", "output_tokens", "cache_read_input_tokens",
                                                                          "cache_creation_input_tokens"].map { ($0, value(1)) }),
                               "content": [["type": pick(["tool_use", "tool_result", "text"]), "id": "t\(next() % 30)",
                                            "tool_use_id": "t\(next() % 30)", "name": pick(["Edit", "Write", "Bash", "AskUserQuestion"]),
                                            "is_error": value(2), "text": value(2),
                                            "input": ["old_string": value(2), "new_string": value(2), "content": value(2)]]]]
            for _ in 0..<Int(next() % 6) { line[pick(keys)] = value(0) }
            let s = String(decoding: (try? JSONSerialization.data(withJSONObject: line)) ?? Data(), as: UTF8.self)
            text += (next() % 9 == 0 ? String(s.prefix(Int(next() % UInt64(max(1, s.count))))) : s) + "\n"
        }
        let data = Data(text.utf8)
        let main = (0..<UsageReader.pieces(size: data.count, of: 4_096)).flatMap {
            UsageReader.events(in: data, piece: $0, last: $0 == UsageReader.pieces(size: data.count, of: 4_096) - 1, subagent: false, size: 4_096)
        }
        let sub = UsageReader.events(in: data, piece: 0, last: true, subagent: true)
        let s = UsageReader.fold(sessionID: "fuzz", projectDir: "-fuzz", files: [main, main, sub], mains: 2, calendar: calendar)
        let t = s.tokens
        return [t.output >= 0, t.cacheRead >= 0, t.cacheWrite >= 0, t.input >= 0, s.turns.seconds.isFinite, s.turns.seconds >= 0,
                s.toolSeconds <= s.turns.seconds + 1e-6, s.days.count < 400, (s.cost.usd ?? 0).isFinite, s.lines.added >= 0]
    }
}
