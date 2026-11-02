import Foundation

// Compiled into both the search helper and the app (Foundation only), so the two sides of the
// distributed notification always agree on its names, keys and rules.

/// The helper asks Claws for Concern to resume a session: Claws switches to its tab if it is still
/// running, else opens a terminal tab in its folder and types the resume command.
///
/// Any process on the Mac can post a distributed notification, and the session ID ends up typed into
/// a shell. So a request carries the nonce Claws gave the Search window it opened, the receiver only
/// accepts a UUID and a plain absolute folder (`init?(userInfo:)`), and Claws checks the rest itself
/// (docs/search.md, "Who can ask").
struct ResumeRequest: Equatable {
    static let note = Notification.Name("io.github.patildhruv.claws-for-concern.resumeSession")
    /// Claws for Concern's bundle ID, which is also its UserDefaults domain.
    static let appID = "io.github.patildhruv.claws-for-concern"
    /// Older requests are refused: one stuck behind a permission prompt must not open a tab later.
    static let maxAge = 30.0

    let sessionId: String
    let folder: String
    /// Claws passes one to each Search window it opens (`--nonce`); it refuses requests without one.
    let nonce: String
    /// Echoed in the reply, so the helper knows which request it answers.
    let token: String
    /// When the helper sent it, in seconds since 1970.
    let sent: Double

    init(sessionId: String, folder: String, nonce: String, token: String = UUID().uuidString,
         sent: Double = Date().timeIntervalSince1970) {
        self.sessionId = sessionId
        self.folder = folder
        self.nonce = nonce
        self.token = token
        self.sent = sent
    }

    var userInfo: [String: String] {
        ["sessionId": sessionId, "folder": folder, "nonce": nonce, "token": token, "sent": String(sent)]
    }

    init?(userInfo: [AnyHashable: Any]?) {
        guard let u = userInfo, let id = u["sessionId"] as? String, let folder = u["folder"] as? String,
              let nonce = u["nonce"] as? String, !nonce.isEmpty, nonce.count <= 64,
              let token = u["token"] as? String, token.count <= 64,
              let sent = (u["sent"] as? String).flatMap(Double.init), sent.isFinite,
              Self.isSessionID(id), Self.isFolder(folder) else { return nil }
        self.init(sessionId: id, folder: folder, nonce: nonce, token: token, sent: sent)
    }

    /// The nonce this helper was launched with (`--nonce <value>`), if Claws launched it.
    static func launchNonce(_ args: [String] = CommandLine.arguments) -> String? {
        guard let i = args.firstIndex(of: "--nonce"), i + 1 < args.count, !args[i + 1].isEmpty else { return nil }
        return args[i + 1]
    }

    /// Claude Code's session IDs are UUIDs. Title-only stubs named `<uuid>.orphaned-…` are not.
    static func isSessionID(_ s: String) -> Bool {
        s.range(of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
                options: .regularExpression) != nil
    }

    /// An absolute path with no control characters and nothing `standardizingPath` would rewrite: no
    /// `.` or `..`, no `//`, no trailing `/`. Checked by hand, because `standardizingPath` also turns an
    /// existing /private/tmp/… into /tmp/… (it looks on disk), which would refuse real sessions there.
    static func isFolder(_ s: String) -> Bool {
        guard s.hasPrefix("/"), s.count < 4096,
              !s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        if s == "/" { return true }
        return !s.dropFirst().split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}

/// Claws for Concern's answer. A new tab is answered twice: `opening` at once, then the outcome.
struct ResumeReply: Equatable {
    static let note = Notification.Name("io.github.patildhruv.claws-for-concern.resumeSessionReply")

    enum Status: String { case focused, opening, opened, failed }
    let token: String
    let status: Status
    /// One line for the helper's status bar.
    let message: String

    var userInfo: [String: String] { ["token": token, "status": status.rawValue, "message": message] }

    init(token: String, status: Status, message: String) {
        self.token = token
        self.status = status
        self.message = message
    }

    init?(userInfo: [AnyHashable: Any]?) {
        guard let u = userInfo, let token = u["token"] as? String,
              let status = (u["status"] as? String).flatMap(Status.init), let message = u["message"] as? String else { return nil }
        self.init(token: token, status: status, message: String(message.prefix(300)))
    }
}

/// Settings → General → Resume command in Claws for Concern: a template where {id} is the session ID.
enum ResumeCommand {
    /// Also the default of `Settings.resumeCommand`.
    static let defaultTemplate = "claude --resume {id}"

    /// The template as Claws for Concern stores it (key `resumeCommand` in its domain); empty means default.
    static func template(_ defaults: UserDefaults? = UserDefaults(suiteName: ResumeRequest.appID)) -> String {
        guard let t = defaults?.string(forKey: "resumeCommand"), !t.isEmpty else { return defaultTemplate }
        return t
    }

    static func expand(_ template: String, id: String) -> String {
        template.replacingOccurrences(of: "{id}", with: id)
    }
}

/// Claude Code's project folder names, as its 2.1.316 bundle makes them: every UTF-16 unit outside
/// [A-Za-z0-9] becomes "-", and a name over 200 characters is cut there and gets "-" plus its hash.
enum ProjectDirs {
    static let limit = 200

    static func encode(_ path: String) -> String {
        String(String.UnicodeScalarView(path.utf16.map { u -> Unicode.Scalar in
            let ok = (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A)
            return ok ? Unicode.Scalar(UInt8(u)) : "-"
        }))
    }

    /// Claude Code's string hash: `h = (h << 5) - h + unit`, 32-bit, over the path's UTF-16 units.
    static func hash(_ path: String) -> Int32 {
        var h: Int32 = 0
        for u in path.utf16 { h = (h &<< 5) &- h &+ Int32(u) }
        return h
    }

    /// The folder name in ~/.claude/projects, hash included (`Math.abs(hash).toString(36)`).
    static func name(for path: String) -> String {
        let e = encode(path)
        guard e.count > limit else { return e }
        return String(e.prefix(limit)) + "-" + String(Int64(hash(path)).magnitude, radix: 36)
    }

    static func matches(_ path: String, _ dirName: String) -> Bool { name(for: path) == dirName }

    /// The folders session `id` resumes from, one per transcript named `<id>.jsonl` in `projects`.
    /// Claws accepts a request only for one of these: the request names the folder, this reads it.
    static func resumeFolders(_ id: String, projects: URL) -> [String] {
        guard ResumeRequest.isSessionID(id) else { return [] }
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        return dirs.sorted().compactMap { dir in
            let file = projects.appendingPathComponent(dir).appendingPathComponent(id + ".jsonl")
            return FileManager.default.fileExists(atPath: file.path) ? folder(transcript: file, project: dir) : nil
        }
    }

    /// The helper's rule (`SessionBuilder`): the last `relocated` record's folder, else the first
    /// recorded cwd, whichever is filed under `project`. Decodes only until it has the first cwd.
    static func folder(transcript: URL, project: String) -> String? {
        guard let data = try? Data(contentsOf: transcript, options: .alwaysMapped) else { return nil }
        struct Line: Decodable { let type: String?; let cwd: String?; let relocatedCwd: String? }
        let decoder = JSONDecoder()
        let messages = [#""type":"user""#, #""type":"assistant""#].map { Array($0.utf8) }
        let moved = Array(#""type":"relocated""#.utf8)
        var relocated: String?, first: String?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var start = 0
            while start < raw.count {
                let end = memchr(base + start, 0x0A, raw.count - start).map { base.distance(to: UnsafeRawPointer($0)) } ?? raw.count
                let line = base + start, len = end - start
                func has(_ needle: [UInt8]) -> Bool { needle.withUnsafeBytes { memmem(line, len, $0.baseAddress, $0.count) != nil } }
                if len > 2, (first == nil && messages.contains(where: has)) || (len < 16_384 && has(moved)),
                   let l = try? decoder.decode(Line.self, from: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line),
                                                                     count: len, deallocator: .none)) {
                    switch l.type {
                    case "relocated": if let c = l.relocatedCwd, !c.isEmpty { relocated = c }
                    case "user", "assistant": if first == nil, let c = l.cwd, !c.isEmpty, matches(c, project) { first = c }
                    default: break
                    }
                }
                start = end + 1
            }
        }
        if let r = relocated, matches(r, project) { return r }
        return first
    }
}

/// Checks for this file, run by both self-tests (the helper's and the app's).
enum ResumeBridgeTests {
    static func run() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { out.append(("resume bridge: " + name, ok)) }
        let id = "0f1e2d3c-4b5a-6978-8a9b-acbdcedfe0f1"

        let r = ResumeRequest(sessionId: id, folder: "/Users/someone/code/web app", nonce: "n-1")
        check("request round trip", ResumeRequest(userInfo: r.userInfo as [AnyHashable: Any]) == r)
        check("names in the app's domain", ResumeRequest.note.rawValue.hasPrefix(ResumeRequest.appID + ".")
              && ResumeReply.note.rawValue.hasPrefix(ResumeRequest.appID + "."))
        var bad = r.userInfo
        bad["sessionId"] = id + "; echo injected"
        check("an ID that is not a UUID is refused (it is typed into a shell)", ResumeRequest(userInfo: bad) == nil)
        bad["sessionId"] = id + ".orphaned-1783010945600-9f9d0e8a"
        check("an orphaned title stub is refused", ResumeRequest(userInfo: bad) == nil)
        for folder in ["code/web", "", "/a\nb", "/a\u{0}b", "/a/../b", "/a/./b", "/a//b", "/a/b/", "/a/.."] {
            var f = r.userInfo
            f["folder"] = folder
            check("folder \(folder.debugDescription) refused", ResumeRequest(userInfo: f) == nil)
        }
        check("plain folders accepted, /private/tmp as recorded", ["/", "/private/tmp/x", "/Users/a b/c.d"].allSatisfy(ResumeRequest.isFolder))
        for key in ["nonce", "token", "sent"] {
            var missing = r.userInfo
            missing[key] = nil
            check("missing \(key) refused", ResumeRequest(userInfo: missing) == nil)
        }
        var empty = r.userInfo
        empty["nonce"] = ""
        check("empty nonce refused", ResumeRequest(userInfo: empty) == nil && ResumeRequest(userInfo: nil) == nil)
        check("launch nonce read from --nonce", ResumeRequest.launchNonce(["x", "--nonce", "abc"]) == "abc"
              && ResumeRequest.launchNonce(["x", "--nonce"]) == nil && ResumeRequest.launchNonce(["x"]) == nil)

        let reply = ResumeReply(token: r.token, status: .opening, message: "Opening a new Ghostty tab…")
        check("reply round trip", ResumeReply(userInfo: reply.userInfo as [AnyHashable: Any]) == reply)
        var junk = reply.userInfo
        junk["status"] = "exploded"
        check("unknown reply status refused", ResumeReply(userInfo: junk) == nil)
        junk = reply.userInfo
        junk["message"] = String(repeating: "x", count: 1000)
        check("reply message clipped", ResumeReply(userInfo: junk)?.message.count == 300)

        check("expand: default template", ResumeCommand.expand(ResumeCommand.defaultTemplate, id: id) == "claude --resume \(id)")
        check("expand: every {id}", ResumeCommand.expand("x {id} --name {id}", id: id) == "x \(id) --name \(id)")
        // Registered defaults live in memory only: nothing is written to ~/Library/Preferences.
        let d = UserDefaults(suiteName: "io.github.patildhruv.claws-for-concern.selftest-\(getpid())")
        check("template: unset means the default", ResumeCommand.template(d) == ResumeCommand.defaultTemplate
              && ResumeCommand.template(nil) == ResumeCommand.defaultTemplate)
        d?.register(defaults: ["resumeCommand": "claude -r {id} --model opus"])
        check("template: the app's setting wins", ResumeCommand.template(d) == "claude -r {id} --model opus")
        d?.register(defaults: ["resumeCommand": ""])
        check("template: empty means the default, as in the app", ResumeCommand.template(d) == ResumeCommand.defaultTemplate)

        // Expected names computed by Claude Code 2.1.316's own two functions, run in node.
        let short = "/Users/someone/code/web app"
        check("project name: short paths are the plain encoding", ProjectDirs.name(for: short) == "-Users-someone-code-web-app")
        for (path, hash) in [("/Users/someone/" + String(repeating: "deep/", count: 45) + "app", "pq4etr"),
                             ("/Users/someone/" + String(repeating: "projets-é/", count: 25) + "fin", "d6793g"),
                             ("/Users/someone/" + String(repeating: "x", count: 190) + "/🦀/end", "f70yhi")] {
            check("project name: \(path.count) characters ends in Claude Code's hash -\(hash)",
                  ProjectDirs.name(for: path) == String(ProjectDirs.encode(path).prefix(200)) + "-" + hash)
        }

        let fm = FileManager.default
        let projects = fm.temporaryDirectory.appendingPathComponent("claws-resume-test-\(getpid())", isDirectory: true)
        defer { try? fm.removeItem(at: projects) }
        func transcript(_ dir: String, _ sid: String, _ lines: [String]) {
            let at = projects.appendingPathComponent(dir, isDirectory: true)
            try? fm.createDirectory(at: at, withIntermediateDirectories: true)
            fm.createFile(atPath: at.appendingPathComponent(sid + ".jsonl").path, contents: Data((lines.joined(separator: "\n") + "\n").utf8))
        }
        func user(_ cwd: String) -> String { #"{"type":"user","cwd":"\#(cwd)","message":{"content":"hi"}}"# }
        func moved(_ cwd: String) -> String { #"{"type":"relocated","relocatedCwd":"\#(cwd)"}"# }
        let ids = (1...5).map { String(format: "0f1e2d3c-4b5a-6978-8a9b-acbdcedfe0%02d", $0) }
        let long = "/Users/someone/" + String(repeating: "deep/", count: 45) + "app"
        transcript(ProjectDirs.name(for: short), ids[0], [user("/Users/someone/elsewhere"), user(short), user("/Users/someone/later")])
        transcript(ProjectDirs.name(for: short), ids[1], [user("/Users/someone/elsewhere"), moved(short)])
        transcript(ProjectDirs.name(for: short), ids[2], [user(short), moved("/Users/someone/not-here")])
        transcript(ProjectDirs.name(for: long), ids[3], [user(long)])
        transcript(String(ProjectDirs.encode(long).prefix(200)) + "-1a2b3c", ids[4], [user(long)])
        check("folder: the first recorded cwd filed under the project", ProjectDirs.resumeFolders(ids[0], projects: projects) == [short])
        check("folder: a relocated record wins", ProjectDirs.resumeFolders(ids[1], projects: projects) == [short])
        check("folder: a relocation elsewhere is ignored", ProjectDirs.resumeFolders(ids[2], projects: projects) == [short])
        check("folder: long names match with the hash", ProjectDirs.resumeFolders(ids[3], projects: projects) == [long])
        check("folder: long names with another hash do not", ProjectDirs.resumeFolders(ids[4], projects: projects).isEmpty)
        check("folder: unknown sessions have none", ProjectDirs.resumeFolders(id, projects: projects).isEmpty
              && ProjectDirs.resumeFolders("not-a-session", projects: projects).isEmpty)
        return out
    }
}
