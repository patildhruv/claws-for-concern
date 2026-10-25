import Foundation

/// Where everything lives. `CLAWS_HOME` overrides the root (self-test, demo).
enum Paths {
    static var root: URL {
        if let o = ProcessInfo.processInfo.environment["CLAWS_HOME"], !o.isEmpty {
            return URL(fileURLWithPath: o, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claws for Concern", isDirectory: true)
    }
    /// One `<session id>.json` per live Claude Code session, written only by the hook.
    static var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    /// The app's own memory: tab mapping, what you've seen, cached recaps.
    static var appState: URL { root.appendingPathComponent("app-state.json") }
    /// Empty working directory for the recap calls, so no project settings or CLAUDE.md load.
    static var summarizerCwd: URL { root.appendingPathComponent("summarizer", isDirectory: true) }
    static var log: URL { root.appendingPathComponent("claws.log") }
    /// Sprite sheets the app builds from Anthropic's Clawd GIFs on first launch (never shipped).
    static var art: URL { root.appendingPathComponent("art", isDirectory: true) }
    /// Optional: more official Clawd GIF URLs, one per line, added to the finished-Clawd pool.
    static var extraArt: URL { root.appendingPathComponent("extra-art.txt") }
}

/// What a session is doing, as last reported by its hooks.
enum SessionStatus: String, Codable {
    case idle        // started, no prompt yet
    case working     // a turn is running
    case blocked     // waiting on you mid-turn: permission, question, plan approval, MCP input
    case finished    // turn ended, Claude is waiting for your next prompt
    case background  // turn ended but subagents/workflows will wake it again
    case failed      // turn ended on an API error (rate limit, overload, auth...)
}

/// The per-session file the hook writes. Only the hook writes it; the app only reads it.
struct SessionState: Codable, Equatable {
    var sessionId: String
    var cwd: String
    /// Folder the session started in. Ghostty reports this as the tab's working directory.
    var rootCwd: String
    var transcriptPath: String?
    var status: SessionStatus = .idle
    /// When `status` last changed (epoch seconds).
    var statusTs: Double = 0
    /// Timestamp of the newest event applied; older events (async hooks can race) are dropped.
    var updatedTs: Double = 0
    /// Last UserPromptSubmit. The app reads the focused Ghostty tab when this moves.
    var promptTs: Double?
    /// permission | question | plan | input — only while `status == .blocked`.
    var blockedKind: String?
    /// The question, the command needing permission, the plan, or the API error.
    var detail: String?
    /// Claude's final message of the last finished turn (Stop.last_assistant_message).
    var lastMessage: String?
    var title: String?
    var permissionMode: String?
    var claudePid: Int32?
    /// Process start time of `claudePid`, so a reused PID is not mistaken for the session.
    var claudeStart: Double?
    var termProgram: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id", cwd, rootCwd = "root_cwd", transcriptPath = "transcript_path"
        case status, statusTs = "status_ts", updatedTs = "updated_ts", promptTs = "prompt_ts"
        case blockedKind = "blocked_kind", detail, lastMessage = "last_message", title
        case permissionMode = "permission_mode", claudePid = "claude_pid", claudeStart = "claude_start"
        case termProgram = "term_program"
    }

    init(sessionId: String, cwd: String) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.rootCwd = cwd
    }

    static func load(_ url: URL) -> SessionState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(sessionId).tmp")
        try enc.encode(self).write(to: tmp)
        // rename(2) is atomic and fires the directory watcher in the app.
        guard rename(tmp.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

/// Process helpers shared by the hook (to find its Claude process) and the app (to spot dead sessions).
enum ProcInfo {
    struct Entry { let pid: Int32; let ppid: Int32; let name: String; let start: Double }

    static func info(_ pid: Int32) -> Entry? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafePointer(to: kp.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        let tv = kp.kp_proc.p_starttime
        return Entry(pid: pid, ppid: kp.kp_eproc.e_ppid, name: name,
                     start: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }

    static func path(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    }

    /// Walk up from `pid` to the nearest Claude Code process. The native install runs as
    /// ~/.local/share/claude/versions/<version>, so the kernel's process name is the version
    /// number ("2.1.310"), not "claude"; match the executable path too.
    static func claudeAncestor(of pid: Int32) -> Entry? {
        var cur = pid
        for _ in 0..<12 {
            guard let e = info(cur) else { return nil }
            let p = path(cur)
            if e.name == "claude" || p.hasSuffix("/claude") || p.contains("/claude/versions/") { return e }
            if e.ppid <= 1 { return nil }
            cur = e.ppid
        }
        return nil
    }

    /// True when `pid` is alive and is still the process that started at `start`.
    static func isAlive(pid: Int32, start: Double?) -> Bool {
        guard let e = info(pid) else { return false }
        if let start { return abs(e.start - start) < 1 }
        return true
    }
}
