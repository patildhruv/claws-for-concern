import Foundation

// Compiled into both the search helper and the app (Foundation only), so the two sides of the
// distributed notification always agree on its names, keys and rules.

/// The helper asks Claws for Concern to resume a session: Claws switches to its tab if it is still
/// open, else opens a terminal tab in its folder and types the resume command.
///
/// Any process on the Mac can post a distributed notification, and the session ID ends up typed into
/// a shell, so the receiver only accepts a UUID and an absolute folder (see `init?(userInfo:)`).
struct ResumeRequest: Equatable {
    static let note = Notification.Name("io.github.patildhruv.claws-for-concern.resumeSession")
    /// Claws for Concern's bundle ID, which is also its UserDefaults domain.
    static let appID = "io.github.patildhruv.claws-for-concern"

    let sessionId: String
    let folder: String
    /// Echoed in the reply, so the helper knows which request it answers.
    let token: String

    init(sessionId: String, folder: String, token: String = UUID().uuidString) {
        self.sessionId = sessionId
        self.folder = folder
        self.token = token
    }

    var userInfo: [String: String] { ["sessionId": sessionId, "folder": folder, "token": token] }

    init?(userInfo: [AnyHashable: Any]?) {
        guard let u = userInfo, let id = u["sessionId"] as? String, let folder = u["folder"] as? String,
              let token = u["token"] as? String, token.count <= 64,
              Self.isSessionID(id), Self.isFolder(folder) else { return nil }
        self.init(sessionId: id, folder: folder, token: token)
    }

    /// Claude Code's session IDs are UUIDs. Title-only stubs named `<uuid>.orphaned-…` are not.
    static func isSessionID(_ s: String) -> Bool {
        s.range(of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
                options: .regularExpression) != nil
    }

    /// An absolute path with no control characters (it becomes a terminal's working directory).
    static func isFolder(_ s: String) -> Bool {
        s.hasPrefix("/") && s.count < 4096 && !s.unicodeScalars.contains { $0.properties.generalCategory == .control }
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
    /// Must match the default of `Settings.resumeCommand` (the app's self-test checks they agree).
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

/// Claude Code's project folder names: every character outside [A-Za-z0-9] becomes "-",
/// and names over 200 characters are cut there and get a hash suffix (2.1.289).
enum ProjectDirs {
    static let limit = 200

    static func encode(_ path: String) -> String {
        String(String.UnicodeScalarView(path.utf16.map { u -> Unicode.Scalar in
            let ok = (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A)
            return ok ? Unicode.Scalar(UInt8(u)) : "-"
        }))
    }

    static func matches(_ path: String, _ dirName: String) -> Bool {
        let e = encode(path)
        if e.count <= limit { return e == dirName }
        return dirName.count > limit && dirName.hasPrefix(e.prefix(limit))
    }

    /// Is session `id` filed under `folder`'s project? `claude --resume` only finds it from there, and
    /// it keeps a resume request from opening a shell in a folder Claude Code never worked in.
    /// Reads only inside `projects` (~/.claude/projects), never the folder itself.
    static func holds(_ id: String, folder: String, projects: URL) -> Bool {
        let e = encode(folder)
        let dirs = e.count <= limit ? [e]
            : ((try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []).filter { matches(folder, $0) }
        return dirs.contains {
            FileManager.default.fileExists(atPath: projects.appendingPathComponent($0).appendingPathComponent(id + ".jsonl").path)
        }
    }
}

/// Checks for this file, run by both self-tests (the helper's and the app's).
enum ResumeBridgeTests {
    static func run() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { out.append(("resume bridge: " + name, ok)) }
        let id = "0f1e2d3c-4b5a-6978-8a9b-acbdcedfe0f1"

        let r = ResumeRequest(sessionId: id, folder: "/Users/someone/code/web app")
        check("request round trip", ResumeRequest(userInfo: r.userInfo as [AnyHashable: Any]) == r)
        check("names in the app's domain", ResumeRequest.note.rawValue.hasPrefix(ResumeRequest.appID + ".")
              && ResumeReply.note.rawValue.hasPrefix(ResumeRequest.appID + "."))
        var bad = r.userInfo
        bad["sessionId"] = id + "; echo injected"
        check("an ID that is not a UUID is refused (it is typed into a shell)", ResumeRequest(userInfo: bad) == nil)
        bad["sessionId"] = id + ".orphaned-1783010945600-9f9d0e8a"
        check("an orphaned title stub is refused", ResumeRequest(userInfo: bad) == nil)
        for folder in ["code/web", "", "/a\nb", "/a\u{0}b"] {
            var f = r.userInfo
            f["folder"] = folder
            check("folder \(folder.debugDescription) refused", ResumeRequest(userInfo: f) == nil)
        }
        var noToken = r.userInfo
        noToken["token"] = nil
        check("missing fields refused", ResumeRequest(userInfo: noToken) == nil && ResumeRequest(userInfo: nil) == nil)

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

        let fm = FileManager.default
        let projects = fm.temporaryDirectory.appendingPathComponent("claws-resume-test-\(getpid())", isDirectory: true)
        defer { try? fm.removeItem(at: projects) }
        let short = "/Users/someone/code/web app", long = "/Users/someone/" + String(repeating: "deep/", count: 45) + "app"
        for (folder, dir) in [(short, ProjectDirs.encode(short)),
                              (long, String(ProjectDirs.encode(long).prefix(ProjectDirs.limit)) + "-1a2b3c")] {
            let at = projects.appendingPathComponent(dir, isDirectory: true)
            try? fm.createDirectory(at: at, withIntermediateDirectories: true)
            fm.createFile(atPath: at.appendingPathComponent(id + ".jsonl").path, contents: Data())
            check("filed under its folder (\(folder.count) characters)", ProjectDirs.holds(id, folder: folder, projects: projects))
        }
        check("not filed under another folder", !ProjectDirs.holds(id, folder: "/Users/someone/elsewhere", projects: projects))
        check("not another session", !ProjectDirs.holds("1f1e2d3c-4b5a-6978-8a9b-acbdcedfe0f1", folder: short, projects: projects))
        return out
    }
}
