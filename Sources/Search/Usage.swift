import Foundation

/// What one Claude Code conversation used and cost, read from its transcript and its subagents'
/// (`UsageReader`) and kept between launches by `UsageCache`. The contract between the reader and the
/// screens that show it, Search's detail pane and list and the Usage window: change it only by adding
/// fields. Guide: docs/usage.md.
///
/// "Main thread" is the conversation itself; subagents are its Agent calls and workflow agents, each in
/// its own transcript. Token, cost, tool and error figures include subagents; context, compactions,
/// turns and tool time are the main thread's.
struct SessionUsage: Codable, Equatable {
    /// Where a figure comes from: Claude Code's own record, or worked out here (the screens say "est.").
    enum Source: String, Codable { case claudeCode, estimate }

    let sessionID: String
    /// Claude Code's folder name under ~/.claude/projects.
    var projectDir: String
    /// The working folder recorded in the transcript that encodes to `projectDir`, else the first one.
    /// Search's `Session.cwd` is the better name for display: it also finds folders on disk.
    var folder: String?
    var firstActive: Date?
    /// The newest timestamp in the transcript or its subagents'.
    var lastActive: Date?
    /// Models that replied, most output first. Never `<synthetic>` (Claude Code's API error lines).
    var models: [String] = []
    /// API calls answered, subagents included, each counted once.
    var replies = 0

    var context = Context()
    /// Everything, subagents included.
    var tokens = Tokens()
    var byModel: [String: ModelUsage] = [:]
    var cost = Cost()
    var turns = Turns()
    /// Main thread: wall-clock time while at least one tool call was running (from each `tool_use` to its
    /// `tool_result`), so parallel calls are not counted twice; never a call that waits for you
    /// (`UsageBuilder.waitingTools`), and only within the turns' working time, so never more than it.
    var toolSeconds: Double = 0
    /// Tool calls by tool name, subagents included, each `tool_use` block once.
    var tools: [String: Int] = [:]
    var subagents = Subagents()
    var apiErrors: [APIError] = []
    /// Per local calendar day, oldest first: what the Usage window's date filters and "when Claude works" read.
    var days: [Day] = []
    var lines = Lines()

    struct Tokens: Codable, Equatable {
        /// Written by Claude: text, tool calls and thinking.
        var output = 0
        /// Read from the prompt cache.
        var cacheRead = 0
        /// Written to the prompt cache, `cacheWrite1h` of it with the one-hour lifetime.
        var cacheWrite = 0
        var cacheWrite1h = 0
        /// Fresh input: neither read from the cache nor written to it.
        var input = 0

        var cacheWrite5m: Int { cacheWrite - cacheWrite1h }
        /// What the model read: fresh input plus the cache, read and written.
        var prompt: Int { input.addingSaturating(cacheRead).addingSaturating(cacheWrite) }
        var total: Int { prompt.addingSaturating(output) }

        /// Sums saturate at `Int.max` rather than trap, whatever a transcript holds.
        mutating func add(_ o: Tokens) {
            output = output.addingSaturating(o.output); cacheRead = cacheRead.addingSaturating(o.cacheRead)
            cacheWrite = cacheWrite.addingSaturating(o.cacheWrite); cacheWrite1h = cacheWrite1h.addingSaturating(o.cacheWrite1h)
            input = input.addingSaturating(o.input)
        }
        static func + (a: Tokens, b: Tokens) -> Tokens { var t = a; t.add(b); return t }
        static func - (a: Tokens, b: Tokens) -> Tokens {
            Tokens(output: a.output.addingSaturating(-b.output), cacheRead: a.cacheRead.addingSaturating(-b.cacheRead),
                   cacheWrite: a.cacheWrite.addingSaturating(-b.cacheWrite), cacheWrite1h: a.cacheWrite1h.addingSaturating(-b.cacheWrite1h),
                   input: a.input.addingSaturating(-b.input))
        }
    }

    struct ModelUsage: Codable, Equatable {
        var tokens = Tokens()
        var replies = 0
        /// At API prices from `Pricing`, always an estimate; nil when no reply could be priced.
        var estimatedUSD: Double?
        /// Replies `Pricing` has no price for (an unknown model, or a prompt over a rate card's limit).
        var unpricedReplies = 0
    }

    struct Context: Codable, Equatable {
        /// Tokens in the main thread's context now: after its last reply, or the compaction after it;
        /// nil when that compaction did not say how much it kept (or there were no replies).
        var now: Int?
        /// The model of the last main-thread reply, the window `now` is measured against.
        var model: String?
        /// After each main-thread reply, oldest first (input + cache read + cache write of that reply).
        var replies: [Point] = []
        var compactions: [Compaction] = []

        struct Point: Codable, Equatable {
            var at: Date
            var tokens: Int
        }
    }

    struct Compaction: Codable, Equatable {
        var at: Date
        /// "auto" or "manual", as Claude Code writes it.
        var trigger: String?
        var preTokens: Int?
        var postTokens: Int?
        /// Claude Code's `cumulativeDroppedTokens`: dropped by every compaction so far.
        var droppedTokens: Int?
        var seconds: Double?
    }

    struct Cost: Codable, Equatable {
        /// US dollars at API prices: Claude Code's own figure when it covers this transcript, else
        /// `estimateUSD`. On a subscription plan this is not the bill. nil when nothing could be priced.
        var usd: Double?
        var source: Source = .estimate
        /// From `Pricing`, over every reply, subagents included (the sum of `byModel`'s estimates). Claude
        /// Code's figure also counts calls that never reach a transcript (its own Haiku side requests).
        var estimateUSD: Double?
        /// Models with replies the estimate leaves out: the cost is unknown for that part.
        var unpriced: [String] = []
        /// Claude Code's last `cost-state` figure, also when not used: written after a later reply (stale),
        /// or by a resumed process whose counter started again from zero.
        var claudeCodeUSD: Double?
    }

    struct Turns: Codable, Equatable {
        var count = 0
        /// Claude's working time across turns.
        var seconds: Double = 0
        var longestSeconds: Double = 0
        /// `.claudeCode` when every turn has Claude Code's `turn_duration`; `.estimate` when any turn
        /// was worked out from its prompt and last reply (or there were no turns).
        var source: Source = .claudeCode
    }

    struct Subagents: Codable, Equatable {
        /// Subagent transcripts: Agent calls and workflow agents.
        var count = 0
        /// Already part of the session's `tokens`.
        var tokens = Tokens()
        var estimatedUSD: Double?
    }

    struct APIError: Codable, Equatable {
        var at: Date
        /// Claude Code's `error`: `rate_limit`, `server_error`, `invalid_request`, …; "unknown" when absent.
        var kind: String
        /// The HTTP status, when Claude Code recorded it.
        var status: Int?
        /// The first line of Claude Code's "API Error: …" text, clipped.
        var message: String?
        var subagent = false
    }

    struct Day: Codable, Equatable {
        /// The local calendar day, "yyyy-MM-dd": sorts and compares as text.
        var date: String
        /// 1 = Sunday … 7 = Saturday, as `Calendar` numbers them.
        var weekday: Int
        var tokens = Tokens()
        var estimatedUSD: Double?
        var replies = 0
        /// Claude's working time in each local hour, 0…23 (seconds).
        var workSeconds: [Double] = Array(repeating: 0, count: 24)
        /// Lines changed by Edit and Write calls whose results came that day, always counted here;
        /// `lines(of:)` scales them to Claude Code's total when that is the session's figure.
        var linesAdded = 0
        var linesRemoved = 0
    }

    struct Lines: Codable, Equatable {
        var added = 0
        var removed = 0
        /// Claude Code's own count (subagents included), or counted from Edit and Write calls.
        var source: Source = .estimate
    }
}

// MARK: Derived figures for the screens

extension SessionUsage {
    /// Tokens the main thread used, without its subagents'.
    var mainTokens: Tokens { tokens - subagents.tokens }

    /// The window for `context.model` (`ContextWindows`); nil for a model not in the table.
    var contextWindow: Int? { context.model.flatMap(ContextWindows.size(for:)) }

    /// How full the context is now, 0…1 (a little over after an overflow); nil without a known window.
    var contextFraction: Double? {
        guard let now = context.now, let window = contextWindow, window > 0 else { return nil }
        return Double(now) / Double(window)
    }

    /// At 80% of the window or more; with no known window, at `ContextWindows.nearLimitWithoutWindow` tokens.
    var isNearContextLimit: Bool {
        guard let now = context.now else { return false }
        if let f = contextFraction { return f >= 0.8 }
        return now >= ContextWindows.nearLimitWithoutWindow
    }

    /// Dollars per hour of Claude's working time; nil without a cost or without any working time.
    var costPerHour: Double? {
        guard let usd = cost.usd, turns.seconds >= 60 else { return nil }
        return usd / (turns.seconds / 3600)
    }

    /// One day's share of `cost.usd`: its estimate, scaled to Claude Code's figure when that is the
    /// session's cost, so a session's days add up to its total.
    func cost(of day: Day) -> Double? {
        guard let est = day.estimatedUSD else { return nil }
        guard cost.source == .claudeCode, let usd = cost.usd, let total = cost.estimateUSD, total > 0 else { return est }
        return est * usd / total
    }

    /// One day's share of `lines`: its own count, scaled to Claude Code's total when that is the
    /// session's figure, so a session's days add up to its total (give or take rounding).
    func lines(of day: Day) -> (added: Int, removed: Int) {
        guard lines.source == .claudeCode else { return (day.linesAdded, day.linesRemoved) }
        // Claude Code's total, split as the edits counted here fell; with none counted on any day, as
        // Claude's working time fell (else its replies, else evenly).
        func share(_ total: Int, _ own: KeyPath<Day, Int>) -> Int {
            let weight: (Day) -> Double
            if days.contains(where: { $0[keyPath: own] > 0 }) { weight = { Double($0[keyPath: own]) } }
            else if days.contains(where: { $0.workSeconds.reduce(0, +) > 0 }) { weight = { $0.workSeconds.reduce(0, +) } }
            else if days.contains(where: { $0.replies > 0 }) { weight = { Double($0.replies) } }
            else { weight = { _ in 1 } }
            let sum = days.reduce(0.0) { $0 + weight($1) }
            return sum > 0 ? Int(saturating: (Double(total) * weight(day) / sum).rounded()) : 0
        }
        return (share(lines.added, \.linesAdded), share(lines.removed, \.linesRemoved))
    }

    /// Claude's working seconds by weekday (rows 0…6 = Sunday…Saturday) and local hour (columns 0…23),
    /// over the days on or after `from` ("yyyy-MM-dd"; nil for all).
    static func activity<S: Sequence>(_ sessions: S, from: String? = nil) -> [[Double]] where S.Element == SessionUsage {
        var grid = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        for s in sessions {
            for d in s.days where from.map({ d.date >= $0 }) ?? true && (1...7).contains(d.weekday) {
                for (h, secs) in d.workSeconds.prefix(24).enumerated() { grid[d.weekday - 1][h] += secs }
            }
        }
        return grid
    }
}

/// Every session's usage, keyed by session ID: what Search's panel and the Usage window read. Reads
/// only transcripts whose files changed since the last call or the last run (`UsageCache`), in
/// parallel, biggest first. Under `--demo` it is `Demo.usage`, and nothing of yours is read.
///
/// A transcript that is a link is read through its target (stamped by the target's size and time), and
/// not again when the target is listed too. A session ID filed as two real transcripts (copies that may
/// have diverged) gets figures from all of them, each reply and line once; `byTranscript` keeps each
/// file's own.
final class UsageStore: @unchecked Sendable {
    let root: URL
    private(set) var cache: UsageCache?
    private var entries: [String: UsageCache.Entry]?
    private var entriesZone: String?
    /// Transcripts read by the last `load()`: the rest came from the cache.
    private(set) var lastRead = 0
    private var byPath: [String: SessionUsage] = [:]
    private var byID: [String: SessionUsage] = [:]

    /// One transcript's figures from the last `load()` (`Session.file`): by its path, so the two copies
    /// of a session ID filed under two project folders (8 of 549 here) keep their own; else by ID.
    func usage(forTranscript file: URL) -> SessionUsage? {
        byPath[file.path] ?? byID[file.deletingPathExtension().lastPathComponent]
    }

    /// Every transcript's figures by its path, as of the last `load()`; read on the thread that called it.
    var byTranscript: [String: SessionUsage] { byPath }

    init(root: URL = URL(fileURLWithPath: Paths.home).appendingPathComponent(".claude/projects", isDirectory: true),
         cache: UsageCache? = UsageCache()) {
        self.root = root
        self.cache = cache
    }

    /// A transcript as listed, and the file behind it.
    private struct Transcript {
        let listed: URL
        let real: URL
        let project: String
        let id: String
        let subagents: [URL]
        let stamps: [UsageCache.Stamp]
        var linked: Bool { listed.path != real.path }
    }

    /// What one reading folds: files (mains first) and the cache key it is stored under.
    private struct Job {
        let key: String
        let id: String
        let project: String
        let files: [URL]
        let mains: Int
        let stamps: [UsageCache.Stamp]
        var bytes: Int { stamps.reduce(0) { $0.addingSaturating($1.size) } }
    }

    /// Not reentrant: callers serialise, as with `SessionStore.load`.
    func load() -> [String: SessionUsage] {
        if Demo.active { byID = Demo.usage; return byID }
        // Days and hours are local: a new time zone (travel) starts the figures afresh.
        NSTimeZone.resetSystemTimeZone()
        let zone = TimeZone.current
        if entriesZone != zone.identifier { entries = nil }
        if cache?.timeZone.identifier != zone.identifier { cache?.timeZone = zone }

        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        func list(_ dir: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        }
        func stamp(_ url: URL) -> UsageCache.Stamp {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return .init(path: url.path, size: v?.fileSize ?? 0, mtime: v?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        /// The file behind a transcript, by its real path (so "/var/…" and "/private/var/…" are one file).
        /// A link's target is read with lstat only, and nil when it leads into a privacy-protected
        /// folder (even a stat there raises a prompt) or nowhere.
        func real(_ url: URL) -> URL? {
            var path = url.path
            for _ in 0..<8 {
                var st = stat()
                guard lstat(path, &st) == 0 else { return nil }
                if st.st_mode & S_IFMT != S_IFLNK {
                    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
                    return URL(fileURLWithPath: realpath(path, &buf).map { String(cString: $0) } ?? path)
                }
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: path) else { return nil }
                path = Paths.normalize(dest.hasPrefix("/") ? dest : (path as NSString).deletingLastPathComponent + "/" + dest)
                if Paths.isPrivacyProtected(path) { return nil }
            }
            return nil
        }

        var transcripts: [Transcript] = []
        for dir in list(root) where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            for file in list(dir) where file.pathExtension == "jsonl" {
                guard let real = real(file) else { continue }
                let subagents = UsageReader.subagentFiles(for: real, list: list)
                transcripts.append(.init(listed: file, real: real, project: dir.lastPathComponent,
                                         id: file.deletingPathExtension().lastPathComponent, subagents: subagents,
                                         stamps: ([real] + subagents).map(stamp)))
            }
        }
        // One reading per real file (a listed one before a link to it), and one more per session ID
        // filed as several real files, oldest first.
        var canonical: [String: Transcript] = [:]
        for t in transcripts.sorted(by: { ($0.linked ? 1 : 0, $0.listed.path) < ($1.linked ? 1 : 0, $1.listed.path) })
        where canonical[t.real.path] == nil {
            canonical[t.real.path] = t
        }
        var jobs: [Job] = []
        for t in canonical.values {
            jobs.append(.init(key: t.real.path, id: t.id, project: t.project, files: [t.real] + t.subagents, mains: 1, stamps: t.stamps))
        }
        for (id, copies) in Dictionary(grouping: canonical.values, by: \.id) where copies.count > 1 {
            let byAge = copies.sorted { ($0.stamps[0].mtime, $0.real.path) < ($1.stamps[0].mtime, $1.real.path) }
            jobs.append(.init(key: "merged " + id, id: id, project: byAge.last!.project,
                              files: byAge.map(\.real) + byAge.flatMap(\.subagents), mains: byAge.count,
                              stamps: byAge.map { $0.stamps[0] } + byAge.flatMap { $0.stamps.dropFirst() }))
        }

        let old = entries ?? cache?.load() ?? [:]
        var next: [String: UsageCache.Entry] = [:]
        var stale: [Job] = []
        for j in jobs {
            if let e = old[j.key], e.stamps == j.stamps { next[j.key] = e } else { stale.append(j) }
        }
        // In batches of about `batchBytes` of transcript, biggest sessions first (a session's own
        // reading and its merged one together, so its files are parsed once), so the parsed events of
        // only one batch are held at a time.
        let groups = Dictionary(grouping: stale, by: \.id).values.sorted {
            ($0.reduce(0) { $0 + $1.bytes }, $0[0].id) > ($1.reduce(0) { $0 + $1.bytes }, $1[0].id)
        }
        var batch: [Job] = [], bytes = 0
        func flush() {
            for (j, u) in zip(batch, Self.read(batch)) { next[j.key] = .init(stamps: j.stamps, usage: u) }
            batch = []; bytes = 0
        }
        for g in groups {
            batch += g
            bytes = bytes.addingSaturating(g.reduce(0) { $0.addingSaturating($1.bytes) })
            if bytes >= Self.batchBytes { flush() }
        }
        flush()
        lastRead = stale.filter { $0.mains == 1 }.count
        if !stale.isEmpty || next.count != old.count { cache?.save(next) }
        entries = next
        entriesZone = zone.identifier

        var paths: [String: SessionUsage] = [:]
        var ids: [String: SessionUsage] = [:]
        for t in transcripts {
            guard let u = next[t.real.path]?.usage else { continue }
            paths[t.listed.path] = u
        }
        for t in canonical.values {
            ids[t.id] = next["merged " + t.id]?.usage ?? next[t.real.path]?.usage
        }
        byPath = paths
        byID = ids
        return ids
    }

    static let batchBytes = 384 << 20

    /// Every piece of every file in `jobs` at once (one session can hold hundreds of workflow agents),
    /// each file once, biggest first; then each job's events in its file order.
    private static func read(_ jobs: [Job]) -> [SessionUsage] {
        guard !jobs.isEmpty else { return [] }
        var files: [(url: URL, subagent: Bool, size: Int)] = []
        var index: [String: Int] = [:]
        for j in jobs {
            for (f, url) in j.files.enumerated() where index[url.path] == nil {
                index[url.path] = files.count
                files.append((url, f >= j.mains, j.stamps[f].size))
            }
        }
        var pieces: [(file: Int, piece: Int, last: Bool, size: Int)] = []
        for (f, file) in files.enumerated() {
            let n = UsageReader.pieces(size: file.size)
            for k in 0..<n { pieces.append((f, k, k == n - 1, min(UsageReader.pieceSize, file.size - k * UsageReader.pieceSize))) }
        }
        pieces.sort { $0.size > $1.size }
        var parsed = [[UsageReader.Event]](repeating: [], count: pieces.count)
        parsed.withUnsafeMutableBufferPointer { buf in
            let out = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: pieces.count) { i in
                let p = pieces[i]
                guard let data = try? Data(contentsOf: files[p.file].url, options: .alwaysMapped) else { return }
                out[i] = UsageReader.events(in: data, piece: p.piece, last: p.last, subagent: files[p.file].subagent)
            }
        }
        var events = [[UsageReader.Event]](repeating: [], count: files.count)
        for i in pieces.indices.sorted(by: { (pieces[$0].file, pieces[$0].piece) < (pieces[$1].file, pieces[$1].piece) }) {
            events[pieces[i].file] += parsed[i]
        }
        parsed = []
        var read = [SessionUsage?](repeating: nil, count: jobs.count)
        let calendar = Calendar.usage
        read.withUnsafeMutableBufferPointer { buf in
            let out = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                let j = jobs[i]
                out[i] = UsageReader.fold(sessionID: j.id, projectDir: j.project, files: j.files.map { events[index[$0.path]!] },
                                          mains: j.mains, calendar: calendar)
            }
        }
        return read.compactMap { $0 }
    }
}
