import Foundation

/// Reads a session's transcript and its subagents' into a `SessionUsage`. Most bytes are tool output,
/// attachments and request logs: a line is JSON-decoded only if it may carry a record that counts
/// (`wanted`). Each file is cut into pieces of whole lines (`pieceSize`) that parse independently into
/// `Event`s, so `UsageStore` can read every piece of every file at once; `fold` then plays a
/// session's events, file by file in order, through `UsageBuilder`. Facts and traps: docs/usage.md.
enum UsageReader {
    /// Subagent transcripts: `<session>/subagents/*.jsonl` (Agent calls) and
    /// `<session>/subagents/workflows/<run>/agent-*.jsonl` (workflow agents), sorted by path. A link is
    /// never followed: a resumed session's run folder can be a link to the run in the session that
    /// started it, whose agents count there.
    static func subagentFiles(for transcript: URL, list: (URL) -> [URL] = Self.list) -> [URL] {
        func linked(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
        let dir = transcript.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        var out = list(dir).filter { $0.pathExtension == "jsonl" && !linked($0) }
        for run in list(dir.appendingPathComponent("workflows", isDirectory: true)) where !linked(run) {
            out += list(run).filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-") && !linked($0) }
        }
        return out.sorted { $0.path < $1.path }
    }

    static func list(_ dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                      options: [.skipsHiddenFiles])) ?? []
    }

    /// One session, in this thread.
    static func read(transcript: URL, subagents: [URL], projectDir: String, calendar: Calendar = .usage) -> SessionUsage {
        let files = ([transcript] + subagents).enumerated().map { i, url in events(of: url, subagent: i > 0) }
        return fold(sessionID: transcript.deletingPathExtension().lastPathComponent, projectDir: projectDir,
                    files: files, calendar: calendar)
    }

    /// A whole file's events.
    static func events(of url: URL, subagent: Bool) -> [Event] {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return [] }
        let n = pieces(size: data.count)
        return (0..<n).flatMap { events(in: data, piece: $0, last: $0 == n - 1, subagent: subagent) }
    }

    /// What one line contributes, in file order.
    enum Event {
        /// A main-thread line's `uuid`, before its events: the copies of one conversation share lines.
        case line(String)
        case saw(Date?)
        case cwd(String)
        case reply(id: String, UsageBuilder.Reply)
        case apiError(SessionUsage.APIError, id: String?)
        case toolUse(id: String, name: String, at: Date?, lines: (added: Int, removed: Int)?)
        /// `failed`: `is_error`, or a result that is only text ("Error: …", "User rejected tool use").
        case toolResult(id: String, at: Date?, failed: Bool)
        /// Claude Code's own diff in an Edit or Write result, for the calls the line answers.
        case patch(added: Int, removed: Int, at: Date?, ids: [String])
        case prompt(Date?)
        case compaction(SessionUsage.Compaction)
        case turn(end: Date, seconds: Double)
        case costState(UsageBuilder.CostState)
    }

    /// Plays a session's events through the builder. `files` are its transcripts, then its subagents
    /// in `subagentFiles` order; `mains` says which are main transcripts (by default only the first).
    /// Several mains are copies of one conversation filed under two project folders, oldest first: a
    /// line they share (the same `uuid`) counts once, and so does a reply (the same `message.id`).
    static func fold(sessionID: String, projectDir: String, files: [[Event]], mains: Int = 1,
                     calendar: Calendar = .usage) -> SessionUsage {
        var b = UsageBuilder(sessionID: sessionID, projectDir: projectDir, calendar: calendar)
        b.subagentCount = max(0, files.count - mains)
        // Lines changed by Edit and Write, once per call and only when it succeeded: Claude Code's own
        // diff in the result, else (subagents write none) the call's input.
        var inputs: [String: (added: Int, removed: Int)] = [:]
        var outcomes: [String: (at: Date?, failed: Bool)] = [:]
        var diffs: [String: (added: Int, removed: Int)] = [:]
        var seenLines = Set<String>()
        for (file, events) in files.enumerated() {
            let subagent = file >= mains
            var skip = false
            for e in events {
                if case .line(let uuid) = e {
                    skip = !seenLines.insert(uuid).inserted
                    continue
                }
                if skip { continue }
                switch e {
                case .line: break
                case .saw(let at): b.saw(at)
                case .cwd(let c): if !subagent { b.noteCwd(c) }
                case .reply(let id, var r):
                    r.subagent = subagent
                    b.reply(id: id, r, file: file)
                case .apiError(var err, let id):
                    err.subagent = subagent
                    b.apiError(err, id: id)
                case .toolUse(let id, let name, let at, let lines):
                    b.toolUse(id: id, name: name, at: at, subagent: subagent)
                    if let lines, inputs[id] == nil { inputs[id] = lines }
                case .toolResult(let id, let at, let failed):
                    if !subagent { b.toolResult(id: id, at: at) }
                    if outcomes[id] == nil { outcomes[id] = (at, failed) }
                case .patch(let added, let removed, _, let ids):
                    for id in ids where diffs[id] == nil { diffs[id] = (added, removed) }
                case .prompt(let at): if !subagent { b.prompt(at: at) }
                case .compaction(let c): if !subagent { b.compaction(c) }
                case .turn(let end, let seconds): if !subagent { b.turn(end: end, seconds: seconds) }
                case .costState(let c): if !subagent { b.costState(c, file: file) }
                }
            }
        }
        for id in Set(inputs.keys).union(diffs.keys).sorted() {
            guard let o = outcomes[id], !o.failed, let lines = diffs[id] ?? inputs[id] else { continue }
            b.editedLines(added: lines.added, removed: lines.removed, at: o.at)
        }
        return b.build()
    }

    static let pieceSize = 4 << 20

    static func pieces(size: Int, of piece: Int = pieceSize) -> Int { max(1, (size + piece - 1) / piece) }

    /// Piece `k` of a file: the lines that start in bytes `k * size ..< (k + 1) * size`, or to the end
    /// for the `last` (the file may have grown since its size was read).
    static func events(in data: Data, piece k: Int, last: Bool, subagent: Bool, size: Int = pieceSize) -> [Event] {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Event] in
            guard let base = raw.baseAddress else { return [] }
            let n = raw.count
            func lineStart(_ k: Int) -> Int {
                let p = k * size
                if p <= 0 { return 0 }
                if p >= n { return n }
                return memchr(base + p - 1, 0x0A, n - p + 1).map { base.distance(to: UnsafeRawPointer($0)) + 1 } ?? n
            }
            var out: [Event] = []
            let decoder = JSONDecoder()
            var start = lineStart(k)
            let stop = last ? n : lineStart(k + 1)
            if stop > start { madvise(UnsafeMutableRawPointer(mutating: base + start), stop - start, MADV_WILLNEED) }
            var cwd: String?
            func note(_ c: String?) {
                guard let c, c != cwd else { return }
                cwd = c
                out.append(.cwd(c))
            }
            while start < stop {
                let end = memchr(base + start, 0x0A, stop - start).map { base.distance(to: UnsafeRawPointer($0)) } ?? stop
                let len = end - start
                if len > 2, wanted(base + start, len, subagent: subagent) {
                    // Tool results are half of all bytes, but the decoder only materialises the keys
                    // asked for; a hand-written scanner that skipped them was slower (docs/usage.md).
                    let bytes = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start), count: len, deallocator: .none)
                    if let l = try? decoder.decode(UsageLine.self, from: bytes), !l.forked {
                        if !subagent, let uuid = l.uuid { out.append(.line(uuid)) }
                        note(l.cwd)
                        events(of: l, subagent: subagent, into: &out)
                    }
                }
                start = end + 1
            }
            return out
        }
    }

    private static let needles = [#""type":"assistant""#, #""type":"user""#, #""subtype":"compact_boundary""#,
                                  #""subtype":"turn_duration""#, #""type":"cost-state""#].map { Array($0.utf8) }
    private static let patchNeedles = [#""structuredPatch""#, #""type":"create""#].map { Array($0.utf8) }
    private static let resultNeedle = Array(#""tool_use_id""#.utf8)

    /// Whether a line may be a record that counts, from its bytes: a quote inside a JSON string is
    /// escaped, so these match keys only. They can match a nested object too (an Agent call's result
    /// embeds messages), so the decoded top-level `type` decides. In a subagent only replies count,
    /// and tool results (they say whether an edit succeeded).
    private static func wanted(_ line: UnsafeRawPointer, _ len: Int, subagent: Bool) -> Bool {
        func has(_ needle: [UInt8]) -> Bool { needle.withUnsafeBytes { memmem(line, len, $0.baseAddress, $0.count) } != nil }
        if !subagent { return needles.contains(where: has) }
        return has(needles[0]) || (has(needles[1]) && (has(resultNeedle) || patchNeedles.contains(where: has)))
    }

    private static func events(of l: UsageLine, subagent: Bool, into out: inout [Event]) {
        let at = l.timestamp.flatMap(Timestamp.plausible)
        switch l.type {
        case "assistant":
            guard let m = l.message else { out.append(.saw(at)); return }
            if l.isApiErrorMessage {
                out.append(.apiError(.init(at: at ?? .distantPast, kind: l.error ?? "unknown", status: l.apiErrorStatus,
                                           message: m.firstText.map { clip($0) }), id: m.id ?? l.requestId ?? l.uuid))
                return
            }
            for t in m.tools { out.append(.toolUse(id: t.id, name: t.name, at: at, lines: t.lines)) }
            guard let model = m.model, model != "<synthetic>", let id = m.id ?? l.requestId, let u = m.usage else {
                out.append(.saw(at)); return
            }
            out.append(.reply(id: id, .init(at: at, model: model, tokens: u.tokens, fast: u.speed == "fast", usOnly: u.geo == "us",
                                            webSearches: u.webSearches, subagent: subagent)))
        case "user":
            out.append(.saw(at))
            let results = l.message?.results ?? []
            for r in results { out.append(.toolResult(id: r.id, at: at, failed: r.failed || l.textResult)) }
            if let p = l.toolUseResult {
                out.append(.patch(added: p.added, removed: p.removed, at: at, ids: results.filter { !$0.failed }.map(\.id)))
            }
            if !l.isMeta, !l.isCompactSummary, l.message?.isPrompt == true { out.append(.prompt(at)) }
        case "system":
            if l.subtype == "compact_boundary", let at {
                let c = l.compactMetadata
                out.append(.compaction(.init(at: at, trigger: c?.trigger, preTokens: c?.preTokens, postTokens: c?.postTokens,
                                             droppedTokens: c?.cumulativeDroppedTokens, seconds: c?.seconds)))
            } else if l.subtype == "turn_duration", let at, let seconds = l.seconds {
                out.append(.turn(end: at, seconds: seconds))
            }
        case "cost-state":
            guard let usd = l.totalCostUSD else { return }
            let usage = l.modelUsage ?? [:]
            out.append(.costState(.init(usd: usd, output: usage.values.reduce(0) { $0.addingSaturating($1.output) },
                                        cacheRead: usage.values.reduce(0) { $0.addingSaturating($1.cacheRead) },
                                        linesAdded: l.totalLinesAdded, linesRemoved: l.totalLinesRemoved,
                                        unknownModelCost: l.hasUnknownModelCost)))
        default:
            break
        }
    }

    static func clip(_ s: String, _ limit: Int = 160) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    /// Lines a new text has over an old one, by whole lines, without a real diff: what is left once the
    /// lines they share at the start and the end are set aside. Only for calls with no result diff.
    static func lineChange(old: String, new: String) -> (added: Int, removed: Int) {
        let a = old.split(separator: "\n", omittingEmptySubsequences: false)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false)
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        return (b.count - head - tail, a.count - head - tail)
    }
}

extension Int {
    /// `+` that stops at `Int.max` (or `Int.min`) instead of trapping: no input may crash the helper.
    func addingSaturating(_ other: Int) -> Int {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : sum
    }

    /// A finite Double as an Int, clamped to what an Int holds; 0 for NaN.
    init(saturating d: Double) {
        if d.isNaN { self = 0 } else if d >= 9.2e18 { self = .max } else if d <= -9.2e18 { self = .min } else { self = Int(d) }
    }
}

/// ISO 8601 timestamps as Claude Code writes them ("2026-11-02T10:00:00.000Z"), parsed by hand: a
/// formatter per line cost more than the rest of the read. Anything else goes to ISO8601DateFormatter.
enum Timestamp {
    /// Dates a transcript can hold: from 2020 to 2100. Others (year 1 or 9999 from a corrupt line) are
    /// treated as missing, so no interval built on them spans centuries.
    static let earliest = Date(timeIntervalSince1970: 1_577_836_800)    // 2020-01-01
    static let latest = Date(timeIntervalSince1970: 4_102_444_800)      // 2100-01-01

    static func plausible(_ s: String) -> Date? {
        parse(s).flatMap { $0 >= earliest && $0 < latest ? $0 : nil }
    }

    static func parse(_ s: String) -> Date? {
        var u = Array(s.utf8)
        return u.withUnsafeMutableBufferPointer { p -> Date? in
            func num(_ i: Int, _ n: Int) -> Int? {
                guard i + n <= p.count else { return nil }
                var v = 0
                for k in i..<(i + n) {
                    let c = Int(p[k]) - 48
                    guard (0...9).contains(c) else { return nil }
                    v = v * 10 + c
                }
                return v
            }
            guard p.count >= 20, p[4] == 45, p[7] == 45, p[10] == 84, p[13] == 58, p[16] == 58,
                  let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2),
                  let sec = num(17, 2) else { return slow(s) }
            var i = 19, frac = 0.0
            if p[i] == 46 {
                var scale = 0.1
                i += 1
                while i < p.count, (48...57).contains(p[i]) { frac += Double(p[i] - 48) * scale; scale /= 10; i += 1 }
            }
            guard i == p.count - 1, p[i] == 90, (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, sec < 61
            else { return slow(s) }     // "Z"
            // Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's days_from_civil).
            let yy = mo <= 2 ? y - 1 : y
            let era = (yy >= 0 ? yy : yy - 399) / 400
            let yoe = yy - era * 400
            let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let days = era * 146_097 + doe - 719_468
            return Date(timeIntervalSince1970: Double(days * 86_400 + h * 3600 + mi * 60 + sec) + frac)
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let lock = NSLock()

    private static func slow(_ s: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        defer { iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
        return iso.date(from: s)
    }
}

/// One transcript line, decoded leniently: a missing field, or one of an unexpected type, is nil.
/// Numbers may also come as strings, and `modelUsage` as a JSON or Python-style dictionary string. A
/// number that is not finite, negative or out of range (`limits`) counts as missing: nothing a line
/// holds may trap.
struct UsageLine: Decodable {
    enum Limits {
        /// Tokens of one kind in one reply, a line count, a compaction's tokens.
        static let count = 1e12
        /// One turn or compaction: longer is a corrupt line, not work.
        static let seconds = 48.0 * 3600
        static let usd = 1e7
    }

    var type: String?
    var subtype: String?
    var timestamp: String?
    var cwd: String?
    var uuid: String?
    var requestId: String?
    var forked = false
    var isMeta = false
    var isCompactSummary = false
    var isApiErrorMessage = false
    var error: String?
    var apiErrorStatus: Int?
    var message: Message?
    var toolUseResult: Patch?
    /// `toolUseResult` is only text: an Edit or Write that failed or was rejected.
    var textResult = false
    /// `durationMs` of a turn, in seconds.
    var seconds: Double?
    var compactMetadata: CompactMetadata?
    var totalCostUSD: Double?
    var totalLinesAdded: Int?
    var totalLinesRemoved: Int?
    var hasUnknownModelCost = false
    var modelUsage: [String: ModelTokens]?

    private enum Keys: String, CodingKey {
        case type, subtype, timestamp, cwd, uuid, requestId, forkedFrom, isMeta, isCompactSummary, isApiErrorMessage
        case error, apiErrorStatus, message, toolUseResult, durationMs, compactMetadata
        case totalCostUSD, totalLinesAdded, totalLinesRemoved, hasUnknownModelCost, modelUsage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        type = c.lenientString(.type)
        timestamp = c.lenientString(.timestamp)
        uuid = c.lenientString(.uuid)
        forked = c.contains(.forkedFrom) && (try? c.decodeNil(forKey: .forkedFrom)) == false
        switch type {
        case "assistant":
            cwd = c.lenientString(.cwd)
            requestId = c.lenientString(.requestId)
            isApiErrorMessage = c.lenientBool(.isApiErrorMessage)
            if isApiErrorMessage {
                error = c.lenientString(.error)
                apiErrorStatus = c.lenientCount(.apiErrorStatus, limit: 999)
            }
            message = try? c.decodeIfPresent(Message.self, forKey: .message)
        case "user":
            cwd = c.lenientString(.cwd)
            isMeta = c.lenientBool(.isMeta)
            isCompactSummary = c.lenientBool(.isCompactSummary)
            message = try? c.decodeIfPresent(Message.self, forKey: .message)
            toolUseResult = try? c.decodeIfPresent(Patch.self, forKey: .toolUseResult)
            textResult = c.lenientString(.toolUseResult) != nil
        case "system":
            subtype = c.lenientString(.subtype)
            seconds = c.lenientNumber(.durationMs, limit: Limits.seconds * 1000).map { $0 / 1000 }
            compactMetadata = try? c.decodeIfPresent(CompactMetadata.self, forKey: .compactMetadata)
        case "cost-state":
            totalCostUSD = c.lenientNumber(.totalCostUSD, limit: Limits.usd)
            totalLinesAdded = c.lenientCount(.totalLinesAdded)
            totalLinesRemoved = c.lenientCount(.totalLinesRemoved)
            hasUnknownModelCost = c.lenientBool(.hasUnknownModelCost)
            if let dict = try? c.decodeIfPresent([String: ModelTokens].self, forKey: .modelUsage) {
                modelUsage = dict
            } else if let text = c.lenientString(.modelUsage) {
                modelUsage = ModelTokens.parse(text)
            }
        default:
            break
        }
    }

    struct Message: Decodable {
        var id: String?
        var model: String?
        var usage: Usage?
        var tools: [Tool] = []
        /// tool_result blocks: the call each answers, and whether it says `is_error`.
        var results: [(id: String, failed: Bool)] = []
        var firstText: String?
        /// A prompt: plain text, or text blocks with no tool result among them.
        var isPrompt = false

        private enum Keys: String, CodingKey { case id, model, usage, content }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = c.lenientString(.id)
            model = c.lenientString(.model)
            usage = try? c.decodeIfPresent(Usage.self, forKey: .usage)
            if let text = try? c.decodeIfPresent(String.self, forKey: .content) {
                firstText = text
                isPrompt = !text.allSatisfy(\.isWhitespace)
            } else if let blocks = try? c.decodeIfPresent([Lenient<ContentBlock>].self, forKey: .content) {
                var hasText = false
                for case let b? in blocks.map(\.value) {
                    switch b.type {
                    case "tool_use": if let id = b.id { tools.append(Tool(id: id, name: b.name ?? "Tool", lines: b.lines)) }
                    case "tool_result": if let id = b.toolUseID { results.append((id, b.isError)) }
                    case "text":
                        if firstText == nil { firstText = b.text }
                        if b.text.map({ !$0.allSatisfy(\.isWhitespace) }) == true { hasText = true }
                    default: break
                    }
                }
                isPrompt = hasText && results.isEmpty
            }
        }
    }

    struct Tool {
        var id: String
        var name: String
        var lines: (added: Int, removed: Int)?
    }

    /// A content block; tool output is never materialised.
    struct ContentBlock: Decodable {
        var type: String?
        var id: String?
        var name: String?
        var text: String?
        var toolUseID: String?
        var isError = false
        var lines: (added: Int, removed: Int)?

        private enum Keys: String, CodingKey { case type, id, name, text, input, tool_use_id, is_error }
        private enum Input: String, CodingKey { case old_string, new_string, content, replace_all }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            type = c.lenientString(.type)
            switch type {
            case "text": text = c.lenientString(.text)
            case "tool_result":
                toolUseID = c.lenientString(.tool_use_id)
                isError = c.lenientBool(.is_error)
            case "tool_use":
                id = c.lenientString(.id)
                name = c.lenientString(.name)
                if name == "Edit" || name == "Write", let i = try? c.nestedContainer(keyedBy: Input.self, forKey: .input) {
                    if name == "Write" {
                        lines = (i.lenientString(.content).map { $0.split(separator: "\n", omittingEmptySubsequences: false).count } ?? 0, 0)
                    } else if let old = i.lenientString(.old_string), let new = i.lenientString(.new_string) {
                        lines = UsageReader.lineChange(old: old, new: new)
                    }
                }
            default: break
            }
        }
    }

    struct Usage: Decodable {
        var tokens = SessionUsage.Tokens()
        var speed: String?
        var geo: String?
        var webSearches = 0

        private enum Keys: String, CodingKey {
            case input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, cache_creation
            case speed, inference_geo, server_tool_use
        }
        private enum Creation: String, CodingKey { case ephemeral_1h_input_tokens }
        private enum Server: String, CodingKey { case web_search_requests }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            func int(_ k: Keys) -> Int { c.lenientCount(k) ?? 0 }
            tokens.input = int(.input_tokens)
            tokens.output = int(.output_tokens)
            tokens.cacheRead = int(.cache_read_input_tokens)
            tokens.cacheWrite = int(.cache_creation_input_tokens)
            if let cc = try? c.nestedContainer(keyedBy: Creation.self, forKey: .cache_creation) {
                tokens.cacheWrite1h = min(tokens.cacheWrite, cc.lenientCount(.ephemeral_1h_input_tokens) ?? 0)
            }
            speed = c.lenientString(.speed)
            geo = c.lenientString(.inference_geo)
            if let s = try? c.nestedContainer(keyedBy: Server.self, forKey: .server_tool_use) {
                webSearches = s.lenientCount(.web_search_requests, limit: 1e6) ?? 0
            }
        }
    }

    /// `toolUseResult` of an Edit or Write: a new file's content, or hunks whose lines start with "+"
    /// or "-" (none when the file was written unchanged).
    struct Patch: Decodable {
        var added = 0
        var removed = 0

        private enum Keys: String, CodingKey { case type, structuredPatch, content }
        private struct Hunk: Decodable { var lines: [String]? }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            if c.lenientString(.type) == "create", let text = c.lenientString(.content) {
                // As Claude Code counts it: a final newline starts one more (empty) line.
                added = text.split(separator: "\n", omittingEmptySubsequences: false).count
            } else if let hunks = try? c.decodeIfPresent([Lenient<Hunk>].self, forKey: .structuredPatch) {
                // The first byte, not the first Character: "-" then a combining mark is one Character
                // in Swift, but a removed line to Claude Code (seen in a real diff).
                for line in hunks.compactMap(\.value).flatMap({ $0.lines ?? [] }) {
                    switch line.utf8.first {
                    case UInt8(ascii: "+"): added += 1
                    case UInt8(ascii: "-"): removed += 1
                    default: break
                    }
                }
            } else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not an edit"))
            }
        }
    }

    struct CompactMetadata: Decodable {
        var trigger: String?
        var preTokens: Int?
        var postTokens: Int?
        var cumulativeDroppedTokens: Int?
        var seconds: Double?

        private enum Keys: String, CodingKey { case trigger, preTokens, postTokens, cumulativeDroppedTokens, durationMs }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            trigger = c.lenientString(.trigger)
            preTokens = c.lenientCount(.preTokens)
            postTokens = c.lenientCount(.postTokens)
            cumulativeDroppedTokens = c.lenientCount(.cumulativeDroppedTokens)
            seconds = c.lenientNumber(.durationMs, limit: Limits.seconds * 1000).map { $0 / 1000 }
        }
    }

    /// One model's entry in a `cost-state` record.
    struct ModelTokens: Decodable {
        var output = 0
        var cacheRead = 0

        private enum Keys: String, CodingKey { case outputTokens, cacheReadInputTokens }

        init(output: Int, cacheRead: Int) { self.output = output; self.cacheRead = cacheRead }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            output = c.lenientCount(.outputTokens) ?? 0
            cacheRead = c.lenientCount(.cacheReadInputTokens) ?? 0
        }

        /// `modelUsage` written as a string: JSON, or a Python-style dict (single quotes, True/None).
        static func parse(_ text: String) -> [String: ModelTokens]? {
            func decode(_ s: String) -> [String: ModelTokens]? {
                try? JSONDecoder().decode([String: ModelTokens].self, from: Data(s.utf8))
            }
            if let d = decode(text) { return d }
            let py = text.replacingOccurrences(of: "'", with: "\"").replacingOccurrences(of: "True", with: "true")
                .replacingOccurrences(of: "False", with: "false").replacingOccurrences(of: "None", with: "null")
            return decode(py)
        }
    }
}

extension KeyedDecodingContainer {
    func lenientString(_ key: Key) -> String? { try? decodeIfPresent(String.self, forKey: key) }

    func lenientBool(_ key: Key) -> Bool {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        return lenientString(key).map { $0 == "true" || $0 == "True" } ?? false
    }

    /// A number in `0...limit`, or a string holding one; anything else (not finite, negative, too big,
    /// "inf", "nan") is missing.
    func lenientNumber(_ key: Key, limit: Double = UsageLine.Limits.count) -> Double? {
        let d = (try? decodeIfPresent(Double.self, forKey: key))
            ?? lenientString(key).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard let d, d.isFinite, d >= 0, d <= limit else { return nil }
        return d
    }

    /// `lenientNumber` as a whole number.
    func lenientCount(_ key: Key, limit: Double = UsageLine.Limits.count) -> Int? {
        lenientNumber(key, limit: limit).map { Int($0) }
    }
}
