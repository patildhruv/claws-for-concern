import AppKit

/// Whether a launch was you opening the app (Search comes up) or macOS starting it (stay quiet).
enum LaunchIntent {
    /// 'oapp' from Finder, Spotlight, the Dock or `open`; not a login item ('lgit') or a service ('svit');
    /// not on first run, where the hooks question comes first; and, in case a login launch is not
    /// marked, not in the first 3 minutes after the Mac starts. No launch event: stay quiet.
    static func opensSearch(eventID: AEEventID?, propData: OSType?, uptime: TimeInterval, firstRun: Bool) -> Bool {
        guard eventID == AEEventID(kAEOpenApplication), !firstRun, uptime >= 180 else { return false }
        return propData != OSType(keyAELaunchedAsLogInItem) && propData != OSType(keyAELaunchedAsServiceItem)
    }

    /// 'oapp', 'lgit'… for the log.
    static func fourCC(_ c: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((c >> $0) & 0xff) }, encoding: .macOSRoman) ?? "\(c)"
    }
}

/// Search lives in its own app inside the bundle (Contents/Helpers/Claws Search.app): its index, a few
/// hundred MB, is only in memory while the window is open, and a crash there never takes the Clawds
/// down. It asks us to resume a session with a distributed notification (`ResumeRequest`), and we
/// answer with what happened (`ResumeReply`), which it shows in its status line.
///
/// Anyone can post that notification, so a request must carry the nonce we gave the Search window we
/// opened, come while that window is in front, be under 30 s old, and name the folder the session's
/// own transcript names. docs/search.md ("Who can ask") says what that does and does not stop.
enum SearchHelper {
    static var url: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Claws Search.app") }
    static var projects: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects") }

    /// Nonces given to the Search windows we opened, with the helper process each reached (0 until known).
    private static var nonces: [String: pid_t] = [:]
    private static var gate = ResumeGate()

    /// Asks a running helper for a window (it only opens one): the window and the helper's PID, so
    /// another copy of the helper ignores it. Anyone can post it; all it can do is open a window.
    static let windowNote = Notification.Name(ResumeRequest.appID + ".search.openWindow")

    /// Opens the search window, or brings it forward. A new helper gets a fresh nonce on its command
    /// line; one already running keeps the nonce it was started with.
    static func open() { show(window: "main") }

    /// The Usage window, and only that: a new helper starts with `--window usage` (its first scene),
    /// a running one is asked for it.
    static func openUsage() { show(window: "usage") }

    /// A new helper's command line: its nonce, and the window to bring up when it is not Search.
    static func arguments(nonce: String, window: String) -> [String] {
        window == "main" ? ["--nonce", nonce] : ["--nonce", nonce, "--window", window]
    }

    static func windowRequest(_ window: String, pid: pid_t) -> [String: Any] { ["window": window, "pid": Int(pid)] }

    /// This bundle's own helper, while it runs (a copy elsewhere has the same bundle ID).
    static func runningHelper() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: ResumeRequest.appID + ".search")
            .first { !$0.isTerminated && $0.bundleURL?.standardizedFileURL.path == url.standardizedFileURL.path }
    }

    private static func show(window: String) {
        let already = runningHelper()
        let nonce = UUID().uuidString
        nonces[nonce] = 0
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.arguments = arguments(nonce: nonce, window: window)
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, error in
            DispatchQueue.main.async {
                guard let pid = app?.processIdentifier else {
                    nonces[nonce] = nil
                    AppLog.write("search: could not open the helper: \(error?.localizedDescription ?? "no app")")
                    couldNotOpen(error)
                    return
                }
                // Already running: it kept its own nonce, and this one never reached it.
                let known = already?.processIdentifier == pid || nonces.contains { $0.key != nonce && $0.value == pid }
                nonces[nonce] = known ? nil : pid
                // It ignored the arguments (macOS only brought it forward): ask for the window.
                guard let already, already.processIdentifier == pid else { return }
                ask(window: window, pid: pid)
            }
        }
    }

    /// The helper's answer once it has opened the window: the same window and PID.
    static let windowAnswer = Notification.Name(ResumeRequest.appID + ".search.openedWindow")
    static let askEvery = 0.5
    static let askFor = 5.0

    /// Ask again while there is no answer: a helper still starting up has no window listening yet.
    /// Opening a window twice is harmless.
    static func shouldAsk(elapsed: Double, answered: Bool) -> Bool { !answered && elapsed < askFor }

    /// Asks every half second until the helper answers, for up to 5 s.
    private static func ask(window: String, pid: pid_t) {
        let center = DistributedNotificationCenter.default()
        var answered = false
        let observer = center.addObserver(forName: windowAnswer, object: nil, queue: .main) { note in
            if note.userInfo?["window"] as? String == window, (note.userInfo?["pid"] as? Int).map(pid_t.init) == pid { answered = true }
        }
        let start = Date()
        func tick() {
            guard shouldAsk(elapsed: Date().timeIntervalSince(start), answered: answered) else {
                center.removeObserver(observer)
                if !answered { AppLog.write("search: the helper did not answer the request for its \(window) window") }
                return
            }
            center.postNotificationName(windowNote, object: nil, userInfo: windowRequest(window, pid: pid), deliverImmediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + askEvery) { tick() }
        }
        tick()
    }

    // MARK: Gatekeeper

    /// At launch. A downloaded release carries the quarantine mark on every file; approving Claws
    /// (right-click → Open) lets Claws run, but the helper inside it may still be refused when it opens.
    /// Claws running means you approved the bundle that holds the helper, so the mark comes off the
    /// helper (only). Logged once when it does.
    static func clearQuarantine() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let r = Quarantine.clear(url)
        if r.removed > 0 { AppLog.write("search: removed the quarantine mark from \(r.removed) item(s) of the search helper") }
        if !r.failed.isEmpty { AppLog.write("search: could not remove the quarantine mark: \(r.failed.prefix(3).joined(separator: "; "))") }
    }

    /// No silent failure: say Search could not open, why, and how to unblock it.
    private static func couldNotOpen(_ error: Error?) {
        let command = unquarantineCommand(appPath: Bundle.main.bundlePath)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Search couldn't open"
        a.informativeText = failureText(error)
        let field = NSTextField(wrappingLabelWithString: command)
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.preferredMaxLayoutWidth = 360
        field.frame.size = field.fittingSize
        a.accessoryView = field
        a.addButton(withTitle: "Copy Command")
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    }

    static func failureText(_ error: Error?) -> String {
        let reason = error.map { $0.localizedDescription } ?? "macOS gave no reason."
        return reason + "\n\nIf macOS is blocking it as downloaded from the internet, run this in Terminal, then try again:"
    }

    /// `xattr -dr com.apple.quarantine "<app>"`, the path quoted for the shell.
    static func unquarantineCommand(appPath: String) -> String {
        var quoted = ""
        for c in appPath {
            if "\"\\$`".contains(c) { quoted.append("\\") }
            quoted.append(c)
        }
        return "xattr -dr \(Quarantine.name) \"\(quoted)\""
    }

    /// Main thread, once at launch.
    static func listen(tracker: Tracker) {
        DistributedNotificationCenter.default().addObserver(forName: ResumeRequest.note, object: nil, queue: .main) { note in
            guard let r = ResumeRequest(userInfo: note.userInfo) else {
                AppLog.write("search: ignored a resume request without a session ID, a plain folder and a nonce")
                return
            }
            resume(r, tracker: tracker)
        }
        // A helper that quits takes its nonce with it.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            nonces = nonces.filter { $0.value != app.processIdentifier }
        }
    }

    static func resume(_ r: ResumeRequest, tracker: Tracker) {
        let now = Date().timeIntervalSince1970
        let id = r.sessionId.prefix(8)
        let front = NSWorkspace.shared.frontmostApplication
        if let why = refusal(nonce: r.nonce, issued: nonces, front: front.map { ($0.bundleURL, $0.processIdentifier) }, helper: url) {
            AppLog.write("search: \(id) refused: \(why)")
            reply(r, .failed, why)
            return
        }
        guard !isStale(r, now: now) else {
            AppLog.write("search: \(id) refused: sent \(Int(now - r.sent)) s ago")
            reply(r, .failed, "That request is more than \(Int(ResumeRequest.maxAge)) s old.")
            return
        }
        let s = tracker.state(r.sessionId)
        if isRunning(s, hasPane: s.map { tracker.location($0).pane != nil } ?? false, now: now,
                     alive: { ProcInfo.isAlive(pid: $0, start: $1) }) {
            let terminal = tracker.terminalName(r.sessionId).map { $0 == "Other terminals" ? "" : " in \($0)" } ?? ""
            AppLog.write("search: \(id) is running: switching to it")
            tracker.open(r.sessionId)
            reply(r, .focused, "Still running: switched to it\(terminal).")
            return
        }
        // Ghostty for now: a session that is no longer running has no terminal on record.
        guard let a = Terminals.shared.adapter(id: "ghostty") else { reply(r, .failed, "No terminal can open a tab."); return }
        if let why = gate.begin(r.sessionId, now: now) { reply(r, .failed, why); return }
        reply(r, .opening, "Opening a new \(a.name) tab in \(abbreviate(r.folder))…")
        let template = Settings.resumeCommand, root = projects
        let deadline = Date(timeIntervalSince1970: r.sent + ResumeRequest.maxAge)
        // Reading the transcript back can take a moment for a big one: off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let folders = ProjectDirs.resumeFolders(r.sessionId, projects: root)
            DispatchQueue.main.async {
                switch plan(r, folders: folders, template: template) {
                case .refuse(let why):
                    gate.end(r.sessionId, opened: false, now: Date().timeIntervalSince1970)
                    AppLog.write("search: \(id) refused: not the folder its transcript names")
                    reply(r, .failed, why)
                case .newPane(let command):
                    AppLog.write("search: \(id) resuming in a new \(a.name) tab")
                    Terminals.shared.newPane(a, in: r.folder, typing: command, until: deadline) { ok in
                        gate.end(r.sessionId, opened: ok, now: Date().timeIntervalSince1970)
                        if ok { reply(r, .opened, "Resumed in a new \(a.name) tab: \(abbreviate(r.folder))"); return }
                        let why = Date() >= deadline ? "Gave up: \(a.name) was not ready within \(Int(ResumeRequest.maxAge)) s." : failure(a)
                        AppLog.write("search: \(id) new tab failed: \(why)")
                        reply(r, .failed, why)
                    }
                }
            }
        }
    }

    // MARK: Decisions (pure, for the self-test)

    /// nil when the request may go on, else why not: the nonce must be one we issued, and the Search
    /// window that got it must be the app in front.
    static func refusal(nonce: String, issued: [String: pid_t], front: (url: URL?, pid: pid_t)?, helper: URL) -> String? {
        let notOurs = "This Search window was not opened by this Claws for Concern: close it and open Search from the menu."
        guard let owner = issued[nonce] else { return notOurs }
        guard let front, front.url?.standardizedFileURL.path == helper.standardizedFileURL.path else {
            return "Resume works only from the Search window, while it is in front."
        }
        return owner == 0 || owner == front.pid ? nil : notOurs
    }

    static func isStale(_ r: ResumeRequest, now: Double) -> Bool { abs(now - r.sent) > ResumeRequest.maxAge }

    /// Its Claude process is alive. Without one on record (its file can then linger for 48 h), only if
    /// we know its pane or it was updated in the last 5 minutes.
    static func isRunning(_ s: SessionState?, hasPane: Bool, now: Double, alive: (Int32, Double?) -> Bool) -> Bool {
        guard let s else { return false }
        if let pid = s.claudePid { return alive(pid, s.claudeStart) }
        return hasPane || now - s.updatedTs < 300
    }

    enum Plan: Equatable {
        case newPane(command: String)
        case refuse(String)
    }

    /// A new tab only in a folder the session's transcript names (`ProjectDirs.resumeFolders`), and
    /// exactly that folder: the request's word for it is never trusted.
    static func plan(_ r: ResumeRequest, folders: [String], template: String) -> Plan {
        guard folders.contains(r.folder) else {
            return .refuse("Claude Code's transcript does not put this session in \(abbreviate(r.folder)).")
        }
        return .newPane(command: ResumeCommand.expand(template, id: r.sessionId))
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

/// The mark macOS puts on downloaded files (`com.apple.quarantine`), which makes Gatekeeper check an app
/// the first time it opens.
enum Quarantine {
    static let name = "com.apple.quarantine"

    /// Removes the mark from `url` and everything inside it, never following a link (so nothing outside
    /// is touched). Returns how many items had it, and what could not be cleared.
    static func clear(_ url: URL) -> (removed: Int, failed: [String]) {
        var removed = 0
        var failed: [String] = []
        func clearOne(_ path: String) {
            guard getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0 else { return }
            if removexattr(path, name, XATTR_NOFOLLOW) == 0 { removed += 1 } else { failed.append("\(path): \(String(cString: strerror(errno)))") }
        }
        clearOne(url.path)
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: nil)
        while let item = items?.nextObject() as? URL { clearOne(item.path) }
        return (removed, failed)
    }

    /// True if `url` or anything inside it carries the mark.
    static func present(_ url: URL) -> Bool {
        func has(_ path: String) -> Bool { getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
        if has(url.path) { return true }
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: nil)
        while let item = items?.nextObject() as? URL { if has(item.path) { return true } }
        return false
    }
}

/// One new tab per session at a time, and none again for 15 s after one opened (by then the resumed
/// session's hooks have usually reported it running, and a second request switches to it instead).
struct ResumeGate {
    static let cooldown = 15.0
    private(set) var inFlight = Set<String>()
    private(set) var opened: [String: Double] = [:]

    /// nil when a tab may open now (and the session is then in flight), else why not.
    mutating func begin(_ id: String, now: Double) -> String? {
        if inFlight.contains(id) { return "Already opening a tab for this session." }
        if let t = opened[id], now - t < Self.cooldown { return "A tab for this session opened a moment ago." }
        inFlight.insert(id)
        return nil
    }

    mutating func end(_ id: String, opened ok: Bool, now: Double) {
        inFlight.remove(id)
        if ok { opened[id] = now }
        opened = opened.filter { now - $0.value < Self.cooldown }
    }
}
