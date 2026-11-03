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
        check("context window: 1M for Opus 5.5, 200K for Haiku 4.5 (dated ID), none for an unknown model",
              ContextWindows.size(for: "claude-opus-5-5") == 1_000_000
              && ContextWindows.size(for: "claude-haiku-4-5-20251001") == 200_000
              && ContextWindows.size(for: "claude-opus-4-5") == nil)

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
            // No result written for this Write: its input counts (a final newline starts a line).
            reply("msg_C", "2026-11-02T10:00:30.000Z", usage(3, 50, 3_500, 200), [tool("tu4", "Write", ["file_path": "g", "content": "x\ny\n"])]),
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

        let file1 = dir.appendingPathComponent(id1 + ".jsonl")
        let subs = UsageReader.subagentFiles(for: file1)
        check("subagents: Agent calls and workflow agents, not journals or meta files",
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
        check("tool time: main thread, overlaps once, a call with no result left out", u.toolSeconds == 13, "\(u.toolSeconds)")
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
              !UsageCache.folder.path.hasPrefix(Paths.realHome + "/.claude") && UsageCache.folder.path.contains("/Library/Caches/"))

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
