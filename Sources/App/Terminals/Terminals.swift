import AppKit
import CoreServices

// MARK: - The adapter contract

/// A pane in a terminal: a Ghostty surface, a tmux pane, a cmux surface, an iTerm2 session…
struct PaneInfo: Equatable {
    let id: String
    let cwd: String
    let name: String
    /// The pane's terminal device, when the terminal reports it (Ghostty 1.4+).
    var tty: String? = nil
    /// The pane's foreground process, when the terminal reports it (Ghostty 1.4+).
    var pid: Int32? = nil
    /// The title without Claude Code's status glyph ("✳ Fix login" -> "Fix login").
    var title: String { PaneInfo.stripGlyph(name) }

    static func stripGlyph(_ s: String) -> String {
        var t = Substring(s)
        while let c = t.first, !(c.isLetter || c.isNumber || c == "/" || c == "~" || c == "." || c == "(" || c == "[") {
            t = t.dropFirst()
        }
        return String(t).trimmingCharacters(in: .whitespaces)
    }
}

/// A pane as a restore sees it: may a resume command be typed into it?
struct RestorePane: Equatable {
    let id: String
    /// The pane's terminal device, as the terminal reports it.
    let tty: String?
    /// The foreground process's name ("zsh", "vim"), "" if unknown.
    let foreground: String
    /// When the foreground process started (epoch seconds): a tab reopened by a relaunch has a shell
    /// that started with the terminal.
    let started: Double?
    /// The foreground process's working directory, from the kernel (no file system access).
    let cwd: String?
    /// Why the pane is not the tab's own login shell waiting at its prompt; nil when it is.
    let problem: String?

    var atShell: Bool { problem == nil }

    /// What the kernel says about a pane's foreground process (Ghostty's `pid`, which is the leader
    /// of the terminal's foreground process group).
    struct Foreground: Equatable {
        var name: String
        var uid: uid_t
        var parentName: String
        var parentPid: Int32
        var pgid: Int32
        var tpgid: Int32
        var tty: String?
    }

    /// The tab's own login shell, alone in front: a shell, ours, started by `login` or by the
    /// terminal itself, in the foreground of the pane's tty. A script waiting on `read` is a shell
    /// too, but its parent is the login shell, so it is refused.
    static func problem(_ f: Foreground, paneTTY: String?, hostPid: Int32?, uid: uid_t = getuid()) -> String? {
        guard isShell(f.name) else { return "\(f.name.isEmpty ? "something" : f.name) is running" }
        guard f.uid == uid else { return "the shell belongs to another user" }
        guard f.parentName == "login" || (hostPid != nil && f.parentPid == hostPid) else {
            return "a shell started from \(f.parentName.isEmpty ? "another program" : f.parentName) is waiting, not the tab's own shell"
        }
        guard f.pgid == f.tpgid else { return "something else is in the foreground" }
        guard let paneTTY, f.tty == paneTTY else { return "the shell is not on the tab's tty" }
        return nil
    }

    /// For terminals that report each pane's tty and foreground process. `hostPid`: the terminal
    /// app's process, which may start shells itself.
    static func from(id: String, tty: String?, foregroundPid pid: Int32?, hostPid: Int32?) -> RestorePane {
        guard let pid, pid > 0, let e = ProcInfo.info(pid) else {
            return RestorePane(id: id, tty: tty, foreground: "", started: nil, cwd: nil, problem: "nothing is running")
        }
        let path = ProcInfo.path(pid)
        let name = path.isEmpty ? e.name : (path as NSString).lastPathComponent
        let f = Foreground(name: name, uid: e.uid, parentName: ProcInfo.info(e.ppid)?.name ?? "", parentPid: e.ppid,
                           pgid: e.pgid, tpgid: e.tpgid, tty: ProcInfo.tty(pid))
        return RestorePane(id: id, tty: tty, foreground: name, started: e.start, cwd: ProcInfo.cwd(pid),
                           problem: problem(f, paneTTY: tty, hostPid: hostPid))
    }

    static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "fish", "ksh", "mksh", "tcsh", "csh", "nu", "elvish", "xonsh", "pwsh"]

    /// "zsh", "-zsh" (a login shell's argv[0]) or "/bin/zsh".
    static func isShell(_ name: String) -> Bool {
        var n = (name as NSString).lastPathComponent
        while n.hasPrefix("-") { n.removeFirst() }
        return shells.contains(n)
    }
}

/// The app in front, captured on the main thread for adapters running on the worker.
struct FrontApp {
    let bundleID: String?
    let pid: Int32?
}

/// What Settings → Integrations shows for an adapter.
struct AdapterHealth: Equatable {
    enum Level { case ready, limited, unavailable }
    var level: Level
    var detail: String
    /// A fix the user can apply from Settings, if there is one.
    var fix: Fix? = nil
    enum Fix: Equatable { case allowAutomation(bundleID: String), openAutomationSettings, openApp(bundleID: String, label: String) }
}

/// One terminal or multiplexer Claws for Concern can find Claude Code sessions in.
///
/// Read docs/adapters.md before writing one. In short: decide `claims` from what the hook recorded,
/// never block the main thread (worker methods run on `Terminals.worker`), keep every external call
/// under ~1.5 s, and never store secrets.
protocol TerminalAdapter: AnyObject {
    /// Stable identifier ("ghostty", "tmux"…). Persisted with learned panes; never change it.
    var id: String { get }
    /// Shown in Settings and menus.
    var name: String { get }
    /// The app this adapter controls over AppleScript, if any (needs the Automation permission).
    var scriptedBundleID: String? { get }
    /// True when the terminal decides "seen" itself (herdr), so no keyboard or mouse activity is needed.
    var tracksSeenItself: Bool { get }

    /// Main thread. Does this adapter handle the session? Decide from the recorded context only.
    func claims(_ s: SessionState) -> Bool
    /// Main thread. The pane the session runs in, when the recorded context says so outright.
    /// Return nil to have the tracker learn it from `focusedPane()` and `panes()` (Ghostty).
    func paneID(for s: SessionState) -> String?

    /// Worker. The panes you are looking at right now. Called about once a second while Clawds are up.
    func lookedAt(front: FrontApp) -> Set<String>
    /// Worker. Bring the pane and its app to the front. False if that did not work.
    func focus(paneID: String, session: SessionState) -> Bool
    /// Worker. Installed, reachable, permitted? For Settings → Integrations.
    func health() -> AdapterHealth

    /// True when `paneID(for:)` cannot name the pane and the tracker must learn it instead, from
    /// `focusedPane` (the tab you type a prompt into) and `panes` (folder and title matching).
    var learnsPanes: Bool { get }
    /// Worker, learning adapters only: the focused pane when the app is in front, and every pane.
    func focusedPane(front: FrontApp) -> PaneInfo?
    func panes() -> [PaneInfo]

    /// Worker, optional (default false): open a new pane in `dir` and type `command` into its shell
    /// (Search resumes a session this way). See `Terminals.newPane` for what happens before it.
    func newPane(in dir: String, typing command: String) -> Bool

    // Restore: when the terminal relaunches and reopens its tabs under the same pane IDs, the
    // conversations that were running in them come back (docs/adapters.md, "Restore").

    /// True when the terminal reopens panes under their old IDs and this adapter implements
    /// `restorablePanes` and `type(_:into:)`.
    var restoresPanes: Bool { get }
    /// The terminal's app: its launch starts a restore.
    var appBundleID: String? { get }
    /// Worker. Every pane, with what runs in front of it. nil when the terminal cannot say.
    func restorablePanes() -> [RestorePane]?
    /// Worker. Types `command` into the pane and presses Return. False if that did not work.
    func type(_ command: String, into paneID: String) -> Bool
    /// Worker. Why the terminal will not reopen its panes after a relaunch (a setting to change),
    /// or nil. Shown in Settings → General → Restore.
    func restoreProblem() -> String?
}

extension TerminalAdapter {
    var scriptedBundleID: String? { nil }
    var tracksSeenItself: Bool { false }
    func paneID(for s: SessionState) -> String? { nil }
    func focusedPane(front: FrontApp) -> PaneInfo? { nil }
    func panes() -> [PaneInfo] { [] }
    var learnsPanes: Bool { false }
    var restoresPanes: Bool { false }
    var appBundleID: String? { scriptedBundleID }
    func restorablePanes() -> [RestorePane]? { nil }
    func type(_ command: String, into paneID: String) -> Bool { false }
    func restoreProblem() -> String? { nil }
}

// MARK: - The coordinator

/// Owns the adapters, the background thread they run on, and the latest "what you are looking at"
/// snapshot the tracker reads.
final class Terminals {
    static let shared = Terminals()

    /// Order matters: multiplexers first, so tmux inside Ghostty is tmux's.
    let adapters: [TerminalAdapter] = [HerdrAdapter(), TmuxAdapter(), CmuxAdapter(), GhosttyAdapter(bundleID: GhosttyAdapter.target),
                                       ITermAdapter(), AppleTerminalAdapter()]
    /// Anything else: bring forward whichever app hosts the session.
    let fallback = HostAppAdapter()
    let worker = ScriptThread(name: "claws.terminals")
    /// Permission prompts get their own thread: one can sit unanswered for as long as you are away,
    /// and the other terminals must keep working meanwhile.
    let prompter = ScriptThread(name: "claws.permissions")

    /// Adapters with Clawds up, and adapters with a session at work (set by the tracker). Only these
    /// are polled, so an idle Mac sends no Apple Events and runs no tools at all.
    var watched: Set<String> = []
    var busy: Set<String> = []

    // Main-thread snapshots.
    private(set) var looked: [String: Set<String>] = [:]
    private(set) var lookedAtTime: [String: Date] = [:]
    private(set) var focused: [String: PaneInfo] = [:]
    private(set) var focusedTime: [String: Date] = [:]
    private(set) var healthByID: [String: AdapterHealth] = [:]
    private var inFlight = Set<String>()
    private var timer: Timer?

    func adapter(for s: SessionState) -> TerminalAdapter { adapters.first { $0.claims(s) } ?? fallback }
    func adapter(id: String) -> TerminalAdapter? { id == fallback.id ? fallback : adapters.first { $0.id == id } }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = 0.15
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.poll() }
        refreshHealth()
    }

    static var front: FrontApp {
        let app = NSWorkspace.shared.frontmostApplication
        return FrontApp(bundleID: app?.bundleIdentifier, pid: app?.processIdentifier)
    }

    /// Polls adapters that have Clawds up or sessions at work (a session at work is about to stop,
    /// and whether you are looking at it then decides if it gets a Clawd).
    private func poll(only: Set<String>? = nil, then: (() -> Void)? = nil) {
        let front = Terminals.front
        let wanted = only ?? watched.union(busy)
        let group = DispatchGroup()
        for a in adapters {
            guard wanted.contains(a.id), !inFlight.contains(a.id) else { continue }
            if let b = a.scriptedBundleID, Automation.cached(b) != .granted { continue }
            inFlight.insert(a.id)
            group.enter()
            worker.run {
                let seen = a.lookedAt(front: front)
                let f = a.learnsPanes ? a.focusedPane(front: front) : nil
                DispatchQueue.main.async {
                    self.inFlight.remove(a.id)
                    self.looked[a.id] = seen
                    self.lookedAtTime[a.id] = Date()
                    if a.learnsPanes { self.focused[a.id] = f; self.focusedTime[a.id] = Date() }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { then?() }
    }

    /// One immediate poll, for "you just typed a prompt: which pane is in front?".
    func pollNow(_ adapterIDs: Set<String>, then: @escaping () -> Void) { poll(only: adapterIDs, then: then) }

    /// Panes you were looking at as of the last poll (stale snapshots count as nothing).
    func lookedAt(_ adapterID: String, maxAge: TimeInterval = 2.5) -> Set<String> {
        guard let t = lookedAtTime[adapterID], Date().timeIntervalSince(t) <= maxAge else { return [] }
        return looked[adapterID] ?? []
    }

    /// The focused pane of a learning adapter, if fresh.
    func focusedPane(_ adapterID: String, maxAge: TimeInterval = 2.5) -> PaneInfo? {
        guard let t = focusedTime[adapterID], Date().timeIntervalSince(t) <= maxAge else { return nil }
        return focused[adapterID]
    }

    func panes(_ a: TerminalAdapter, _ done: @escaping ([PaneInfo]) -> Void) {
        if let b = a.scriptedBundleID, Automation.cached(b) != .granted { done([]); return }
        worker.run {
            let list = a.panes()
            DispatchQueue.main.async { done(list) }
        }
    }

    /// Jump to the session: its adapter's pane if known, else (or if that fails) the app hosting it.
    /// `done` says whether the pane itself was focused.
    func open(_ s: SessionState, adapter a: TerminalAdapter, paneID: String?, done: @escaping (_ paneOK: Bool) -> Void) {
        // Scripting an app we may not control would raise its prompt here and hold up the worker:
        // ask on the prompt thread instead, and this time just bring the app forward.
        let permitted = a.scriptedBundleID.map { Automation.cached($0) == .granted } ?? true
        if !permitted { requestPermission(a) }
        worker.run {
            var paneOK = false
            if permitted, let paneID { paneOK = a.focus(paneID: paneID, session: s) }
            if !paneOK { _ = self.fallback.focus(paneID: "", session: s) }
            DispatchQueue.main.async { done(paneOK) }
        }
    }

    /// Re-checks every adapter for Settings (and caches Automation permissions for polling).
    func refreshHealth(then: (() -> Void)? = nil) {
        worker.run {
            var h: [String: AdapterHealth] = [:]
            for a in self.adapters {
                if let b = a.scriptedBundleID { Automation.refresh(b) }
                h[a.id] = a.health()
            }
            DispatchQueue.main.async { self.healthByID = h; then?() }
        }
    }

    /// Asks for the Automation permission an adapter needs (shows the system prompt once).
    func requestPermission(_ a: TerminalAdapter, then: (() -> Void)? = nil) {
        guard let b = a.scriptedBundleID, Automation.startAsking(b) else { then?(); return }
        prompter.run {
            _ = Automation.check(b, ask: true)
            Automation.doneAsking(b)
            DispatchQueue.main.async { self.refreshHealth(then: then) }
        }
    }
}

// MARK: - Shared plumbing

/// The Automation (Apple Events) permission per target app. Checking it can block while the system
/// prompt is up, so it never runs on the main thread; the cache is read from anywhere.
enum Automation {
    enum Status { case granted, denied, undetermined, notRunning }
    private static var cache: [String: Status] = [:]
    private static var asking = Set<String>()
    private static let lock = NSLock()

    static func cached(_ bundleID: String) -> Status {
        lock.lock(); defer { lock.unlock() }
        return cache[bundleID] ?? .undetermined
    }

    /// Marks a prompt for this app as pending; false if one already is.
    static func startAsking(_ bundleID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return asking.insert(bundleID).inserted
    }

    static func doneAsking(_ bundleID: String) {
        lock.lock(); asking.remove(bundleID); lock.unlock()
    }

    static func isAsking(_ bundleID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return asking.contains(bundleID)
    }

    /// Without asking. Skipped while that app's prompt is up: the check would block the worker until
    /// it is answered, even though it asks nothing itself.
    @discardableResult
    static func refresh(_ bundleID: String) -> Status {
        isAsking(bundleID) ? cached(bundleID) : check(bundleID, ask: false)
    }

    /// Off the main thread only: blocks until the user answers the prompt when `ask` is true.
    static func check(_ bundleID: String, ask: Bool) -> Status {
        let s: Status
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            s = .notRunning
        } else {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            switch AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask) {
            case noErr: s = .granted
            case OSStatus(errAEEventNotPermitted): s = .denied
            default: s = .undetermined
            }
        }
        lock.lock(); defer { lock.unlock() }
        // An app that quit keeps its last real answer; "not running" only replaces "undetermined".
        if s != .notRunning || cache[bundleID] == nil || cache[bundleID] == .undetermined { cache[bundleID] = s }
        return s
    }

    static func healthFor(_ bundleID: String, appName: String, ready: String) -> AdapterHealth {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) == nil {
            return AdapterHealth(level: .unavailable, detail: "\(appName) is not installed.")
        }
        switch cached(bundleID) {
        case .granted: return AdapterHealth(level: .ready, detail: ready)
        case .denied: return AdapterHealth(level: .limited, detail: "Not allowed to control \(appName).", fix: .openAutomationSettings)
        case .notRunning: return AdapterHealth(level: .limited, detail: "\(appName) is not running.")
        case .undetermined: return AdapterHealth(level: .limited, detail: "Allow access to find and switch \(appName) tabs.",
                                                 fix: .allowAutomation(bundleID: bundleID))
        }
    }
}

/// AppleScript helpers, compiled once per source. Worker thread only.
enum Script {
    private static var cache: [String: NSAppleScript] = [:]

    static func run(_ source: String, cacheKey: String? = nil) -> NSAppleEventDescriptor? {
        attempt(source, cacheKey: cacheKey).result
    }

    /// The result, or the AppleScript error number (-1712: timed out; -2753: a term the app's
    /// dictionary does not define, so it ran as an undefined variable).
    static func attempt(_ source: String, cacheKey: String? = nil) -> (result: NSAppleEventDescriptor?, error: Int?) {
        let script: NSAppleScript
        if let k = cacheKey, let s = cache[k] { script = s } else {
            guard let s = NSAppleScript(source: source) else { return (nil, nil) }
            if let k = cacheKey { cache[k] = s }
            script = s
        }
        var err: NSDictionary?
        let r = script.executeAndReturnError(&err)
        guard let err else { return (r, nil) }
        return (nil, (err[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0)
    }

    static let undefinedTerm = -2753

    /// Quotes a value for an AppleScript string literal.
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Runs command-line tools (tmux, herdr, cmux) with a hard timeout. Worker thread only.
enum Command {
    struct Result { let status: Int32; let out: String; let err: String }

    static func find(_ name: String, extra: [String] = []) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin"]
        return (extra + dirs.map { "\($0)/\(name)" }).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ path: String, _ args: [String], env extra: [String: String] = [:], timeout: Double = 1.5) -> Result? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        // Never let our own context leak into another tool's idea of "the current pane".
        for k in env.keys where k.hasPrefix("TMUX") || k.hasPrefix("HERDR_") || k.hasPrefix("CMUX_") { env[k] = nil }
        extra.forEach { env[$0.key] = $0.value }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let pid = p.processIdentifier
        let killer = DispatchWorkItem { if p.isRunning { p.terminate(); kill(pid, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); errDone.signal() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        p.waitUntilExit()
        killer.cancel()
        return Result(status: p.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
    }

    static func json(_ r: Result?) -> Any? {
        guard let r, r.status == 0, let d = r.out.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }
}

/// The GUI app hosting a process: walk up its parents to the first regular app.
enum HostApp {
    static func of(pid: Int32) -> NSRunningApplication? {
        var cur = pid
        for _ in 0..<20 where cur > 1 {
            if let app = NSRunningApplication(processIdentifier: cur), app.activationPolicy == .regular { return app }
            guard let e = ProcInfo.info(cur) else { return nil }
            cur = e.ppid
        }
        return nil
    }
}

/// A single long-lived thread that runs closures in order. NSAppleScript is not thread-safe, so
/// every script runs on one such thread (`Terminals.worker`), never on the main thread.
final class ScriptThread {
    private var jobs: [() -> Void] = []
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)

    init(name: String) {
        let t = Thread { [unowned self] in
            while true {
                self.ready.wait()
                self.lock.lock()
                let job = self.jobs.isEmpty ? nil : self.jobs.removeFirst()
                self.lock.unlock()
                autoreleasepool { job?() }
            }
        }
        t.name = name
        t.qualityOfService = .userInitiated
        t.start()
    }

    func run(_ job: @escaping () -> Void) {
        lock.lock(); jobs.append(job); lock.unlock()
        ready.signal()
    }
}

/// How long since your last keystroke or mouse movement anywhere.
enum Presence {
    static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}

// MARK: - New panes (Search resumes a session that is no longer open)

extension TerminalAdapter {
    func newPane(in dir: String, typing command: String) -> Bool { false }
}

extension Terminals {
    /// Opens a new pane in `dir` through the adapter and types `command` into it, unless `deadline` has
    /// passed by then. Allowed and running, the terminal is scripted straight away on the worker.
    /// Otherwise it is launched and its Automation permission asked for on the prompt thread first:
    /// both can take a while, and another app's unanswered prompt can hold that thread up, so the
    /// deadline is checked again after them. `done` (main thread) says whether the pane opened.
    func newPane(_ a: TerminalAdapter, in dir: String, typing command: String, until deadline: Date,
                 done: @escaping (Bool) -> Void) {
        let open = {
            self.worker.run {
                let ok = Date() < deadline && a.newPane(in: dir, typing: command)
                DispatchQueue.main.async { done(ok) }
            }
        }
        guard let b = a.scriptedBundleID, !(Automation.cached(b) == .granted && Terminals.isRunning(b)) else { open(); return }
        prompter.run {
            let ready = Date() < deadline && Terminals.launchIfNeeded(b)
            let mine = ready && Automation.startAsking(b)
            let status = ready ? Automation.check(b, ask: true) : .notRunning
            if mine { Automation.doneAsking(b) }
            guard status == .granted, Date() < deadline else { DispatchQueue.main.async { done(false) }; return }
            open()
        }
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.isFinishedLaunching == true
    }

    /// Prompt thread. Launches the app (without bringing it forward) unless it runs, and waits up to
    /// 10 s for it to finish launching. False if it is not installed or never got there.
    private static func launchIfNeeded(_ bundleID: String) -> Bool {
        func app() -> NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first }
        if isRunning(bundleID) { return true }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        if app() == nil {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            DispatchQueue.main.async { NSWorkspace.shared.openApplication(at: url, configuration: cfg) }
        }
        for _ in 0..<50 {
            if app()?.isFinishedLaunching == true { return true }
            usleep(200_000)
        }
        return false
    }
}
