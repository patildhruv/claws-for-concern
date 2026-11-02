import AppKit

/// Ghostty over AppleScript. Ghostty 1.4+ reports each terminal's tty, the same tty the hook records
/// from the Claude process, so a session maps to its tab exactly. Ghostty 1.3 does not: then this
/// adapter learns panes from the tab you type a prompt into, then by folder and title (Claude Code
/// titles its tab "<status glyph> <session title>").
final class GhosttyAdapter: TerminalAdapter {
    let id = "ghostty"
    let name = "Ghostty"
    static let bundleID = "com.mitchellh.ghostty"
    /// The Ghostty the app drives: Ghostty itself, except under the CLI's `--bundle-id`, which tests
    /// use to drive a copy of Ghostty under its own bundle ID and never the one you work in.
    static var target = bundleID
    let scriptedBundleID: String?
    private let app: String
    var learnsPanes: Bool { true }
    var restoresPanes: Bool { true }
    private var lastFocused: PaneInfo?
    /// Written on the worker, read on the main thread by `paneID(for:)`.
    private var ttys = TTYMap()
    private let lock = NSLock()
    /// The Ghostty process that answered the old listing but not the one with `tty` (Ghostty 1.3).
    private var noTTY: pid_t?

    init(bundleID: String = GhosttyAdapter.bundleID) {
        app = bundleID
        scriptedBundleID = bundleID
    }

    func claims(_ s: SessionState) -> Bool {
        (s.env("TERM_PROGRAM") ?? s.termProgram) == "ghostty" || s.env("GHOSTTY_RESOURCES_DIR") != nil
    }

    /// The terminal on the session's tty, as of the adapter's last listings: no Apple Events here.
    func paneID(for s: SessionState) -> String? {
        lock.lock(); defer { lock.unlock() }
        return ttys.pane(tty: s.tty, since: s.claudeStart)
    }

    func lookedAt(front: FrontApp) -> Set<String> {
        lastFocused = front.bundleID == scriptedBundleID ? focusedTerminal() : nil
        if let f = lastFocused, f.tty != nil {
            lock.lock(); ttys.saw(f, at: Date().timeIntervalSince1970); lock.unlock()
        }
        return lastFocused.map { [$0.id] } ?? []
    }

    /// The poll calls `lookedAt` first; reuse its answer instead of asking Ghostty twice.
    func focusedPane(front: FrontApp) -> PaneInfo? {
        front.bundleID == scriptedBundleID ? lastFocused : nil
    }

    func panes() -> [PaneInfo] { list() ?? [] }

    /// Every terminal, or nil if Ghostty did not answer. Each listing refreshes the tty map.
    func list() -> [PaneInfo]? {
        let now = Date().timeIntervalSince1970
        if !ttyUnsupported, let l = listing(withTTY: true) {
            lock.lock(); ttys.list(l, at: now); lock.unlock()
            return l
        }
        guard let l = listing(withTTY: false) else { return nil }
        if !ttyUnsupported {
            noTTY = runningPID
            AppLog.write("ghostty: this version reports no tty; learning tabs instead")
        }
        return l
    }

    private var runningPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: app).first?.processIdentifier
    }

    private var ttyUnsupported: Bool { noTTY != nil && noTTY == runningPID }

    private func listing(withTTY: Bool) -> [PaneInfo]? {
        let props = withTTY ? "{id, working directory, name, tty, pid}" : "{id, working directory, name}"
        let src = """
        with timeout of 3 seconds
          tell application id \(Script.quote(app)) to get \(props) of every terminal
        end timeout
        """
        let columns = withTTY ? 5 : 3
        guard let d = Script.run(src, cacheKey: "ghostty.all.\(withTTY).\(app)"), d.numberOfItems == columns else { return nil }
        let cols = (1...columns).compactMap { d.atIndex($0) }
        guard cols.count == columns else { return nil }
        let n = cols[0].numberOfItems
        guard cols.allSatisfy({ $0.numberOfItems == n }) else { return nil }
        guard n > 0 else { return [] }
        return (1...n).compactMap { i in
            guard let id = cols[0].atIndex(i)?.stringValue else { return nil }
            var p = PaneInfo(id: id, cwd: cols[1].atIndex(i)?.stringValue ?? "", name: cols[2].atIndex(i)?.stringValue ?? "")
            if withTTY {
                p.tty = cols[3].atIndex(i)?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                let pid = cols[4].atIndex(i)?.int32Value ?? 0
                p.pid = pid > 0 ? pid : nil
            }
            return p
        }
    }

    func focus(paneID: String, session: SessionState) -> Bool {
        let safe = paneID.filter { $0.isHexDigit || $0 == "-" }
        return Script.run("""
        with timeout of 3 seconds
          tell application id \(Script.quote(app))
            focus (terminal id "\(safe)")
            activate
          end tell
        end timeout
        """) != nil
    }

    func health() -> AdapterHealth {
        Automation.healthFor(app, appName: "Ghostty",
                             ready: "Finds each session's tab, clears its Clawd when you look, and jumps there on click.")
    }

    // MARK: Restore

    /// Ghostty 1.4+ only: whether a shell is idle in a terminal comes from its foreground `pid`.
    func restorablePanes() -> [RestorePane]? {
        guard let l = list(), !ttyUnsupported else { return nil }
        return l.map { RestorePane.from(id: $0.id, cwd: $0.cwd, foregroundPid: $0.pid) }
    }

    func type(_ command: String, into paneID: String) -> Bool {
        Script.run(GhosttyAdapter.typeScript(app: app, terminal: paneID, command: command))?.stringValue == "ok"
    }

    static func typeScript(app: String, terminal: String, command: String) -> String {
        let safe = terminal.filter { $0.isHexDigit || $0 == "-" }
        return """
        with timeout of 3 seconds
          tell application id \(Script.quote(app))
            set t to terminal id "\(safe)"
            input text \(Script.quote(command)) to t
            send key "enter" to t
          end tell
        end timeout
        return "ok"
        """
    }

    /// Ghostty brings its tabs back after quitting only with `window-save-state = always`; the
    /// default follows macOS's "Close windows when quitting an application", which is on by default.
    func restoreProblem() -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { return nil }
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        if let v = info?["CFBundleShortVersionString"] as? String, GhosttyAdapter.isBefore(v, [1, 4]) {
            return "Restore needs Ghostty 1.4 or later to find the tabs it reopens (this is \(v))."
        }
        let cli = url.appendingPathComponent("Contents/MacOS/ghostty").path
        guard let r = Command.run(cli, ["+show-config", "--no-pager"], timeout: 3), r.status == 0 else { return nil }
        let value = GhosttyAdapter.saveState(r.out) ?? "default"
        return value == "always" ? nil
            : "Ghostty reopens its tabs after quitting only with window-save-state = always in its config (it is \(value))."
    }

    /// `window-save-state` from `ghostty +show-config` (which prints only what differs from the default).
    static func saveState(_ config: String) -> String? {
        for line in config.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "window-save-state" { return parts[1] }
        }
        return nil
    }

    /// "1.3.1" is before [1, 4]; "1.4.0" and "1.10" are not.
    static func isBefore(_ version: String, _ minimum: [Int]) -> Bool {
        let v = version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for (i, m) in minimum.enumerated() {
            let x = i < v.count ? v[i] : 0
            if x != m { return x < m }
        }
        return false
    }

    private func focusedTerminal() -> PaneInfo? {
        if !ttyUnsupported, let s = Script.run(focusedScript(withTTY: true), cacheKey: "ghostty.focused.true.\(app)")?.stringValue {
            let p = s.components(separatedBy: "\t")
            return p.count >= 4 ? PaneInfo(id: p[0], cwd: p[1], name: p[3...].joined(separator: "\t"), tty: p[2].isEmpty ? nil : p[2]) : nil
        }
        guard let s = Script.run(focusedScript(withTTY: false), cacheKey: "ghostty.focused.false.\(app)")?.stringValue else { return nil }
        let p = s.components(separatedBy: "\t")
        return p.count >= 3 ? PaneInfo(id: p[0], cwd: p[1], name: p[2...].joined(separator: "\t")) : nil
    }

    private func focusedScript(withTTY: Bool) -> String {
        // `tab` is a Ghostty class, so the tab character is bound outside the tell block. The title
        // goes last: it may contain anything.
        let fields = withTTY ? "(id of t) & sep & (working directory of t) & sep & (tty of t) & sep & (name of t)"
            : "(id of t) & sep & (working directory of t) & sep & (name of t)"
        return """
        set sep to tab
        with timeout of 2 seconds
          tell application id \(Script.quote(app))
            if (count of windows) is 0 then return ""
            set t to focused terminal of selected tab of front window
            return \(fields)
          end tell
        end timeout
        """
    }
}

/// Ghostty terminals by tty, from the listings the adapter makes anyway, so `paneID(for:)` answers
/// on the main thread without asking Ghostty. Pure, for the self-test.
struct TTYMap {
    struct Seen: Equatable { let id: String; let at: Double }
    private(set) var byTTY: [String: Seen] = [:]

    /// A full listing replaces the map: a terminal missing from it is gone.
    mutating func list(_ panes: [PaneInfo], at t: Double) {
        byTTY = [:]
        for p in panes { if let tty = p.tty { byTTY[tty] = Seen(id: p.id, at: t) } }
    }

    /// One terminal seen now (the focused one).
    mutating func saw(_ p: PaneInfo, at t: Double) {
        guard let tty = p.tty else { return }
        byTTY = byTTY.filter { $0.value.id != p.id }
        byTTY[tty] = Seen(id: p.id, at: t)
    }

    /// A tty is reused once its terminal closes, so only a sighting made after the session's Claude
    /// process started names that session's terminal.
    func pane(tty: String?, since start: Double?) -> String? {
        guard let tty, let s = byTTY[tty], s.at >= (start ?? 0) else { return nil }
        return s.id
    }
}


/// Everything else (VS Code, Warp, Zed, Alacritty…): no pane-level control, but a click still brings
/// forward the app hosting the session, found by walking up from its Claude process.
final class HostAppAdapter: TerminalAdapter {
    let id = "app"
    let name = "Other terminals"

    func claims(_ s: SessionState) -> Bool { true }
    func lookedAt(front: FrontApp) -> Set<String> { [] }

    func focus(paneID: String, session: SessionState) -> Bool {
        if let pid = session.claudePid, let app = HostApp.of(pid: pid) {
            DispatchQueue.main.async { app.activate() }
            return true
        }
        // A daemonised multiplexer has no GUI ancestor: fall back to the terminal it was started from.
        let bundle: String? = ["ghostty": "com.mitchellh.ghostty", "Apple_Terminal": "com.apple.Terminal",
                               "iTerm.app": "com.googlecode.iterm2", "WarpTerminal": "dev.warp.Warp-Stable",
                               "vscode": "com.microsoft.VSCode"][session.env("TERM_PROGRAM") ?? session.termProgram ?? ""]
        if let bundle, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            DispatchQueue.main.async { app.activate() }
            return true
        }
        return false
    }

    func health() -> AdapterHealth {
        AdapterHealth(level: .ready, detail: "Clicking brings the terminal or editor forward. A Clawd clears when you prompt that session or dismiss it.")
    }
}

// MARK: - New tabs (Search resumes a session that is no longer open)

extension GhosttyAdapter {
    /// A new tab in the front window (a new window when there is none) in `dir`, with `command` typed
    /// into its shell: typed rather than run, so the user's aliases apply and the tab stays open after.
    /// Never types into an existing terminal.
    static func newPaneScript(in dir: String, typing command: String) -> String {
        """
        with timeout of 5 seconds
          tell application id "com.mitchellh.ghostty"
            set cfg to {initial working directory:\(Script.quote(dir)), initial input:\(Script.quote(command)) & linefeed}
            if (count of windows) > 0 then
              new tab in front window with configuration cfg
            else
              new window with configuration cfg
            end if
            activate
          end tell
        end timeout
        """
    }

    func newPane(in dir: String, typing command: String) -> Bool {
        Script.run(GhosttyAdapter.newPaneScript(in: dir, typing: command)) != nil
    }
}
