import Foundation

/// Finds and parses Claude Code transcripts under ~/.claude/projects/<encoded cwd>/<session id>.jsonl,
/// plus each session's subagent transcripts in <session id>/subagents/*.jsonl.
/// Keeps parsed sessions between calls and re-reads only files whose size or mtime changed.
final class SessionStore: @unchecked Sendable {
    let root: URL
    private var cache: [String: Entry] = [:]
    private var resolved: [String: String?] = [:]       // project folder name -> folder on disk
    private let resolvedLock = NSLock()

    struct Stamp: Equatable { let size: Int; let mtime: Double }
    private struct Entry { let stamps: [Stamp]; let session: Session? }
    private struct Job { let key: String; let file: URL; let project: String; let subagents: [URL]; let stamps: [Stamp] }

    init(root: URL = URL(fileURLWithPath: Paths.home).appendingPathComponent(".claude/projects", isDirectory: true)) {
        self.root = root
    }

    /// Not reentrant: callers serialise (AppModel only runs one refresh at a time).
    func load() -> (sessions: [Session], changed: Bool) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        func list(_ dir: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        }

        var next = [String: Entry]()
        var jobs = [Job]()
        for dir in list(root) where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            for file in list(dir) where file.pathExtension == "jsonl" {
                let id = file.deletingPathExtension().lastPathComponent
                let subagents = list(dir.appendingPathComponent(id, isDirectory: true).appendingPathComponent("subagents", isDirectory: true))
                    .filter { $0.pathExtension == "jsonl" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                let stamps = ([file] + subagents).map(Self.stamp)
                if let old = cache[file.path], old.stamps == stamps {
                    next[file.path] = old
                } else {
                    jobs.append(Job(key: file.path, file: file, project: dir.lastPathComponent, subagents: subagents, stamps: stamps))
                }
            }
        }
        let changed = !jobs.isEmpty || next.count != cache.count

        // Biggest first so one huge transcript doesn't start last and hold everything up.
        jobs.sort { $0.stamps.reduce(0) { $0 + $1.size } > $1.stamps.reduce(0) { $0 + $1.size } }
        var parsed = [Session?](repeating: nil, count: jobs.count)
        parsed.withUnsafeMutableBufferPointer { buf in
            let out = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                let job = jobs[i]
                out[i] = self.parse(job.file, project: job.project, subagents: job.subagents, stamp: job.stamps[0])
            }
        }
        for (i, job) in jobs.enumerated() { next[job.key] = Entry(stamps: job.stamps, session: parsed[i]) }
        cache = next
        return (next.values.compactMap(\.session), changed)
    }

    private static func stamp(_ url: URL) -> Stamp {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return Stamp(size: v?.fileSize ?? 0, mtime: v?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)
    }

    func parse(_ file: URL, project: String, subagents: [URL], stamp: Stamp) -> Session? {
        var builder = SessionBuilder(id: file.deletingPathExtension().lastPathComponent)
        Self.forEachRecord(in: file) { builder.add($0, subagent: false) }
        for sub in subagents { Self.forEachRecord(in: sub) { builder.add($0, subagent: true) } }
        return builder.build(file: file, project: project, size: stamp.size,
                             mtime: Date(timeIntervalSinceReferenceDate: stamp.mtime), subagentCount: subagents.count,
                             resolve: resolveProject)
    }

    private func resolveProject(_ name: String) -> String? {
        resolvedLock.lock()
        defer { resolvedLock.unlock() }
        if let known = resolved[name] { return known }
        let found = ProjectDirs.resolve(name)
        resolved[name] = .some(found)
        return found
    }

    // Most bytes are tool output and file snapshots; only lines carrying one of these get JSON-decoded.
    private static let messageNeedles = [#""type":"user""#, #""type":"assistant""#].map { Array($0.utf8) }
    private static let titleNeedles = [#""type":"custom-title""#, #""type":"ai-title""#, #""type":"agent-name""#,
                                       #""type":"summary""#, #""type":"relocated""#].map { Array($0.utf8) }

    static func forEachRecord(in url: URL, _ body: (Record) -> Void) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return }
        let decoder = JSONDecoder()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let n = raw.count
            var start = 0
            while start < n {
                let end = memchr(base + start, 0x0A, n - start).map { base.distance(to: UnsafeRawPointer($0)) } ?? n
                let line = base + start
                let len = end - start
                if len > 2 && wanted(line, len) {
                    let bytes = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line), count: len, deallocator: .none)
                    if let record = try? decoder.decode(Record.self, from: bytes) { body(record) }
                }
                start = end + 1
            }
        }
    }

    private static func wanted(_ line: UnsafeRawPointer, _ len: Int) -> Bool {
        func has(_ needle: [UInt8]) -> Bool {
            needle.withUnsafeBytes { memmem(line, len, $0.baseAddress, $0.count) != nil }
        }
        if messageNeedles.contains(where: has) { return true }
        return len < 16_384 && titleNeedles.contains(where: has)    // title records are tiny
    }
}

/// One transcript line, decoded leniently: a field that is missing or has an unexpected type is nil.
struct Record: Decodable {
    var type: String?
    var cwd: String?
    var timestamp: String?
    var gitBranch: String?
    var entrypoint: String?
    var isMeta = false
    var isCompactSummary = false
    var content: Content?
    var title: String?      // customTitle / aiTitle / agentName / summary, by type
    var relocatedCwd: String?

    private enum Keys: String, CodingKey {
        case type, cwd, timestamp, gitBranch, entrypoint, isMeta, isCompactSummary, message
        case customTitle, aiTitle, agentName, summary, relocatedCwd
    }
    private enum MessageKeys: String, CodingKey { case content }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        func string(_ key: Keys) -> String? { try? c.decodeIfPresent(String.self, forKey: key) }
        switch type {
        case "user", "assistant":
            cwd = string(.cwd)
            timestamp = string(.timestamp)
            gitBranch = string(.gitBranch)
            entrypoint = string(.entrypoint)
            isMeta = (try? c.decodeIfPresent(Bool.self, forKey: .isMeta)) ?? false
            isCompactSummary = (try? c.decodeIfPresent(Bool.self, forKey: .isCompactSummary)) ?? false
            if let m = try? c.nestedContainer(keyedBy: MessageKeys.self, forKey: .message) {
                content = try? m.decodeIfPresent(Content.self, forKey: .content)
            }
        case "custom-title": title = string(.customTitle)
        case "ai-title": title = string(.aiTitle)
        case "agent-name": title = string(.agentName)
        case "summary": title = string(.summary)
        case "relocated": relocatedCwd = string(.relocatedCwd)
        default: break
        }
    }
}

enum Content: Decodable {
    case text(String)
    case blocks([Block])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .text(s)
        } else {
            self = .blocks(((try? c.decode([Lenient<Block>].self)) ?? []).compactMap(\.value))
        }
    }
}

struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) { value = try? T(from: decoder) }
}

/// A content block. tool_result blocks are skipped without materialising their (large) text.
struct Block: Decodable {
    var type: String?
    var text: String?
    var name: String?
    var input: FlatStrings?

    private enum Keys: String, CodingKey { case type, text, name, input }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        switch type {
        case "text":
            text = try? c.decodeIfPresent(String.self, forKey: .text)
        case "tool_use":
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            input = try? c.decodeIfPresent(FlatStrings.self, forKey: .input)
        default:
            break
        }
    }
}

/// Every string value inside a JSON value. Makes tool-call inputs (commands, paths, edits) searchable.
struct FlatStrings: Decodable {
    var parts: [String] = []

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
    }
    // Shown first in snippets, so "Bash: <command>" reads naturally.
    private static let leading = ["command", "description", "file_path", "path", "pattern", "query", "url", "prompt"]

    init(from decoder: Decoder) {
        if let keyed = try? decoder.container(keyedBy: AnyKey.self) {
            let keys = keyed.allKeys.sorted {
                let a = Self.leading.firstIndex(of: $0.stringValue) ?? Int.max
                let b = Self.leading.firstIndex(of: $1.stringValue) ?? Int.max
                return a != b ? a < b : $0.stringValue < $1.stringValue
            }
            for key in keys {
                if let v = try? keyed.decode(FlatStrings.self, forKey: key) { parts += v.parts }
            }
        } else if var list = try? decoder.unkeyedContainer() {
            while !list.isAtEnd {
                guard let v = try? list.decode(FlatStrings.self) else { break }
                parts += v.parts
            }
        } else if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
            parts.append(s)
        }
    }
}

struct SessionBuilder {
    let id: String
    var cwds: [String] = []     // distinct, in order of appearance
    var relocatedCwd: String?   // set when a session cd'd and Claude Code moved its transcript
    var gitBranch: String?
    var entrypoint: String?
    var firstTimestamp: String?
    var lastTimestamp: String?
    var titles: [String: String] = [:]     // record type -> last value seen
    var firstPrompt: String?
    var autonomous = false
    var messages: [Message] = []
    var promptCount = 0

    init(id: String) { self.id = id }

    mutating func add(_ r: Record, subagent: Bool) {
        switch r.type {
        case "custom-title", "ai-title", "agent-name", "summary":
            if !subagent, let t = r.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { titles[r.type!] = t }
        case "relocated":
            if !subagent, let c = r.relocatedCwd, !c.isEmpty { relocatedCwd = c }
        case "user":
            if !subagent { noteContext(r) }
            guard !r.isMeta, !r.isCompactSummary, let content = r.content else { return }
            let texts: [String]
            switch content {
            case .text(let s): texts = [s]
            case .blocks(let blocks): texts = blocks.compactMap { $0.type == "text" ? $0.text : nil }
            }
            for t in texts where !t.allSatisfy(\.isWhitespace) {
                if !subagent && firstPrompt == nil && !autonomous {
                    if t.hasPrefix("<tick>") { autonomous = true } else { firstPrompt = Prompts.display(t) }
                }
                if !subagent { promptCount += 1 }
                messages.append(Message(kind: .prompt, subagent: subagent, text: t, timestamp: r.timestamp))
            }
        case "assistant":
            if !subagent { noteContext(r) }
            guard case .blocks(let blocks)? = r.content else { return }
            for b in blocks {
                if b.type == "text", let t = b.text, !t.allSatisfy(\.isWhitespace) {
                    messages.append(Message(kind: .reply, subagent: subagent, text: t, timestamp: r.timestamp))
                } else if b.type == "tool_use" {
                    let body = (b.input?.parts ?? []).joined(separator: "\n")
                    messages.append(Message(kind: .toolCall, subagent: subagent, text: "\(b.name ?? "Tool"): \(body)", timestamp: r.timestamp))
                }
            }
        default:
            break
        }
    }

    private mutating func noteContext(_ r: Record) {
        if let c = r.cwd, !c.isEmpty, cwds.last != c, !cwds.contains(c) { cwds.append(c) }
        if let b = r.gitBranch, !b.isEmpty { gitBranch = b }
        if entrypoint == nil { entrypoint = r.entrypoint }
        if let t = r.timestamp {
            if firstTimestamp == nil { firstTimestamp = t }
            lastTimestamp = t
        }
    }

    func build(file: URL, project: String, size: Int, mtime: Date, subagentCount: Int,
               resolve: (String) -> String?) -> Session? {
        // /resume hides sessions with nothing to show; so do we.
        guard !messages.isEmpty || !titles.isEmpty else { return nil }

        // The folder is the one the project folder name encodes. Claude Code 2.1.289 takes the last
        // `relocated` record, else the first cwd; for branched or hand-moved sessions it's a later
        // cwd, or only findable on disk.
        // Claws for Concern reads the same rule back (`ProjectDirs.folder`) before it opens a tab.
        var cwd = ([relocatedCwd].compactMap { $0 } + cwds).first { ProjectDirs.matches($0, project) }
        let recorded = cwd != nil
        if cwd == nil { cwd = resolve(project) }
        let uncertain = cwd == nil && !cwds.isEmpty
        if cwd == nil { cwd = cwds.first }

        // Same precedence as Claude Code 2.1.289's resume list: agentName || customTitle || aiTitle || summary || first prompt.
        var title = String(id.prefix(8))
        var source = TitleSource.fallback
        for (type, src) in [("agent-name", TitleSource.agentName), ("custom-title", .customTitle), ("ai-title", .aiTitle), ("summary", .summary)] {
            if let t = titles[type] { title = t; source = src; break }
        }
        if source == .fallback {
            if let p = firstPrompt { title = p; source = .firstPrompt }
            else if autonomous { title = "Autonomous session"; source = .firstPrompt }
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Session(
            id: id, file: file, projectDir: project, cwd: cwd,
            recordedCwd: cwds.first.flatMap { $0 == cwd ? nil : $0 }, cwdUncertain: uncertain, folderRecorded: recorded,
            title: title, titleSource: source,
            altTitles: Array(Set(titles.values)).filter { $0 != title }.sorted(),
            firstPrompt: firstPrompt, gitBranch: gitBranch, entrypoint: entrypoint,
            created: firstTimestamp.flatMap(iso.date(from:)),
            modified: lastTimestamp.flatMap(iso.date(from:)) ?? mtime,
            fileSize: size, subagentCount: subagentCount, promptCount: promptCount, messages: messages)
    }
}

/// How Claude Code renders a user prompt as a session name (approximated from 2.1.289).
enum Prompts {
    static let builtinCommands: Set<String> = [
        "add-dir", "agents", "artifacts", "bashes", "bug", "chrome", "clear", "compact", "config", "context", "copy",
        "cost", "desktop", "doctor", "effort", "exit", "export", "extra-usage", "fast", "feedback", "help", "hooks",
        "ide", "init", "insights", "install-github-app", "keybindings", "login", "logout", "mcp", "memory", "mobile",
        "model", "output-style", "permissions", "plugin", "plugins", "pr-comments", "privacy-settings", "release-notes",
        "remote-env", "rename", "resume", "review", "rewind", "sandbox", "security-review", "skills", "stats", "status",
        "statusline", "tasks", "teleport", "terminal-setup", "theme", "todos", "upgrade", "usage", "vim",
    ]
    static let skipPrefixes = ["<local-command-", "<bash-stdout>", "<bash-stderr>", "<command-message>",
                               "<task-notification>", "Caveat: The messages below", "[Request interrupted"]

    /// The text shown for a prompt, or nil when Claude Code skips it when naming a session.
    static func display(_ raw: String, limit: Int = 200) -> String? {
        let t = strip(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let name = tag("command-name", in: t) {
            let command = name.hasPrefix("/") ? String(name.dropFirst()) : name
            if builtinCommands.contains(command) { return nil }
            guard let args = tag("command-args", in: t)?.trimmingCharacters(in: .whitespacesAndNewlines), !args.isEmpty else { return nil }
            return clip("\(name) \(args)", limit)
        }
        if let command = tag("bash-input", in: t) { return clip("! \(command)", limit) }
        if skipPrefixes.contains(where: t.hasPrefix) { return nil }
        return clip(t, limit)
    }

    static func tag(_ name: String, in s: String) -> String? {
        guard let a = s.range(of: "<\(name)>"), let b = s.range(of: "</\(name)>", range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound])
    }

    static func strip(_ s: String) -> String {
        guard s.contains("<") else { return s }
        var out = s
        for name in ["system-reminder", "ide_opened_file", "ide_selection"] {
            while let a = out.range(of: "<\(name)"), let b = out.range(of: "</\(name)>", range: a.upperBound..<out.endIndex) {
                out.removeSubrange(a.lowerBound..<b.upperBound)
            }
        }
        return out
    }

    static func clip(_ s: String, _ limit: Int) -> String {
        let line = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard line.count > limit else { return line }
        return String(line.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
