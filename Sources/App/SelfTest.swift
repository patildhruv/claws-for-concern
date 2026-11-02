import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `--selftest`: checks the parts that can go wrong without a GUI. Prints ALL PASS or exits 1.
enum SelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print((ok ? "PASS " : "FAIL ") + name + (ok ? "" : "  — " + detail()))
        if !ok { failures += 1 }
    }

    static func run() -> Int32 {
        hookTransitions()
        geometry()
        terminals()
        restore()
        orderedJSON()
        installer()
        text()
        art()
        search()
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    private static func ev(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var e: [String: Any] = ["hook_event_name": name, "session_id": "t1", "cwd": "/w", "transcript_path": "/t.jsonl"]
        e.merge(extra) { $1 }
        return e
    }

    static func hookTransitions() {
        var s: SessionState?
        var t = 1000.0
        func apply(_ e: [String: Any]) -> HookEvent.Outcome { t += 1; return HookEvent.apply(e, to: &s, now: t) }
        check("start writes idle", apply(ev("SessionStart", ["source": "startup"])) == .write && s?.status == .idle)
        check("prompt -> working", apply(ev("UserPromptSubmit", ["prompt": "hi"])) == .write && s?.status == .working && s?.promptTs == t)
        _ = apply(ev("PreToolUse", ["tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": "Which DB?",
                    "options": [["label": "Postgres"], ["label": "SQLite"]]]]]]))
        check("question -> blocked", s?.status == .blocked && s?.blockedKind == "question" && s?.detail == "Which DB? [Postgres / SQLite]",
              String(describing: s?.detail))
        check("answer -> working", apply(ev("PostToolUse", ["tool_name": "AskUserQuestion"])) == .write && s?.status == .working)
        check("other tool is a no-op", apply(ev("PostToolUse", ["tool_name": "Bash"])) == .ignore)
        _ = apply(ev("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build\necho done"]]))
        check("permission detail", s?.blockedKind == "permission" && s?.detail == "Bash: rm -rf build", String(describing: s?.detail))
        check("duplicate permission notification ignored",
              apply(ev("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission"])) == .ignore)
        check("idle_prompt ignored", apply(ev("Notification", ["notification_type": "idle_prompt"])) == .ignore)
        _ = apply(ev("Stop", ["last_assistant_message": "All done.", "background_tasks": []]))
        check("stop -> finished", s?.status == .finished && s?.lastMessage == "All done." && s?.blockedKind == nil)
        _ = apply(ev("UserPromptSubmit"))
        _ = apply(ev("Stop", ["last_assistant_message": "Waiting on agents", "background_tasks": [["type": "subagent", "status": "running"]]]))
        check("stop with subagents -> background", s?.status == .background)
        _ = apply(ev("Stop", ["last_assistant_message": "dev server up", "background_tasks": [["type": "shell", "status": "running"]]]))
        check("stop with a shell task -> finished", s?.status == .finished)
        _ = apply(ev("StopFailure", ["error": "rate_limit", "last_assistant_message": "API Error: Rate limit reached"]))
        check("failure detail", s?.status == .failed && s?.detail == "API Error: Rate limit reached")
        var stale = s
        check("older event dropped", HookEvent.apply(ev("UserPromptSubmit"), to: &stale, now: 5) == .ignore && stale?.status == .failed)
        check("compact keeps status", apply(ev("SessionStart", ["source": "compact"])) != .write || s?.status == .failed)
        check("/exit deletes", apply(ev("SessionEnd", ["reason": "prompt_input_exit"])) == .delete)
        // Ownership: a child `claude` that inherited the session ID must not touch the session.
        var owned: SessionState?
        _ = HookEvent.apply(ev("SessionStart", ["source": "startup", "cwd": "/drifted"]), to: &owned, now: 1, pid: 100,
                            pidStart: 5, processCwd: "/launch", isAlive: { _, _ in true })
        check("root folder comes from the process", owned?.rootCwd == "/launch" && owned?.cwd == "/drifted")
        check("child Stop ignored while owner lives",
              HookEvent.apply(ev("Stop", ["last_assistant_message": "x"]), to: &owned, now: 2, pid: 200,
                              isAlive: { _, _ in true }) == .ignore && owned?.status == .idle)
        check("child SessionEnd ignored", HookEvent.apply(ev("SessionEnd"), to: &owned, now: 3, pid: 200,
                                                          isAlive: { _, _ in true }) == .ignore)
        check("resume in a new process takes over",
              HookEvent.apply(ev("UserPromptSubmit"), to: &owned, now: 4, pid: 300, processCwd: "/again",
                              isAlive: { _, _ in false }) == .write && owned?.claudePid == 300 && owned?.rootCwd == "/again")
        var none: SessionState?
        check("missing session id ignored", HookEvent.apply(["hook_event_name": "Stop"], to: &none, now: 1) == .ignore && none == nil)
    }

    static func terminals() {
        func session(_ env: [String: String], tty: String? = nil) -> SessionState {
            var st = SessionState(sessionId: "x", cwd: "/w")
            st.terminal = TerminalContext.capture(env)
            st.tty = tty
            st.termProgram = env["TERM_PROGRAM"]
            return st
        }
        let t = Terminals.shared
        let ghostty = session(["TERM_PROGRAM": "ghostty", "GHOSTTY_RESOURCES_DIR": "/Applications/Ghostty.app/Contents/Resources/ghostty"])
        let tmuxInGhostty = session(["TERM_PROGRAM": "tmux", "GHOSTTY_RESOURCES_DIR": "/x", "TMUX": "/private/tmp/tmux-501/default,123,0", "TMUX_PANE": "%7"])
        let cmux = session(["TERM_PROGRAM": "ghostty", "GHOSTTY_RESOURCES_DIR": "/Applications/cmux.app/x",
                            "CMUX_WORKSPACE_ID": "WS-1", "CMUX_SURFACE_ID": "SF-2", "CMUX_SOCKET_CAPABILITY": "v1.secret",
                            "CMUX_SOCKET_PASSWORD": "hunter2"])
        let herdr = session(["TERM_PROGRAM": "ghostty", "HERDR_PANE_ID": "w1:p3", "HERDR_SOCKET_PATH": "/s/herdr.sock"])
        let iterm = session(["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t1p0:ABC"], tty: "/dev/ttys004")
        let apple = session(["TERM_PROGRAM": "Apple_Terminal", "TERM_SESSION_ID": "A1"], tty: "/dev/ttys009")
        let vscode = session(["TERM_PROGRAM": "vscode"])
        check("terminal: Ghostty", t.adapter(for: ghostty).id == "ghostty")
        check("terminal: tmux inside Ghostty is tmux's", t.adapter(for: tmuxInGhostty).id == "tmux")
        check("terminal: cmux, though it says TERM_PROGRAM=ghostty", t.adapter(for: cmux).id == "cmux")
        check("terminal: herdr", t.adapter(for: herdr).id == "herdr")
        check("terminal: iTerm2", t.adapter(for: iterm).id == "iterm2")
        check("terminal: Terminal.app", t.adapter(for: apple).id == "terminal")
        check("terminal: anything else falls back to its app", t.adapter(for: vscode).id == "app")
        check("pane: tmux socket|pane", t.adapter(for: tmuxInGhostty).paneID(for: tmuxInGhostty) == "/private/tmp/tmux-501/default|%7")
        check("pane: cmux workspace|surface", t.adapter(for: cmux).paneID(for: cmux) == "WS-1|SF-2")
        check("pane: herdr socket|pane", t.adapter(for: herdr).paneID(for: herdr) == "/s/herdr.sock|w1:p3")
        check("pane: iTerm2 and Terminal by tty", t.adapter(for: iterm).paneID(for: iterm) == "/dev/ttys004"
              && t.adapter(for: apple).paneID(for: apple) == "/dev/ttys009")
        check("pane: Ghostty learns", t.adapter(for: ghostty).paneID(for: ghostty) == nil && t.adapter(for: ghostty).learnsPanes)
        check("context: secrets never captured", cmux.terminal?["CMUX_SOCKET_CAPABILITY"] == nil && cmux.terminal?["CMUX_SOCKET_PASSWORD"] == nil
              && cmux.terminal?["CMUX_SURFACE_ID"] == "SF-2")
        check("context: unknown variables dropped", TerminalContext.capture(["PATH": "/bin", "HOME": "/Users/x"]).isEmpty)
        check("adapter ids unique", Set(t.adapters.map(\.id)).count == t.adapters.count)

        // An unanswered permission prompt must not hold up the other terminals.
        let prompt = DispatchSemaphore(value: 0), polled = DispatchSemaphore(value: 0)
        t.prompter.run { prompt.wait() }
        t.worker.run { polled.signal() }
        check("permission prompt does not block polling", polled.wait(timeout: .now() + 1) == .success)
        prompt.signal()
        let fake = "io.example.claws.not-installed"
        let first = Automation.startAsking(fake), second = Automation.startAsking(fake)
        let whileAsking = Automation.refresh(fake)
        Automation.doneAsking(fake)
        check("permission: one prompt per app; no check while it is up",
              first && !second && whileAsking == .undetermined && Automation.refresh(fake) == .notRunning)

        // Compiling an AppleScript reads the app's dictionary without sending it anything: no prompt.
        for (app, bundle, source) in [
            ("Ghostty", "com.mitchellh.ghostty", "tell application id \"com.mitchellh.ghostty\" to get {id, working directory, name} of every terminal"),
            ("Terminal", "com.apple.Terminal", "tell application id \"com.apple.Terminal\" to get tty of selected tab of front window"),
            ("iTerm2", "com.googlecode.iterm2", "tell application id \"com.googlecode.iterm2\" to get tty of current session of current window"),
            ("Ghostty (tty, pid)", "com.mitchellh.ghostty",
             "tell application id \"com.mitchellh.ghostty\" to get {id, working directory, name, tty, pid} of every terminal"),
            ("Ghostty (type a command)", "com.mitchellh.ghostty",
             GhosttyAdapter.typeScript(app: "com.mitchellh.ghostty", terminal: "AB12-CD34", shell: 4242, deferIfFocused: true,
                                       command: "claude --resume \"x\" \\ y")),
            ("Terminal (jump)", "com.apple.Terminal", AppleTerminalAdapter.focusScript(tty: "/dev/ttys001")),
            ("iTerm2 (jump)", "com.googlecode.iterm2", ITermAdapter.focusScript(tty: "/dev/ttys001")),
        ] where NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil {
            var err: NSDictionary?
            check("applescript compiles against \(app)'s dictionary", NSAppleScript(source: source)?.compileAndReturnError(&err) == true,
                  String(describing: err))
        }
    }

    static func restore() {
        // The hook: why a session ended decides whether it is kept for a restore.
        let alive: (Int32, Double?) -> Bool = { _, _ in true }
        var s: SessionState?
        _ = HookEvent.apply(ev("SessionStart", ["source": "startup"]), to: &s, now: 1, pid: 100, pidStart: 5, isAlive: alive)
        let started = s
        check("hook: quitting the terminal keeps the session, marked ended",
              HookEvent.apply(ev("SessionEnd", ["reason": "other"]), to: &s, now: 2, pid: 100, isAlive: alive) == .write
                && s?.endReason == "other" && s?.endedTs == 2)
        for reason in ["prompt_input_exit", "clear", "resume", "logout"] {
            var d = started
            check("hook: \(reason) deletes", HookEvent.apply(ev("SessionEnd", ["reason": reason]), to: &d, now: 2, pid: 100, isAlive: alive) == .delete)
        }
        var noReason = started
        check("hook: a SessionEnd without a reason keeps it",
              HookEvent.apply(ev("SessionEnd"), to: &noReason, now: 2, pid: 100, isAlive: alive) == .write && noReason?.endReason == "unknown")
        var late = s
        check("hook: a late event from the ended process is ignored",
              HookEvent.apply(ev("Stop", ["last_assistant_message": "x"]), to: &late, now: 3, pid: 100, isAlive: alive) == .ignore && late?.endedTs == 2)
        var back = s
        check("hook: /resume back into it from the same process revives it",
              HookEvent.apply(ev("SessionStart", ["source": "resume"]), to: &back, now: 4, pid: 100, isAlive: alive) == .write
                && back?.endedTs == nil && back?.endReason == nil && back?.status == .idle)
        var resumed = s
        check("hook: a resume in a new process revives it",
              HookEvent.apply(ev("UserPromptSubmit"), to: &resumed, now: 4, pid: 300, isAlive: { _, _ in false }) == .write
                && resumed?.endedTs == nil && resumed?.claudePid == 300)
        let saved = (try? JSONEncoder().encode(s)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("hook: ended fields on disk", saved.contains("\"end_reason\":\"other\"") && saved.contains("\"ended_ts\":2"), saved)
        var hosted: SessionState?
        _ = HookEvent.apply(ev("SessionStart", ["source": "startup"]), to: &hosted, now: 1, pid: 100, pidStart: 5, host: (900, 0.5), isAlive: alive)
        check("hook: records the terminal process the session runs under", hosted?.hostPid == 900 && hosted?.hostStart == 0.5)
        _ = HookEvent.apply(ev("UserPromptSubmit"), to: &hosted, now: 2, pid: 100, pidStart: 5, host: (777, 3), isAlive: alive)
        check("hook: a later event of the same process never rewrites the host (an orphan's late event)",
              hosted?.hostPid == 900 && hosted?.hostStart == 0.5)
        _ = HookEvent.apply(ev("SessionStart", ["source": "resume"]), to: &hosted, now: 3, pid: 300, pidStart: 6, host: (901, 2.5),
                            isAlive: { _, _ in false })
        check("hook: a new Claude process (a resume) records its own host", hosted?.hostPid == 901 && hosted?.hostStart == 2.5)
        var orphan: SessionState?
        _ = HookEvent.apply(ev("SessionStart", ["source": "startup"]), to: &orphan, now: 1, pid: 100, pidStart: 5, host: (100, 5), isAlive: alive)
        check("hook: a Claude process with no terminal above it is never its own host", orphan?.hostPid == nil && orphan?.hostStart == nil)
        check("hook: the terminal process of this test is found", ProcInfo.hostAncestor(of: getpid()).map { $0.ppid <= 1 } == true)

        // The ledger: IDs, one entry per pane and session, expiry, the lock.
        func uuid(_ n: Int) -> String { String(format: "%08d-0000-4000-8000-000000000000", n) }
        func entry(_ n: Int, _ pane: String, _ ended: Double, folder: String = "/w/p", host: Int32? = 900) -> RestoreEntry {
            RestoreEntry(sessionId: uuid(n), adapter: "ghostty", pane: pane, folder: folder, title: "T\(n)", endedTs: ended, reason: "other",
                         hostPid: host, hostStart: 0.5)
        }
        var l = RestoreLedger()
        [entry(1, "P1", 10), entry(2, "P2", 10), entry(3, "P1", 20), entry(4, "P2", 5)].forEach { l.add($0) }
        check("ledger: one entry per pane, the last session to end there wins", l.entries.map(\.sessionId).sorted() == [uuid(2), uuid(3)])
        l.add(entry(2, "P3", 30))
        check("ledger: one entry per session", l.entries.filter { $0.sessionId == uuid(2) }.map(\.pane) == ["P3"])
        var old = l
        old.expire(now: 20 + RestoreLedger.maxAge + 1)
        check("ledger: entries expire after 7 days", old.entries.map(\.sessionId) == [uuid(2)])
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("claws-restore-\(getpid())")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("restore.json")
        RestoreLedger.update(file) { $0 = l; $0.entries.append(RestoreEntry(sessionId: "x; rm -rf ~", adapter: "ghostty", pane: "P9", folder: "/w",
                                                                           title: "bad", endedTs: 1, reason: "other")) }
        check("ledger: a session ID that is not a UUID never loads", RestoreLedger.load(file) == l)
        let held = Darwin.open(dir.appendingPathComponent("restore.lock").path, O_RDWR)
        _ = flock(held, LOCK_EX)
        let blocked = RestoreLedger.update(file) { $0.entries = [] }
        flock(held, LOCK_UN)
        close(held)
        check("ledger: no change while another process holds restore.lock", blocked == nil && RestoreLedger.load(file).entries.count == 2)
        check("ledger: changes under the lock otherwise", RestoreLedger.update(file) { $0.entries.removeFirst() }?.entries.count == 1
              && RestoreLedger.load(file).entries.count == 1)
        check("command: only for a UUID", RestorePlan.command("claude --resume {id}", entry(5, "P", 1)) == "claude --resume \(uuid(5))"
              && RestorePlan.command("claude --resume {id}", RestoreEntry(sessionId: "$(touch x)", adapter: "ghostty", pane: "P", folder: "/w",
                                                                            title: "", endedTs: 1, reason: "other")) == nil)

        // Typing safety: only the tab's own login shell, alone in front.
        let me = getuid()
        let shell = RestorePane.Foreground(name: "zsh", uid: me, parentName: "login", parentPid: 50, parentUID: 0, grandparentPid: 9,
                                           pgid: 60, tpgid: 60, tty: "/dev/ttys003")
        check("pane: the tab's login shell at its prompt", RestorePane.problem(shell, paneTTY: "/dev/ttys003", hostPid: 9) == nil)
        var direct = shell
        direct.parentName = "ghostty"; direct.parentPid = 9; direct.grandparentPid = 1
        check("pane: a shell the terminal started itself", RestorePane.problem(direct, paneTTY: "/dev/ttys003", hostPid: 9) == nil)
        var userLogin = shell
        userLogin.parentUID = me
        var otherLogin = shell
        otherLogin.grandparentPid = 77
        check("pane: a `login` that is not root, or not started by this terminal, is refused",
              RestorePane.problem(userLogin, paneTTY: "/dev/ttys003", hostPid: 9) != nil
                && RestorePane.problem(otherLogin, paneTTY: "/dev/ttys003", hostPid: 9) != nil)
        var script = shell
        script.parentName = "zsh"; script.parentPid = 60
        check("pane: a script waiting on read is refused (a shell, but not the tab's own)",
              RestorePane.problem(script, paneTTY: "/dev/ttys003", hostPid: 9) != nil)
        var vim = shell
        vim.name = "vim"
        var root = shell
        root.uid = me &+ 1
        var behind = shell
        behind.tpgid = 61
        check("pane: a program, another user's shell, a shell not in front, another tty are refused",
              RestorePane.problem(vim, paneTTY: "/dev/ttys003", hostPid: 9) != nil && RestorePane.problem(root, paneTTY: "/dev/ttys003", hostPid: 9) != nil
                && RestorePane.problem(behind, paneTTY: "/dev/ttys003", hostPid: 9) != nil
                && RestorePane.problem(shell, paneTTY: "/dev/ttys004", hostPid: 9) != nil && RestorePane.problem(shell, paneTTY: nil, hostPid: 9) != nil)
        check("pane: shells", RestorePane.isShell("zsh") && RestorePane.isShell("-zsh") && RestorePane.isShell("-/bin/zsh")
              && RestorePane.isShell("/opt/homebrew/bin/fish") && !RestorePane.isShell("vim") && !RestorePane.isShell("login")
              && !RestorePane.isShell("2.1.316"))

        // The rules: ended at 100, its terminal gone, Ghostty relaunched at 200 and seen launching.
        let e = entry(7, "P", 100)
        let launch = RestorePlan.Launch(at: 200, observed: true)
        func pane(_ id: String = "P", cwd: String? = "/w/p", problem: String? = nil, started: Double? = 202) -> RestorePane {
            RestorePane(id: id, tty: "/dev/ttys003", foreground: "zsh", started: started, cwd: cwd, problem: problem)
        }
        func v(_ e: RestoreEntry = e, _ panes: [RestorePane] = [pane()], launch: RestorePlan.Launch = launch, host: Bool? = false,
               now: Double = 300) -> RestorePlan.Verdict {
            RestorePlan.verdict(e, panes: panes, launch: launch, hostAlive: host, now: now)
        }
        check("rule: reopened tab, its login shell from this launch, same folder -> resume", v(e, [pane("X"), pane()]) == .resume)
        check("rule (a): the terminal it ran in still runs", v(host: true) == .hostRunning && v(host: nil) == .noHost)
        check("rule (b): this terminal was running before the session ended",
              v(launch: RestorePlan.Launch(at: 90, observed: true)) == .notRelaunched)
        check("rule (c): Claws did not see this launch", v(launch: RestorePlan.Launch(at: 200, observed: false)) == .launchMissed)
        check("rule (c): observed = seen launching, or Claws started at most 2 minutes after it",
              RestorePlan.observed(launchAt: 200, sawLaunch: true, startedAt: 9999) && RestorePlan.observed(launchAt: 200, sawLaunch: false, startedAt: 310)
                && !RestorePlan.observed(launchAt: 200, sawLaunch: false, startedAt: 330) && !RestorePlan.observed(launchAt: 200, sawLaunch: false, startedAt: 100))
        check("rule (d): the tab's shell did not start with the launch", v(e, [pane(started: 290)]) == .notFromLaunch
              && v(e, [pane(started: 150)]) == .notFromLaunch && v(e, [pane(started: nil)]) == .notFromLaunch)
        check("rule: no tab with that ID", v(e, [pane("X")]) == .noPane)
        check("rule: not the login shell at its prompt", v(e, [pane(problem: "vim is running")]) == .busy("vim is running"))
        check("rule: another folder, compared as the kernel reports it (no file system access)",
              v(e, [pane(cwd: "/w/p/sub")]) == .otherFolder("/w/p/sub") && v(e, [pane(cwd: nil)]) == .otherFolder("unknown"))
        check("rule: older than a week", v(now: 101 + RestoreLedger.maxAge) == .expired)
        var offered = e
        offered.launch = 150
        check("rule: offered at an earlier launch, never again", v(offered) == .otherLaunch && RestorePlan.spent(offered, .otherLaunch, launch: launch))
        offered.launch = 200
        check("rule: still offered at the launch it was asked for", v(offered) == .resume)
        check("rule: a settled look is the one chance of what ended before the launch", RestorePlan.spent(e, .noPane, launch: launch)
              && RestorePlan.spent(e, .launchMissed, launch: launch) && !RestorePlan.spent(e, .resume, launch: launch)
              && !RestorePlan.spent(entry(8, "P", 250), .hostRunning, launch: launch))
        check("rule: a terminal already running when the session ended spends it",
              RestorePlan.spent(entry(8, "P", 250), .notRelaunched, launch: launch))
        var stamped = entry(10, "Q", 100)
        stamped.launch = 150
        check("rule: a launch that settles nothing still stamps what ended before it (once), not what ended after",
              RestorePlan.toStamp([e, entry(11, "R", 250), stamped], launch: launch).map(\.sessionId) == [e.sessionId])
        var e2 = e
        e2.launch = 200
        check("rule: a stamped entry is dropped at the next launch", v(e2, launch: RestorePlan.Launch(at: 400, observed: true)) == .otherLaunch
              && RestorePlan.spent(e2, .otherLaunch, launch: RestorePlan.Launch(at: 400, observed: true)))

        // One tab's turn, right before typing, and what typing did.
        func step(_ panes: [RestorePane]?, id: RestoreEntry = e) -> RestorePlan.Step {
            RestorePlan.step(id, panes: panes, launch: launch, hostAlive: false, now: 300, template: "claude --resume {id}")
        }
        var withPid = pane()
        withPid.pid = 4242
        check("step: types into the checked shell, naming its pid",
              step([withPid]) == .type(command: "claude --resume \(e.sessionId)", foreground: 4242))
        check("step: no listing this time waits, it does not drop", step(nil) == .later)
        check("step: the rules still drop", step([withPid], id: entry(12, "Z", 100)) == .drop(RestorePlan.Verdict.noPane.why)
              && step([pane()]) == .drop("its shell is not known"))
        check("typing: the script's answer decides; an error or timeout part way is never retried",
              TypeResult.from(script: "ok", error: nil) == .typed && TypeResult.from(script: "moved", error: nil) == .moved
                && TypeResult.from(script: "gone", error: nil) == .moved && TypeResult.from(script: "busy", error: nil) == .busy
                && TypeResult.from(script: nil, error: -1712) == .failed && TypeResult.from(script: "ok", error: -1728) == .failed
                && TypeResult.from(script: nil, error: nil) == .failed && TypeResult.from(script: "what", error: nil) == .failed)
        check("typing: retry only when nothing was sent", RestorePlan.after(.typed) == .done && RestorePlan.after(.moved) == .retry
              && RestorePlan.after(.busy) == .retry && RestorePlan.after(.failed) == .forget)
        check("typing: only by keystrokes in the last 3 s", RestorePlan.recentlyTyped(idle: 1) && !RestorePlan.recentlyTyped(idle: 4))
        check("typing: never into another Ghostty process than the launch's", GhosttyAdapter.sameProcess(40, 40)
              && !GhosttyAdapter.sameProcess(41, 40) && GhosttyAdapter.sameProcess(41, nil))
        var lateAlive = entry(13, "S", 250), lateDead = entry(14, "T", 250), lateStamped = entry(15, "U", 250)
        lateStamped.launch = 150
        let stampedNow = RestorePlan.stampedForRunning([lateAlive, lateDead, lateStamped], runningLaunch: 200, hostAlive: { $0.sessionId == lateAlive.sessionId })
        check("remember: while its terminal already runs again, an entry gets that launch only (its host still running: no)",
              stampedNow.map(\.launch) == [nil, 200, 150]
                && RestorePlan.stampedForRunning([lateDead], runningLaunch: nil, hostAlive: { _ in false }).map(\.launch) == [nil])
        lateAlive.launch = nil
        let mine = getpid(), myStart = ProcInfo.info(getpid())?.start
        var live = entry(9, "P", 100, host: mine)
        live.hostStart = myStart
        var gone = live
        gone.hostStart = (myStart ?? 0) - 1000
        check("rule: a terminal still running 12 s after the end outlived the session (Cmd-W, claude ended in an open tab)",
              RestorePlan.hostStayed(live, now: 113, alive: ProcInfo.isAlive) && !RestorePlan.hostStayed(live, now: 105, alive: ProcInfo.isAlive)
                && !RestorePlan.hostStayed(gone, now: 113, alive: ProcInfo.isAlive))

        // Settling.
        let starting = [pane(problem: "login is running")], ready = [pane()], other = [pane("X")]
        var w = RestoreWait(start: 0)
        check("wait: a tab still starting is not settled", w.look(nil, at: 0.5, watching: ["P"]) == .waiting
              && w.look(starting, at: 1, watching: ["P"]) == .waiting && w.look(starting, at: 2, watching: ["P"]) == .waiting)
        check("wait: settled once unchanged for 5 s, even if busy", w.look(starting, at: 6.5, watching: ["P"]) == .settled)
        var w2 = RestoreWait(start: 0)
        check("wait: fast when the remembered tabs are there, at their shells",
              w2.look(ready, at: 1, watching: ["P"]) == .waiting && w2.look(ready, at: 2, watching: ["P"]) == .settled)
        var w3 = RestoreWait(start: 0)
        check("wait: no fast path while none of the remembered tabs is there",
              w3.look(other, at: 1, watching: ["P"]) == .waiting && w3.look(other, at: 2, watching: ["P"]) == .waiting
                && w3.look(other, at: 7, watching: ["P"]) == .waiting && w3.look(other, at: 11.5, watching: ["P"]) == .unchanged)
        var w4 = RestoreWait(start: 0, limit: 10)
        check("wait: gives up at the limit, deciding nothing", w4.look(nil, at: 9, watching: ["P"]) == .waiting
              && w4.look(nil, at: 10, watching: ["P"]) == .gaveUp)
        let realHome = dir.appendingPathComponent("real-home"), alias = dir.appendingPathComponent("alias-home")
        try? fm.createDirectory(at: realHome, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: alias, withDestinationURL: realHome)
        check("--watch: only with a data folder of its own, also through a symlink", !RestoreCLI.isScratchHome([:]) && !RestoreCLI.isScratchHome(["CLAWS_HOME": ""])
              && !RestoreCLI.isScratchHome(["CLAWS_HOME": realHome.path + "/"], real: realHome)
              && !RestoreCLI.isScratchHome(["CLAWS_HOME": alias.path], real: realHome)
              && RestoreCLI.isScratchHome(["CLAWS_HOME": dir.path], real: realHome))
        check("--restore-run --yes: not alongside a running Claws, unless on a data folder of its own",
              !RestoreCLI.mayRunAlongside(appRunning: true, env: [:]) && RestoreCLI.mayRunAlongside(appRunning: false, env: [:])
                && RestoreCLI.mayRunAlongside(appRunning: true, env: ["CLAWS_HOME": dir.path]))

        // Ghostty: tabs by tty, its config, its version.
        var m = TTYMap()
        m.list([PaneInfo(id: "A", cwd: "/w", name: "a", tty: "/dev/ttys001"), PaneInfo(id: "B", cwd: "/w", name: "b", tty: "/dev/ttys002"),
                PaneInfo(id: "C", cwd: "/w", name: "c")], at: 100, host: 9)
        check("tty: a session maps to the tab on its tty", m.pane(tty: "/dev/ttys002", since: 90, host: 9) == "B"
              && m.pane(tty: "/dev/ttys009", since: 90, host: 9) == nil)
        check("tty: a sighting older than the session's process is not trusted", m.pane(tty: "/dev/ttys001", since: 150, host: 9) == nil)
        check("tty: only a sighting by the Ghostty the session runs under (a relaunched one reuses ttys)",
              m.pane(tty: "/dev/ttys002", since: 90, host: 10) == nil && m.pane(tty: "/dev/ttys002", since: 90, host: nil) == nil)
        m.saw(PaneInfo(id: "D", cwd: "/w", name: "d", tty: "/dev/ttys001"), at: 200, host: 9)
        check("tty: a reused tty points at its new tab", m.pane(tty: "/dev/ttys001", since: 150, host: 9) == "D")
        m.list([PaneInfo(id: "B", cwd: "/w", name: "b", tty: "/dev/ttys002")], at: 300, host: 9)
        check("tty: a full listing forgets closed tabs", m.pane(tty: "/dev/ttys001", since: 0, host: 9) == nil
              && m.pane(tty: "/dev/ttys002", since: 250, host: 9) == "B")
        func scripts(_ app: String) -> [(String, String)] {
            [("listing with tty", GhosttyAdapter.listingScript(app: app, withTTY: true)),
             ("listing", GhosttyAdapter.listingScript(app: app, withTTY: false)),
             ("focused tab with tty", GhosttyAdapter.focusedScript(app: app, withTTY: true)),
             ("focused tab", GhosttyAdapter.focusedScript(app: app, withTTY: false)),
             ("focus", GhosttyAdapter.focusScript(app: app, terminal: "AB12-CD34")),
             ("typing", GhosttyAdapter.typeScript(app: app, terminal: "AB12-CD34", shell: 7, deferIfFocused: false, command: "c \"q\" \\ x")),
             ("typing, deferring", GhosttyAdapter.typeScript(app: app, terminal: "AB12-CD34", shell: 7, deferIfFocused: true, command: "c")),
             ("new tab", GhosttyAdapter.newPaneScript(app: app, in: "/w", typing: "c"))]
        }
        check("ghostty: every script runs only while Ghostty is running (a quit one is never relaunched)",
              scripts("x.y").allSatisfy { $0.1.hasPrefix("if application id \"x.y\" is running then") })
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: GhosttyAdapter.bundleID) != nil {
            // Compiling reads the dictionary from the app bundle and sends Ghostty nothing.
            for (name, source) in scripts(GhosttyAdapter.bundleID) {
                var err: NSDictionary?
                check("applescript compiles against Ghostty's dictionary (guarded \(name))",
                      NSAppleScript(source: source)?.compileAndReturnError(&err) == true, String(describing: err))
            }
        }
        let typing = GhosttyAdapter.typeScript(app: "x.y", terminal: "AB", shell: 7, deferIfFocused: true, command: "c")
        func at(_ s: String) -> String.Index { typing.range(of: s)!.lowerBound }
        check("ghostty: one typing script checks the shell, then the focused tab, then Ctrl-E, Ctrl-U, the command",
              typing.contains("if (pid of t) is not 7 then return \"moved\"") && typing.contains("is \"AB\" then return \"busy\"")
                && at("return \"moved\"") < at("return \"busy\"") && at("return \"busy\"") < at("send key \"e\"")
                && at("send key \"e\"") < at("send key \"u\"") && at("send key \"u\"") < at("input text") && typing.hasSuffix("return \"gone\""))
        check("ghostty: no focus check while you are not typing",
              !GhosttyAdapter.typeScript(app: "x.y", terminal: "AB", shell: 7, deferIfFocused: false, command: "c").contains("busy"))
        check("ghostty: window-save-state from +show-config", GhosttyAdapter.saveState("font-size = 13\nwindow-save-state = always\n") == "always"
              && GhosttyAdapter.saveState("font-size = 13\n") == nil)
        check("ghostty: version check", GhosttyAdapter.isBefore("1.3.1", [1, 4]) && !GhosttyAdapter.isBefore("1.4.0", [1, 4])
              && !GhosttyAdapter.isBefore("1.10", [1, 4]) && !GhosttyAdapter.isBefore("2.0", [1, 4]) && GhosttyAdapter.isBefore("1.4.0-dev", [1, 5]))
        check("ghostty: restores, other terminals do not", Terminals.shared.adapters.filter(\.restoresPanes).map(\.id) == ["ghostty"])
        // Telling an app that is not running anything launches it: these return before any script.
        let absent = GhosttyAdapter(bundleID: "io.example.claws.not-installed")
        check("ghostty: never scripted unless running and done launching",
              absent.list() == nil && absent.restorablePanes(app: nil) == nil
                && absent.type("x", into: "AB12", app: 1, ifForeground: 1, deferIfFocused: false) == .moved)
        check("applescript: an undefined term is -2753 (Ghostty 1.3's missing tty), not a timeout",
              Script.attempt("return tty").error == Script.undefinedTerm)
    }

    static func geometry() {
        let vf = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let w: [CGFloat] = [28, 28, 28]
        func lay(_ p: Placement) -> StripGeometry.Result {
            StripGeometry.layout(widths: w, height: 40, placement: p, in: vf, margin: 8, gap: 3)
        }
        let bl = lay(Placement(corner: "bottomLeft"))
        check("layout: bottom-left grows right", bl.growsRight && bl.frames.map(\.minX) == [8, 39, 70] && bl.frames[0].minY == 8)
        let br = lay(Placement(corner: "bottomRight"))
        check("layout: bottom-right grows left", !br.growsRight && br.frames.map(\.minX) == [964, 933, 902], "\(br.frames.map(\.minX))")
        let nearRight = lay(Placement(corner: nil, fx: 0.96, fy: 0.5))
        check("layout: no room on the right flips left, first Clawd stays put",
              !nearRight.growsRight && nearRight.frames[0].minX == 960 && nearRight.frames[2].minX < 960)
        let middle = lay(Placement(corner: nil, fx: 0.5, fy: 0.5))
        check("layout: middle grows right", middle.growsRight && middle.frames[0].minX == 500)
        let top = lay(Placement(corner: "topLeft"))
        check("layout: top corner opens the bubble below", top.bubbleBelow && top.frames[0].maxY == 792)
        let offscreen = lay(Placement(corner: nil, fx: 1.4, fy: -0.2))
        check("layout: a stale spot is pulled back on screen", offscreen.rect.maxX <= 1000 && offscreen.rect.minY >= 0)

        func drop(_ x: CGFloat, _ y: CGFloat) -> Placement {
            let lead = CGRect(x: x, y: y, width: 28, height: 40)
            return StripGeometry.placement(lead: lead, strip: CGRect(x: x, y: y, width: 90, height: 40), in: vf, margin: 8, snap: true)
        }
        check("snap: near bottom-left becomes the corner", drop(30, 25).corner == "bottomLeft")
        check("snap: near top-right becomes the corner", drop(1000 - 8 - 90 - 20, 800 - 8 - 40 - 10).corner == "topRight")
        let free = drop(400, 300)
        check("snap: middle stays exactly where dropped", free.corner == nil && free.fx == 0.4 && free.fy == 0.375)
        let edge = drop(400, 15)
        check("snap: close to the bottom edge sits on it", edge.corner == nil && abs(edge.fy * 800 - 8) < 0.001)
        let noSnap = StripGeometry.placement(lead: CGRect(x: 30, y: 25, width: 28, height: 40),
                                             strip: CGRect(x: 30, y: 25, width: 90, height: 40), in: vf, margin: 8, snap: false)
        check("snap off: exact drop", noSnap.corner == nil && noSnap.fx == 0.03)
    }

    static func orderedJSON() {
        let samples = [
            "{}", "[]", "{\n  \"a\": 1,\n  \"b\": [\n    true,\n    null,\n    \"x\\ny\\\"z\"\n  ],\n  \"c\": {}\n}",
            "{\n  \"emoji\": \"✳ crab 🦀\",\n  \"n\": -1.5e3\n}",
        ]
        for s in samples {
            let v = try? JSONValue.parse(s)
            check("json round trip \(s.prefix(12).replacingOccurrences(of: "\n", with: " "))", v?.serialized() == s,
                  v?.serialized() ?? "parse failed")
        }
        check("json \\u escapes", (try? JSONValue.parse("\"\\u00e9\\ud83e\\udd80\""))?.stringValue == "é🦀")
        check("json rejects junk", (try? JSONValue.parse("{\"a\":1}x")) == nil)
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        if let text = try? String(contentsOf: real, encoding: .utf8) {
            let v = try? JSONValue.parse(text)
            check("~/.claude/settings.json round-trips byte for byte",
                  v.map { $0.serialized() + (text.hasSuffix("\n") ? "\n" : "") } == text)
        }
    }

    static func installer() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claws-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        let original = """
        {
          "model": "opus",
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "say done"
                  }
                ]
              }
            ]
          },
          "theme": "dark"
        }

        """
        try? original.write(to: url, atomically: true, encoding: .utf8)
        let hook = "/Applications/Claws for Concern.app/Contents/MacOS/claws-for-concern-hook"
        check("install", (try? HooksInstaller.install(settings: url, hookPath: hook)) != nil)
        check("status installed", HooksInstaller.status(settings: url, hookPath: hook) == .installed)
        let after = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check("other hooks kept", after.contains("say done") && after.contains("\"theme\": \"dark\""))
        check("key order kept", after.range(of: "\"model\"")!.lowerBound < after.range(of: "\"hooks\"")!.lowerBound
              && after.range(of: "\"hooks\"")!.lowerBound < after.range(of: "\"theme\"")!.lowerBound)
        check("reinstall is a no-op", (try? HooksInstaller.install(settings: url, hookPath: hook)) == .some(nil))
        check("moved app reads as outdated", HooksInstaller.status(settings: url, hookPath: "/tmp/x/claws-for-concern-hook") != .installed)
        _ = try? HooksInstaller.remove(settings: url)
        check("remove restores the file exactly", (try? String(contentsOf: url, encoding: .utf8)) == original)
        let empty = dir.appendingPathComponent("new.json")
        _ = try? HooksInstaller.install(settings: empty, hookPath: hook)
        _ = try? HooksInstaller.remove(settings: empty)
        check("install+remove on a missing file leaves {}", (try? String(contentsOf: empty, encoding: .utf8)) == "{}\n")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.contains("bak-claws") } ?? []
        check("backups written", !backups.isEmpty)
    }

    static func text() {
        check("clean strips quotes and period", Summarizer.clean("\"Waiting on your pick: main or release.\"\n") == "Waiting on your pick: main or release")
        check("clean strips label", Summarizer.clean("Recap: PR open, needs review") == "PR open, needs review")
        check("clean caps length", Summarizer.clean(String(repeating: "a", count: 300)).count == 140)
        check("fallback first sentence", Summarizer.fallback("## Done\n\nPushed it. Then more.") == "Done Pushed it.",
              Summarizer.fallback("## Done\n\nPushed it. Then more."))
        check("strip glyph ✳", PaneInfo.stripGlyph("✳ Fix login") == "Fix login")
        check("strip spinner", PaneInfo.stripGlyph("◐ Claude animated icon") == "Claude animated icon")
        check("keep path titles", PaneInfo.stripGlyph("/Users/sam/code") == "/Users/sam/code")
        let claudeTab = PaneInfo(id: "1", cwd: "/w", name: "✳ Fix login test")
        let shellTab = PaneInfo(id: "2", cwd: "/w", name: "/w")
        check("tab: claude tab matches its title", TabMatch.matches(claudeTab, rootCwd: "/x", cwd: "/x", title: "Fix login test", strong: false))
        check("tab: claude tab rejects another title", !TabMatch.matches(claudeTab, rootCwd: "/w", cwd: "/w", title: "Budgets", strong: true))
        check("tab: plain shell never matches a titled session", !TabMatch.matches(shellTab, rootCwd: "/w", cwd: "/w", title: "Fix login test", strong: false))
        check("tab: plain shell matches when you typed there", TabMatch.matches(shellTab, rootCwd: "/w", cwd: "/w", title: "Fix login test", strong: true))
        check("tab: untitled session matches by folder", TabMatch.matches(claudeTab, rootCwd: "/w", cwd: "/w", title: nil, strong: false))
        check("shell quoting", "/Users/a b".shellQuoted == "'/Users/a b'" && "/Users/ab".shellQuoted == "/Users/ab")
    }

    /// The search helper: who may ask, what a request leads to, the new-tab script, the helper in the
    /// bundle and its own self-test.
    static func search() {
        for (name, ok) in ResumeBridgeTests.run() { check(name, ok) }

        let id = "0f1e2d3c-4b5a-6978-8a9b-acbdcedfe0f1"
        let now = Date().timeIntervalSince1970
        let r = ResumeRequest(sessionId: id, folder: "/Users/someone/code", nonce: "n1", sent: now)
        let helper = URL(fileURLWithPath: "/Applications/Claws for Concern.app/Contents/Helpers/Claws Search.app")
        let front: (url: URL?, pid: pid_t)? = (URL(fileURLWithPath: helper.path + "/"), 42)
        check("search: our nonce, from the Search window in front, is accepted",
              SearchHelper.refusal(nonce: "n1", issued: ["n1": 42], front: front, helper: helper) == nil
              && SearchHelper.refusal(nonce: "n1", issued: ["n1": 0], front: front, helper: helper) == nil)
        check("search: a nonce we never issued is refused", SearchHelper.refusal(nonce: "made-up", issued: ["n1": 42], front: front, helper: helper) != nil)
        check("search: a nonce another Search process got is refused", SearchHelper.refusal(nonce: "n1", issued: ["n1": 7], front: front, helper: helper) != nil)
        check("search: refused unless the Search window is in front",
              SearchHelper.refusal(nonce: "n1", issued: ["n1": 42], front: (URL(fileURLWithPath: "/Applications/Ghostty.app"), 42), helper: helper) != nil
              && SearchHelper.refusal(nonce: "n1", issued: ["n1": 42], front: nil, helper: helper) != nil)
        check("search: requests more than 30 s old (or ahead) are dropped",
              !SearchHelper.isStale(r, now: now + 29) && SearchHelper.isStale(r, now: now + 31) && SearchHelper.isStale(r, now: now - 31))

        var withPid = SessionState(sessionId: id, cwd: "/w")
        withPid.claudePid = 5
        var noPid = SessionState(sessionId: id, cwd: "/w")
        noPid.updatedTs = now - 3600
        check("search: running means its Claude process is alive", SearchHelper.isRunning(withPid, hasPane: false, now: now) { _, _ in true }
              && !SearchHelper.isRunning(withPid, hasPane: true, now: now) { _, _ in false })
        check("search: no process on record, quiet for an hour: not running unless its pane is known",
              !SearchHelper.isRunning(noPid, hasPane: false, now: now) { _, _ in true } && SearchHelper.isRunning(noPid, hasPane: true, now: now) { _, _ in false })
        noPid.updatedTs = now - 60
        check("search: no process on record, updated a minute ago: running", SearchHelper.isRunning(noPid, hasPane: false, now: now) { _, _ in false }
              && !SearchHelper.isRunning(nil, hasPane: true, now: now) { _, _ in true })

        func refused(_ p: SearchHelper.Plan) -> Bool { if case .refuse = p { return true } else { return false } }
        check("search: a closed session gets a new tab typing the resume command",
              SearchHelper.plan(r, folders: ["/Users/someone/code"], template: "claude -r {id}") == .newPane(command: "claude -r \(id)"))
        check("search: only in the exact folder its transcript names", refused(SearchHelper.plan(r, folders: ["/Users/someone/other"], template: "x"))
              && refused(SearchHelper.plan(r, folders: [], template: "x")) && refused(SearchHelper.plan(r, folders: ["/Users/someone/code/sub"], template: "x")))

        var gate = ResumeGate()
        check("search: one new tab per session at a time", gate.begin(id, now: now) == nil && gate.begin(id, now: now) != nil)
        gate.end(id, opened: true, now: now)
        check("search: none again for 15 s after one opened", gate.begin(id, now: now + 5) != nil && gate.begin(id, now: now + 16) == nil)
        gate.end(id, opened: false, now: now + 16)
        check("search: a failed attempt may be tried again at once", gate.begin(id, now: now + 17) == nil)

        final class Plain: TerminalAdapter {
            let id = "plain", name = "Plain"
            func claims(_ s: SessionState) -> Bool { false }
            func lookedAt(front: FrontApp) -> Set<String> { [] }
            func focus(paneID: String, session: SessionState) -> Bool { false }
            func health() -> AdapterHealth { AdapterHealth(level: .ready, detail: "") }
        }
        check("search: adapters open no new panes unless they say so", !Plain().newPane(in: "/w", typing: "true"))
        check("search: the new-tab script drives the adapter's own Ghostty",
              GhosttyAdapter.newPaneScript(app: "com.example.ghostty-copy", in: "/w", typing: "x").contains("tell application id \"com.example.ghostty-copy\""))
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: GhosttyAdapter.bundleID) != nil {
            var err: NSDictionary?
            let src = GhosttyAdapter.newPaneScript(app: GhosttyAdapter.bundleID, in: "/Users/someone/a \"b\" \\c", typing: "claude --resume \(id)")
            check("applescript compiles against Ghostty's dictionary (new tab)", NSAppleScript(source: src)?.compileAndReturnError(&err) == true,
                  String(describing: err))
        }

        guard let helper = Bundle(url: SearchHelper.url), let exe = helper.executableURL else {
            check("search: helper in the bundle", false, SearchHelper.url.path); return
        }
        let version = { (b: Bundle) in ["CFBundleShortVersionString", "CFBundleVersion"].map { b.object(forInfoDictionaryKey: $0) as? String } }
        check("search: helper in the bundle, same version", helper.bundleIdentifier == ResumeRequest.appID + ".search"
              && version(helper) == version(Bundle.main), "\(helper.bundleIdentifier ?? "?") \(version(helper)) vs \(version(Bundle.main))")
        // The helper also reads our resume command from our domain, its way, and compares it with ours.
        guard let res = Command.run(exe.path, ["--selftest"], env: ["CLAWS_EXPECTED_RESUME_COMMAND": Settings.resumeCommand], timeout: 300) else {
            check("search: helper self-test ran", false, exe.path); return
        }
        let lines = res.out.split(separator: "\n")
        for l in lines where l.hasPrefix("info ") || l.hasPrefix("FAIL") { print("     helper: " + l.prefix(160)) }
        check("search: the helper reads the same resume command as Settings",
              lines.contains { $0.hasPrefix("PASS the resume command read from the app's domain") })
        check("search: helper self-test (\(lines.filter { $0.hasPrefix("PASS") }.count) checks) prints ALL PASS",
              res.status == 0 && lines.last == "ALL PASS", "exit \(res.status)")
    }

    /// Builds a two-frame GIF on a 110 x 74 canvas (2 px per art pixel) and converts it back.
    static func art() {
        let w = 110, h = 74
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil) else {
            check("gif encoder", false); return
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (i, (x, y)) in [(10, 20), (12, 22)].enumerated() {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(PixelCrab.clay.cgColor)
            // Art pixels (x..x+3, y..y+1) in top-left coordinates.
            ctx.fill(CGRect(x: x * 2, y: h - (y + 2) * 2, width: 8, height: 4))
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1 + Double(i) * 0.1]] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
        let out = Art.convert(data as Data)
        check("art: frames and delays", out?.meta.frames == 2 && out?.meta.delays == [100, 200], String(describing: out?.meta))
        check("art: union crop", out?.meta.x == 10 && out?.meta.y == 20 && out?.meta.w == 6 && out?.meta.h == 4, String(describing: out?.meta))
        check("art: placeholder sprite", SpriteLibrary(directory: URL(fileURLWithPath: "/nonexistent"))[SpriteLibrary.placeholder] != nil)
    }
}
