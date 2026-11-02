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
    /// Whether this Ghostty process reports `tty` and `pid` (worker only).
    private var ttySupport: (pid: pid_t, ok: Bool)?
    private var problemCache: (stamp: String, problem: String?)?

    init(bundleID: String = GhosttyAdapter.bundleID) {
        app = bundleID
        scriptedBundleID = bundleID
    }

    func claims(_ s: SessionState) -> Bool {
        (s.env("TERM_PROGRAM") ?? s.termProgram) == "ghostty" || s.env("GHOSTTY_RESOURCES_DIR") != nil
    }

    /// The terminal on the session's tty, as of the adapter's last listings: no Apple Events here.
    /// Only a sighting in the Ghostty process the session runs under counts: after a relaunch, its
    /// old tty may belong to someone else's tab.
    func paneID(for s: SessionState) -> String? {
        lock.lock(); defer { lock.unlock() }
        return ttys.pane(tty: s.tty, since: s.claudeStart, host: s.hostPid)
    }

    func lookedAt(front: FrontApp) -> Set<String> {
        let g = ready
        lastFocused = front.bundleID == scriptedBundleID && g != nil ? focusedTerminal() : nil
        if let f = lastFocused, f.tty != nil, let g {
            lock.lock(); ttys.saw(f, at: Date().timeIntervalSince1970, host: g.processIdentifier); lock.unlock()
        }
        return lastFocused.map { [$0.id] } ?? []
    }

    /// The poll calls `lookedAt` first; reuse its answer instead of asking Ghostty twice.
    func focusedPane(front: FrontApp) -> PaneInfo? {
        front.bundleID == scriptedBundleID ? lastFocused : nil
    }

    func panes() -> [PaneInfo] { list() ?? [] }

    /// Ghostty, running and done launching. Never script it otherwise: telling an app that is not
    /// running anything launches it.
    private var ready: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: app).first { !$0.isTerminated && $0.isFinishedLaunching }
    }

    /// Whether this Ghostty process reports `tty` and `pid`: from its version (1.4+); nil while
    /// unknown, which a listing then settles. Never decided by a timeout.
    private func hasTTY(_ g: NSRunningApplication) -> Bool? {
        if let s = ttySupport, s.pid == g.processIdentifier { return s.ok }
        guard let url = g.bundleURL,
              let v = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String,
              !v.isEmpty else { return nil }
        ttySupport = (g.processIdentifier, !GhosttyAdapter.isBefore(v, [1, 4]))
        return ttySupport?.ok
    }

    /// Every terminal, or nil if Ghostty did not answer (or is not running). Each listing refreshes
    /// the tty map.
    func list() -> [PaneInfo]? {
        guard let g = ready else { return nil }
        if hasTTY(g) != false {
            let (l, error) = listing(withTTY: true)
            if let l {
                ttySupport = (g.processIdentifier, true)
                lock.lock(); ttys.list(l, at: Date().timeIntervalSince1970, host: g.processIdentifier); lock.unlock()
                return l
            }
            // Only a term its dictionary lacks means Ghostty 1.3; a timeout or a busy app means nothing.
            guard error == Script.undefinedTerm else { return nil }
            ttySupport = (g.processIdentifier, false)
            AppLog.write("ghostty: this version reports no tty; learning tabs instead")
        }
        return listing(withTTY: false).panes
    }

    /// Every script runs inside `if application id … is running`: `ready` reads NSRunningApplication
    /// off the main thread, which can lag a quit, and telling a quit app anything launches it again.
    static func guarded(_ app: String, _ body: String) -> String {
        """
        if application id \(Script.quote(app)) is running then
        \(body)
        end if
        """
    }

    static func listingScript(app: String, withTTY: Bool) -> String {
        let props = withTTY ? "{id, working directory, name, tty, pid}" : "{id, working directory, name}"
        return guarded(app, """
        with timeout of 3 seconds
          tell application id \(Script.quote(app)) to return \(props) of every terminal
        end timeout
        """)
    }

    private func listing(withTTY: Bool) -> (panes: [PaneInfo]?, error: Int?) {
        let src = GhosttyAdapter.listingScript(app: app, withTTY: withTTY)
        let columns = withTTY ? 5 : 3
        let r = Script.attempt(src, cacheKey: "ghostty.all.\(withTTY).\(app)")
        guard let d = r.result, d.numberOfItems == columns else { return (nil, r.error) }
        let cols = (1...columns).compactMap { d.atIndex($0) }
        guard cols.count == columns else { return (nil, nil) }
        let n = cols[0].numberOfItems
        guard cols.allSatisfy({ $0.numberOfItems == n }) else { return (nil, nil) }
        guard n > 0 else { return ([], nil) }
        return ((1...n).compactMap { i in
            guard let id = cols[0].atIndex(i)?.stringValue else { return nil }
            var p = PaneInfo(id: id, cwd: cols[1].atIndex(i)?.stringValue ?? "", name: cols[2].atIndex(i)?.stringValue ?? "")
            if withTTY {
                p.tty = cols[3].atIndex(i)?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                let pid = cols[4].atIndex(i)?.int32Value ?? 0
                p.pid = pid > 0 ? pid : nil
            }
            return p
        }, nil)
    }

    func focus(paneID: String, session: SessionState) -> Bool {
        Script.run(GhosttyAdapter.focusScript(app: app, terminal: paneID))?.stringValue == "ok"
    }

    static func focusScript(app: String, terminal: String) -> String {
        let safe = terminal.filter { $0.isHexDigit || $0 == "-" }
        return guarded(app, """
        with timeout of 3 seconds
          tell application id \(Script.quote(app))
            focus (terminal id "\(safe)")
            activate
          end tell
        end timeout
        return "ok"
        """)
    }

    func health() -> AdapterHealth {
        Automation.healthFor(app, appName: "Ghostty",
                             ready: "Finds each session's tab, clears its Clawd when you look, and jumps there on click.")
    }

    // MARK: Restore

    /// Ghostty 1.4+ only (`tty` and `pid`): whether the tab's own shell waits at its prompt comes from
    /// the kernel's view of its foreground process.
    func restorablePanes(app pid: Int32?) -> [RestorePane]? {
        guard let g = ready, GhosttyAdapter.sameProcess(g.processIdentifier, pid), let l = list(), hasTTY(g) == true else { return nil }
        return l.map { RestorePane.from(id: $0.id, tty: $0.tty, foregroundPid: $0.pid, hostPid: g.processIdentifier) }
    }

    func type(_ command: String, into paneID: String, app pid: Int32, ifForeground shell: Int32, deferIfFocused: Bool) -> TypeResult {
        // A job queued before a quit and relaunch must not type into the new Ghostty.
        guard let g = ready, GhosttyAdapter.sameProcess(g.processIdentifier, pid) else { return .moved }
        let r = Script.attempt(GhosttyAdapter.typeScript(app: app, terminal: paneID, shell: shell, deferIfFocused: deferIfFocused, command: command))
        return TypeResult.from(script: r.result?.stringValue, error: r.error)
    }

    /// `expected` nil accepts any Ghostty process.
    static func sameProcess(_ running: Int32, _ expected: Int32?) -> Bool { expected == nil || running == expected }

    /// One script, so nothing can change between its checks and its keys: "moved" (nothing sent) unless
    /// `shell` is still the tab's foreground process; with `deferIfFocused` (you typed a moment ago),
    /// "busy" (nothing sent) while Ghostty is in front with that tab focused. Then Ctrl-E and Ctrl-U
    /// (each pressed and released: bash and fish kill only what is left of the cursor), the command as
    /// if pasted, Return, and "ok". "gone": Ghostty is not running. An error part way may have sent keys.
    static func typeScript(app: String, terminal: String, shell: Int32, deferIfFocused: Bool, command: String) -> String {
        let safe = terminal.filter { $0.isHexDigit || $0 == "-" }
        let focusCheck = deferIfFocused ? """
            if frontmost then
              if (count of windows) > 0 then
                if (id of focused terminal of selected tab of front window) is "\(safe)" then return "busy"
              end if
            end if
        """ : ""
        return guarded(app, """
        with timeout of 3 seconds
          tell application id \(Script.quote(app))
            set t to terminal id "\(safe)"
            if (pid of t) is not \(shell) then return "moved"
        \(focusCheck)
            send key "e" action press modifiers "control" to t
            send key "e" action release modifiers "control" to t
            send key "u" action press modifiers "control" to t
            send key "u" action release modifiers "control" to t
            input text \(Script.quote(command)) to t
            send key "enter" to t
          end tell
        end timeout
        return "ok"
        """) + "\nreturn \"gone\""
    }

    /// Ghostty brings its tabs back after quitting only with `window-save-state = always`; the
    /// default follows macOS's "Close windows when quitting an application", which is on by default.
    /// `ghostty +show-config` runs again only when the version or a config file changes.
    func restoreProblem() -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { return nil }
        let version = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
        if let version, GhosttyAdapter.isBefore(version, [1, 4]) {
            return "Restore needs Ghostty 1.4 or later to find the tabs it reopens (this is \(version))."
        }
        let stamp = (version ?? "") + "|" + GhosttyAdapter.configFiles().map { f in
            ((try? FileManager.default.attributesOfItem(atPath: f))?[.modificationDate] as? Date).map { "\($0.timeIntervalSince1970)" } ?? "-"
        }.joined(separator: "|")
        if let c = problemCache, c.stamp == stamp { return c.problem }
        let cli = url.appendingPathComponent("Contents/MacOS/ghostty").path
        let problem: String?
        if let r = Command.run(cli, ["+show-config", "--no-pager"], timeout: 3), r.status == 0 {
            let value = GhosttyAdapter.saveState(r.out) ?? "default"
            problem = value == "always" ? nil
                : "Ghostty reopens its tabs after quitting only with window-save-state = always in its config (it is \(value))."
        } else {
            problem = nil  // Ghostty's own tool failed: say nothing, and do not run it again until something changes
        }
        problemCache = (stamp, problem)
        return problem
    }

    /// Where Ghostty reads its config (files it includes with `config-file` are not watched).
    static func configFiles() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.config"
        let support = "\(home)/Library/Application Support/com.mitchellh.ghostty"
        return ["\(xdg)/ghostty/config", "\(xdg)/ghostty/config.ghostty", "\(support)/config", "\(support)/config.ghostty"]
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
        guard let g = ready else { return nil }
        if hasTTY(g) == true {
            guard let s = Script.run(GhosttyAdapter.focusedScript(app: app, withTTY: true), cacheKey: "ghostty.focused.true.\(app)")?.stringValue
            else { return nil }
            let p = s.components(separatedBy: "\t")
            return p.count >= 4 ? PaneInfo(id: p[0], cwd: p[1], name: p[3...].joined(separator: "\t"), tty: p[2].isEmpty ? nil : p[2]) : nil
        }
        guard let s = Script.run(GhosttyAdapter.focusedScript(app: app, withTTY: false), cacheKey: "ghostty.focused.false.\(app)")?.stringValue
        else { return nil }
        let p = s.components(separatedBy: "\t")
        return p.count >= 3 ? PaneInfo(id: p[0], cwd: p[1], name: p[2...].joined(separator: "\t")) : nil
    }

    static func focusedScript(app: String, withTTY: Bool) -> String {
        // `tab` is a Ghostty class, so the tab character is bound outside the tell block. The title
        // goes last: it may contain anything.
        let fields = withTTY ? "(id of t) & sep & (working directory of t) & sep & (tty of t) & sep & (name of t)"
            : "(id of t) & sep & (working directory of t) & sep & (name of t)"
        return guarded(app, """
        set sep to tab
        with timeout of 2 seconds
          tell application id \(Script.quote(app))
            if (count of windows) is 0 then return ""
            set t to focused terminal of selected tab of front window
            return \(fields)
          end tell
        end timeout
        """)
    }
}

/// Ghostty terminals by tty, from the listings the adapter makes anyway, so `paneID(for:)` answers
/// on the main thread without asking Ghostty. Pure, for the self-test.
struct TTYMap {
    struct Seen: Equatable { let id: String; let at: Double; let host: Int32 }
    private(set) var byTTY: [String: Seen] = [:]

    /// A full listing replaces the map: a terminal missing from it is gone. `host`: the Ghostty
    /// process that answered.
    mutating func list(_ panes: [PaneInfo], at t: Double, host: Int32) {
        byTTY = [:]
        for p in panes { if let tty = p.tty { byTTY[tty] = Seen(id: p.id, at: t, host: host) } }
    }

    /// One terminal seen now (the focused one).
    mutating func saw(_ p: PaneInfo, at t: Double, host: Int32) {
        guard let tty = p.tty else { return }
        byTTY = byTTY.filter { $0.value.id != p.id }
        byTTY[tty] = Seen(id: p.id, at: t, host: host)
    }

    /// A tty is reused once its terminal closes, so only a sighting made after the session's Claude
    /// process started, by the Ghostty process the session runs under, names that session's terminal.
    /// A dead session's tty may belong to another tab of a relaunched Ghostty.
    func pane(tty: String?, since start: Double?, host: Int32?) -> String? {
        guard let tty, let host, let s = byTTY[tty], s.host == host, s.at >= (start ?? 0) else { return nil }
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
    static func newPaneScript(app: String, in dir: String, typing command: String) -> String {
        // `Terminals.newPane` launched Ghostty first; a quit since must not relaunch it.
        guarded(app, """
        with timeout of 5 seconds
          tell application id \(Script.quote(app))
            set cfg to {initial working directory:\(Script.quote(dir)), initial input:\(Script.quote(command)) & linefeed}
            if (count of windows) > 0 then
              new tab in front window with configuration cfg
            else
              new window with configuration cfg
            end if
            activate
          end tell
        end timeout
        return "ok"
        """)
    }

    func newPane(in dir: String, typing command: String) -> Bool {
        Script.run(GhosttyAdapter.newPaneScript(app: app, in: dir, typing: command))?.stringValue == "ok"
    }
}
