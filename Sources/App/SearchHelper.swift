import AppKit

/// Search lives in its own app inside the bundle (Contents/Helpers/Claws Search.app): its index, a few
/// hundred MB, is only in memory while the window is open, and a crash there never takes the Clawds
/// down. It asks us to resume a session with a distributed notification (`ResumeRequest`), and we
/// answer with what happened (`ResumeReply`), which it shows in its status line.
enum SearchHelper {
    static var url: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Claws Search.app") }
    static var projects: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects") }

    /// Opens the search window, or brings it forward when it is already open.
    static func open() {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { AppLog.write("search: could not open the helper: \(error.localizedDescription)") }
        }
    }

    /// Main thread, once at launch.
    static func listen(tracker: Tracker) {
        DistributedNotificationCenter.default().addObserver(forName: ResumeRequest.note, object: nil, queue: .main) { note in
            guard let r = ResumeRequest(userInfo: note.userInfo) else {
                AppLog.write("search: ignored a resume request that was not a session ID and a folder")
                return
            }
            resume(r, tracker: tracker)
        }
    }

    enum Plan: Equatable {
        case focus
        case newPane(command: String)
        case refuse(String)
    }

    /// A session that is still running gets the Clawd-click path (its own tab), never a second process.
    /// Otherwise a new tab, but only in the folder Claude Code filed the session under: that is the only
    /// place `claude --resume` finds it, and anything else would be a shell opened wherever the
    /// notification's sender liked.
    static func plan(_ r: ResumeRequest, live: Bool, filed: Bool, template: String) -> Plan {
        if live { return .focus }
        guard filed else { return .refuse("Claude Code did not file this session under \(abbreviate(r.folder)).") }
        return .newPane(command: ResumeCommand.expand(template, id: r.sessionId))
    }

    static func resume(_ r: ResumeRequest, tracker: Tracker) {
        // A session file can outlive its process by up to one reap (10 s): ask the process itself.
        let live = tracker.state(r.sessionId).map { s in s.claudePid.map { ProcInfo.isAlive(pid: $0, start: s.claudeStart) } ?? true } ?? false
        let filed = live || ProjectDirs.holds(r.sessionId, folder: r.folder, projects: projects)
        let id = r.sessionId.prefix(8)
        switch plan(r, live: live, filed: filed, template: Settings.resumeCommand) {
        case .focus:
            let terminal = tracker.terminalName(r.sessionId).map { $0 == "Other terminals" ? "" : " in \($0)" } ?? ""
            AppLog.write("search: \(id) is running: switching to it")
            tracker.open(r.sessionId)
            reply(r, .focused, "Still running: switched to it\(terminal).")
        case .refuse(let why):
            AppLog.write("search: \(id) refused: not filed under its folder")
            reply(r, .failed, why)
        case .newPane(let command):
            // Ghostty for now: a session that is no longer running has no terminal on record.
            guard let a = Terminals.shared.adapter(id: "ghostty") else { reply(r, .failed, "No terminal can open a tab."); return }
            AppLog.write("search: \(id) resuming in a new \(a.name) tab")
            reply(r, .opening, "Opening a new \(a.name) tab in \(abbreviate(r.folder))…")
            Terminals.shared.newPane(a, in: r.folder, typing: command) { ok in
                if ok { reply(r, .opened, "Resumed in a new \(a.name) tab: \(abbreviate(r.folder))"); return }
                let why = failure(a)
                AppLog.write("search: \(id) new tab failed: \(why)")
                reply(r, .failed, why)
            }
        }
    }

    private static func failure(_ a: TerminalAdapter) -> String {
        guard let b = a.scriptedBundleID else { return "\(a.name) did not open a tab." }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) == nil { return "\(a.name) is not installed." }
        switch Automation.cached(b) {
        case .denied: return "Claws for Concern may not control \(a.name): System Settings → Privacy & Security → Automation."
        case .undetermined: return "Claws for Concern needs permission to control \(a.name)."
        case .notRunning: return "\(a.name) did not start."
        case .granted: return "\(a.name) did not open a tab."
        }
    }

    private static func reply(_ r: ResumeRequest, _ status: ResumeReply.Status, _ message: String) {
        DistributedNotificationCenter.default().postNotificationName(
            ResumeReply.note, object: nil, userInfo: ResumeReply(token: r.token, status: status, message: message).userInfo,
            deliverImmediately: true)
    }

    private static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
