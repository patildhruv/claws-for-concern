import AppKit
import SwiftUI

// MARK: - The ledger

/// A session that ended with its terminal (the terminal quit or crashed, the Mac restarted), kept
/// so it can be resumed once the terminal reopens its tab.
struct RestoreEntry: Codable, Equatable {
    var sessionId: String
    var adapter: String
    var pane: String
    /// The folder Claude was started in, from the kernel: the reopened shell's own working directory.
    var folder: String
    var title: String
    var endedTs: Double
    /// SessionEnd's reason ("other"), or "vanished" when the process went without one.
    var reason: String
    /// The terminal process the session ran under, and its start time: restore needs it gone.
    var hostPid: Int32?
    var hostStart: Double?
    /// The terminal launch this entry was offered at. That launch is its only chance.
    var launch: Double?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id", adapter, pane, folder, title, endedTs = "ended_ts", reason
        case hostPid = "host_pid", hostStart = "host_start", launch
    }
}

/// `restore.json`. An entry goes once it is resumed or dismissed, when its pane hosts another
/// session, when its terminal outlives it, after the launch that was its chance, or after a week.
struct RestoreLedger: Codable, Equatable {
    static let maxAge: Double = 7 * 24 * 3600
    var entries: [RestoreEntry] = []

    /// Anything but a UUID for a session ID is dropped: the ID ends up typed into a shell.
    static func load(_ url: URL = Paths.restore) -> RestoreLedger {
        guard let d = try? Data(contentsOf: url), var l = try? JSONDecoder().decode(RestoreLedger.self, from: d) else {
            return RestoreLedger()
        }
        l.entries.removeAll { !ResumeRequest.isSessionID($0.sessionId) }
        return l
    }

    private func save(_ url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(self) else { return }
        try? d.write(to: url, options: .atomic)
    }

    /// Load, change and save under `restore.lock`, reading the file again inside the lock: the app
    /// and the command line may both write it. Waits up to a second for the lock; nil if it never came.
    @discardableResult
    static func update(_ url: URL = Paths.restore, _ change: (inout RestoreLedger) -> Void) -> RestoreLedger? {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = Darwin.open(dir.appendingPathComponent("restore.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var locked = false
        for _ in 0..<100 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            usleep(10_000)
        }
        guard locked else { return nil }
        defer { flock(fd, LOCK_UN) }
        let before = load(url)
        var l = before
        change(&l)
        if l != before { l.save(url) }
        return l
    }

    /// One entry per session, and one per pane: the last session to end in a pane is the one to
    /// bring back there.
    mutating func add(_ e: RestoreEntry) {
        entries.removeAll { $0.sessionId == e.sessionId || ($0.adapter == e.adapter && $0.pane == e.pane && $0.endedTs <= e.endedTs) }
        guard !entries.contains(where: { $0.adapter == e.adapter && $0.pane == e.pane }) else { return }
        entries.append(e)
    }

    mutating func remove(where drop: (RestoreEntry) -> Bool) { entries.removeAll(where: drop) }

    mutating func expire(now: Double) { remove { now - $0.endedTs > RestoreLedger.maxAge } }
}

// MARK: - The rules (pure, self-tested)

enum RestorePlan {
    /// The running terminal process a restore would type into.
    struct Launch: Equatable {
        /// When it launched (epoch seconds).
        let at: Double
        /// Claws saw it launch, or started within `observeWindow` after it.
        let observed: Bool
        /// Its process: listings and typing for this launch refuse any other Ghostty process.
        var pid: Int32? = nil
    }

    static let observeWindow: Double = 120
    /// A tab the relaunch reopened has a shell that started with the terminal.
    static let shellWindow: Double = 60
    /// A terminal still running this long after a session ended did not go away with it.
    static let hostWindow: Double = 12
    /// You typed or moved the pointer this recently: you may be typing in that tab.
    static let activeWindow: Double = 3

    enum Verdict: Equatable {
        case resume, expired, otherLaunch, noHost, hostRunning, notRelaunched, launchMissed, noPane, busy(String),
             notFromLaunch, otherFolder(String)

        var why: String {
            switch self {
            case .resume: return "resume"
            case .expired: return "skip: ended more than a week ago"
            case .otherLaunch: return "skip: it was offered at an earlier launch"
            case .noHost: return "skip: the terminal it ran in is not known"
            case .hostRunning: return "skip: the terminal it ran in is still running (tab closed, or claude ended in an open tab)"
            case .notRelaunched: return "skip: this terminal was already running when the session ended"
            case .launchMissed: return "skip: Claws was not there when this terminal launched"
            case .noPane: return "skip: no tab with that ID (closed, or not reopened)"
            case .busy(let why): return "skip: \(why)"
            case .notFromLaunch: return "skip: the tab's shell did not start with this launch"
            case .otherFolder(let f): return "skip: the tab's shell is in another folder (\(f))"
            }
        }
    }

    /// Type only when the terminal process the session ran under is gone (`hostAlive` false), the
    /// terminal running now launched after the session ended and Claws saw that launch, and the tab
    /// with the entry's ID has its own login shell waiting at the prompt, started with that launch,
    /// in the session's folder. `hostAlive`: nil when the entry does not name its terminal.
    static func verdict(_ e: RestoreEntry, panes: [RestorePane], launch: Launch, hostAlive: Bool?, now: Double) -> Verdict {
        if now - e.endedTs > RestoreLedger.maxAge { return .expired }
        if let l = e.launch, l != launch.at { return .otherLaunch }
        guard let hostAlive else { return .noHost }
        if hostAlive { return .hostRunning }
        guard launch.at > e.endedTs else { return .notRelaunched }
        guard launch.observed else { return .launchMissed }
        guard let p = panes.first(where: { $0.id == e.pane }) else { return .noPane }
        if let problem = p.problem { return .busy(problem) }
        guard let s = p.started, s >= launch.at - 1, s <= launch.at + shellWindow else { return .notFromLaunch }
        guard let cwd = p.cwd, cwd == e.folder else { return .otherFolder(p.cwd ?? "unknown") }
        return .resume
    }

    /// Claws saw the launch, or started at most `observeWindow` after it (at login, say).
    static func observed(launchAt: Double, sawLaunch: Bool, startedAt: Double) -> Bool {
        sawLaunch || (startedAt >= launchAt - 5 && startedAt - launchAt <= observeWindow)
    }

    /// After a settled look at `launch`: an entry that cannot be resumed and ended before it has had
    /// its one chance, and so has one offered at an earlier launch.
    static func spent(_ e: RestoreEntry, _ v: Verdict, launch: Launch) -> Bool {
        switch v {
        case .resume: return false
        case .otherLaunch, .expired, .notRelaunched: return true
        default: return e.endedTs < launch.at
        }
    }

    /// A launch that never settled, or reopened none of the remembered tabs, decides nothing about
    /// them but still was their chance: these get stamped with it, so the next launch drops them.
    static func toStamp(_ entries: [RestoreEntry], launch: Launch) -> [RestoreEntry] {
        entries.filter { $0.launch == nil && $0.endedTs < launch.at }
    }

    /// One tab's turn, decided right before typing into it. Whether you are typing in it is decided by
    /// the typing script itself, so the tab in front cannot change in between.
    enum Step: Equatable {
        case type(command: String, foreground: Int32)
        /// Look again in a moment: the terminal did not answer.
        case later
        case drop(String)
    }

    /// `panes` nil: the terminal did not answer this time, which says nothing about the tab.
    static func step(_ e: RestoreEntry, panes: [RestorePane]?, launch: Launch, hostAlive: Bool?, now: Double, template: String) -> Step {
        guard let panes else { return .later }
        let v = verdict(e, panes: panes, launch: launch, hostAlive: hostAlive, now: now)
        guard v == .resume else { return .drop(v.why) }
        guard let command = command(template, e) else { return .drop("its session ID is not a UUID") }
        guard let pid = panes.first(where: { $0.id == e.pane })?.pid else { return .drop("its shell is not known") }
        return .type(command: command, foreground: pid)
    }

    /// After typing: try again only when nothing was sent. An error part way may have sent keys.
    enum After: Equatable { case done, retry, forget }

    static func after(_ r: TypeResult) -> After {
        switch r {
        case .typed: return .done
        case .moved, .busy: return .retry
        case .failed: return .forget
        }
    }

    /// The ledger entries `remember` adds while the terminal already runs again: SessionEnd or a reap
    /// landing after a launch's restore looked. That launch is their only one (`launch`), as if offered.
    static func stampedForRunning(_ entries: [RestoreEntry], runningLaunch: Double?, hostAlive: (RestoreEntry) -> Bool?) -> [RestoreEntry] {
        guard let runningLaunch else { return entries }
        return entries.map { e in
            var e = e
            if e.launch == nil, hostAlive(e) == false { e.launch = runningLaunch }
            return e
        }
    }

    /// The terminal process the session ran under still runs `hostWindow` after the end.
    static func hostStayed(_ e: RestoreEntry, now: Double, alive: (Int32, Double?) -> Bool) -> Bool {
        guard let pid = e.hostPid else { return false }
        return now - e.endedTs >= hostWindow && alive(pid, e.hostStart)
    }

    /// You pressed a key this recently (`idle`, seconds; moving the pointer or clicking Resume is not
    /// typing): the typing script then sends nothing to a tab that is focused in front.
    static func recentlyTyped(idle: Double) -> Bool { idle < activeWindow }

    /// The command to type, or nil when the session ID is not a UUID.
    static func command(_ template: String, _ e: RestoreEntry) -> String? {
        ResumeRequest.isSessionID(e.sessionId) ? ResumeCommand.expand(template, id: e.sessionId) : nil
    }
}

/// Waits for a relaunched terminal to settle. The fast path, the same list twice with every
/// remembered tab at its shell, needs at least one remembered tab present; otherwise the list must
/// stay the same 5 s (10 s when none of them is there), and after `limit` it gives up.
struct RestoreWait {
    enum Result: Equatable {
        case waiting
        /// Remembered tabs are there; plan.
        case settled
        /// None of the remembered tabs came back; plan (they are not coming).
        case unchanged
        /// Never settled: a plan now would be premature, so nothing is decided.
        case gaveUp
    }

    let start: Double
    let limit: Double
    private var last: [RestorePane]?
    private var since: Double = 0

    init(start: Double, limit: Double = 30) {
        self.start = start
        self.limit = limit
    }

    mutating func look(_ panes: [RestorePane]?, at t: Double, watching ids: Set<String>) -> Result {
        if t - start >= limit { return .gaveUp }
        guard let panes else { last = nil; return .waiting }
        if panes != last { last = panes; since = t; return .waiting }
        guard t - start >= 1.5 else { return .waiting }
        let watched = panes.filter { ids.contains($0.id) }
        if watched.isEmpty { return t - since >= 10 ? .unchanged : .waiting }
        return watched.allSatisfy(\.atShell) || t - since >= 5 ? .settled : .waiting
    }
}

// MARK: - The coordinator

/// Notices a terminal relaunching (or launched just before Claws started), waits for its tabs to
/// settle, and offers once to resume the sessions those tabs were running. Main thread; terminal
/// I/O on `Terminals.worker`.
final class Restorer {
    static let shared = Restorer()
    weak var tracker: Tracker?
    /// Command-line overrides: resume without asking, the command to type.
    var withoutAsking: Bool?
    var commandOverride: String?
    /// No windows (the CLI): report the question instead of asking it.
    var headless = false
    /// `--restore-run` without `--yes`: decide and report, never write the ledger or type.
    var readOnly = false
    /// Also print the log lines (the CLI).
    var echo = false
    /// Seconds since your last keystroke; tests replace it (`--assume-active`).
    var idleSeconds: () -> Double = { Presence.keyboardIdleSeconds }
    /// The CLI's `--restore-on`: act as if Restore were on in this process, leaving the setting alone.
    var forceOn = false
    private var enabled: Bool { forceOn || Settings.restore }
    /// When Claws started: a terminal launched up to 2 minutes earlier still counts as observed.
    let startedAt = Date().timeIntervalSince1970
    /// Terminal processes seen launching while Claws ran.
    private var sawLaunch = Set<pid_t>()
    /// Adapters with a restore under way: one at a time, one question at a time.
    private var underWay = Set<String>()
    /// Bumped when a terminal quits: its settle wait and deferred typing stop.
    private var generation: [String: Int] = [:]
    private var prompt: RestorePrompt?
    private var promptFor: String?
    private let terminals = Terminals.shared

    var adapters: [TerminalAdapter] { terminals.adapters.filter(\.restoresPanes) }
    var isIdle: Bool { underWay.isEmpty }

    func start() {
        let now = Date().timeIntervalSince1970
        let stale = RestoreLedger.load().entries.filter {
            now - $0.endedTs > RestoreLedger.maxAge || RestorePlan.hostStayed($0, now: now, alive: ProcInfo.isAlive)
        }
        if !stale.isEmpty {
            forget(stale, why: "a week old, or the terminal it ran in is still running")
        }
        clearIfOff()
        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in self?.clearIfOff() }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            for a in self.adapters where a.appBundleID == app.bundleIdentifier {
                self.sawLaunch.insert(app.processIdentifier)
                // A quick quit and relaunch (an update's restart) can beat the old sessions' SessionEnd
                // to the ledger: with nothing remembered yet, look once more a moment later.
                if !self.begin(a, why: "launched") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.begin(a, why: "launched") }
                }
            }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            for a in self.adapters where a.appBundleID == id {
                self.generation[a.id, default: 0] += 1
                self.underWay.remove(a.id)
                if self.promptFor == a.id {
                    // It quit with the question up: that launch was their chance.
                    self.prompt?.close()
                    self.prompt = nil
                    self.promptFor = nil
                }
            }
        }
        for a in adapters where running(a) != nil { begin(a, why: "was running when Claws started") }
    }

    /// The CLI's `--restore-run`: what the app does when a terminal launches, for each one running.
    func restoreNow() -> Bool {
        var any = false
        for a in adapters where running(a) != nil { any = begin(a, why: "asked to restore") || any }
        return any
    }

    func running(_ a: TerminalAdapter) -> NSRunningApplication? {
        guard let b = a.appBundleID else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: b).first { !$0.isTerminated }
    }

    /// Restore switched off: Claws stops watching launches, so nothing remembered may come back when
    /// it is switched on again, launches later.
    private func clearIfOff() {
        guard !enabled else { return }
        let all = RestoreLedger.load().entries
        if !all.isEmpty { forget(all, why: "Restore is off") }
    }

    // Tracker hooks.

    /// Sessions that ended with their tab: kept until their terminal reopens it. One that lands while
    /// its terminal already runs again (a late SessionEnd, a reap after that launch's restore looked)
    /// gets that launch as its only one: Claws cannot see launches it was not running for.
    func remember(_ entries: [RestoreEntry]) {
        let checked = entries.filter { ResumeRequest.isSessionID($0.sessionId) && $0.hostPid != nil }
        guard !checked.isEmpty, enabled else { return }
        let valid = Dictionary(grouping: checked, by: \.adapter).flatMap { aid, group in
            RestorePlan.stampedForRunning(group, runningLaunch: terminals.adapter(id: aid).flatMap(running)?.launchDate?.timeIntervalSince1970,
                                          hostAlive: hostAlive)
        }
        write("remembered " + valid.map { "\($0.sessionId.prefix(8)) (\($0.reason), pane \($0.pane.prefix(8))"
            + ($0.launch == nil ? ")" : "; its terminal already runs again: for that launch only)") }.joined(separator: ", ")) { l in
            valid.forEach { l.add($0) }
        }
        // Cmd-W, or claude ending in a tab that stays open: the terminal outlives the session.
        DispatchQueue.main.asyncAfter(deadline: .now() + RestorePlan.hostWindow + 0.5) { [weak self] in
            let now = Date().timeIntervalSince1970
            let stayed = valid.filter { RestorePlan.hostStayed($0, now: now, alive: ProcInfo.isAlive) }
            guard !stayed.isEmpty else { return }
            self?.write("forgot " + stayed.map { "\($0.sessionId.prefix(8))" }.joined(separator: ", ")
                        + ": the terminal it ran in is still running (tab closed, or claude ended in an open tab)") { l in
                l.remove { e in stayed.contains { $0.sessionId == e.sessionId && $0.endedTs == e.endedTs } }
            }
        }
    }

    /// Live sessions, on every reload: an entry whose session is back (resumed), or whose pane now
    /// hosts another session, is done.
    func live(_ sessions: [(id: String, adapter: String, pane: String?)]) {
        let entries = RestoreLedger.load().entries
        guard !entries.isEmpty else { return }
        let ids = Set(sessions.map(\.id))
        let panes = Set(sessions.compactMap { s in s.pane.map { "\(s.adapter)|\($0)" } })
        let gone = entries.filter { ids.contains($0.sessionId) || panes.contains("\($0.adapter)|\($0.pane)") }
        guard !gone.isEmpty else { return }
        write("forgot " + gone.map { "\($0.sessionId.prefix(8))" + (ids.contains($0.sessionId) ? " (running again)" : " (its tab hosts another session)") }
            .joined(separator: ", ")) { l in l.remove { e in gone.contains { $0.sessionId == e.sessionId } } }
    }

    // The restore itself.

    @discardableResult
    private func begin(_ a: TerminalAdapter, why: String) -> Bool {
        guard enabled, !underWay.contains(a.id), let app = running(a), let at = app.launchDate?.timeIntervalSince1970 else { return false }
        tracker?.reapNow()
        let mine = RestoreLedger.load().entries.filter { $0.adapter == a.id }
        guard !mine.isEmpty else { return false }
        let launch = RestorePlan.Launch(at: at, observed: RestorePlan.observed(launchAt: at, sawLaunch: sawLaunch.contains(app.processIdentifier),
                                                                               startedAt: startedAt),
                                        pid: app.processIdentifier)
        guard launch.observed else {
            // Claws was not there when this terminal started: its tabs have been yours since.
            let spent = mine.filter { $0.endedTs < at }
            if !spent.isEmpty { spend(spent, why: "\(a.name) launched before Claws could restore its tabs") }
            return true
        }
        let gen = generation[a.id, default: 0] + 1
        generation[a.id] = gen
        underWay.insert(a.id)
        log("\(a.name) \(why): waiting for its tabs to settle")
        let ids = Set(mine.map(\.pane))
        var wait = RestoreWait(start: Date().timeIntervalSince1970)
        func look() {
            terminals.worker.run {
                if let b = a.scriptedBundleID { Automation.refresh(b) }
                let panes = self.permitted(a) ? a.restorablePanes(app: launch.pid) : nil
                DispatchQueue.main.async {
                    guard self.generation[a.id] == gen else { return }
                    switch wait.look(panes, at: Date().timeIntervalSince1970, watching: ids) {
                    case .waiting:
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if self.generation[a.id] == gen { look() } }
                    case .gaveUp:
                        self.stamp(a, launch, why: "its tabs never settled, or it may not be scripted")
                        self.underWay.remove(a.id)
                    case .unchanged:
                        self.stamp(a, launch, why: "none of their tabs came back")
                        self.underWay.remove(a.id)
                    case .settled:
                        self.plan(a, panes ?? [], launch: launch, gen: gen)
                    }
                }
            }
        }
        look()
        return true
    }

    private func permitted(_ a: TerminalAdapter) -> Bool {
        a.scriptedBundleID.map { Automation.cached($0) == .granted } ?? true
    }

    /// A launch that decides nothing about its entries is still their one chance: they are kept for
    /// this launch only (stamped), and the next launch drops them. Ones offered at an earlier launch go now.
    private func stamp(_ a: TerminalAdapter, _ launch: RestorePlan.Launch, why: String) {
        let mine = RestoreLedger.load().entries.filter { $0.adapter == a.id }
        let old = mine.filter { $0.launch != nil && $0.launch != launch.at }
        if !old.isEmpty { forget(old, why: "offered at an earlier launch") }
        let ids = Set(RestorePlan.toStamp(mine, launch: launch).map(\.sessionId))
        guard !ids.isEmpty else { log("\(a.name): \(why); nothing decided"); return }
        write("\(a.name): \(why); kept for this launch only: " + ids.map { "\($0.prefix(8))" }.sorted().joined(separator: ", ")) { l in
            for i in l.entries.indices where ids.contains(l.entries[i].sessionId) && l.entries[i].launch == nil { l.entries[i].launch = launch.at }
        }
    }

    private func hostAlive(_ e: RestoreEntry) -> Bool? {
        e.hostPid.map { ProcInfo.isAlive(pid: $0, start: e.hostStart) }
    }

    private func plan(_ a: TerminalAdapter, _ panes: [RestorePane], launch: RestorePlan.Launch, gen: Int) {
        // A session whose process vanished without SessionEnd joins the ledger now, not in 10 s.
        tracker?.reapNow()
        let now = Date().timeIntervalSince1970
        var ready: [RestoreEntry] = []
        var spent: [RestoreEntry] = []
        for e in RestoreLedger.load().entries where e.adapter == a.id {
            let v = RestorePlan.verdict(e, panes: panes, launch: launch, hostAlive: hostAlive(e), now: now)
            log("\(e.sessionId.prefix(8)) \"\(e.title)\": \(v.why)")
            if v == .resume { ready.append(e) } else if RestorePlan.spent(e, v, launch: launch) { spent.append(e) }
        }
        if !spent.isEmpty { spend(spent, why: "had their chance at this launch") }
        guard !ready.isEmpty else { underWay.remove(a.id); return }
        // This launch is their one chance, asked or not.
        let ids = Set(ready.map(\.sessionId))
        write(nil) { l in for i in l.entries.indices where ids.contains(l.entries[i].sessionId) { l.entries[i].launch = launch.at } }
        let n = ready.count
        let text = n == 1 ? "\(a.name) reopened a tab that was running Claude Code. Resume it?"
            : "\(a.name) reopened \(n) tabs that were running Claude Code. Resume them?"
        let items = ready.map { (title: $0.title, folder: ($0.folder as NSString).lastPathComponent) }
        if withoutAsking ?? Settings.restoreWithoutAsking, !readOnly {
            resume(a, ready, launch: launch, gen: gen, until: now + RestorePrompt.timeout)
            return
        }
        if headless || readOnly {
            log("would ask: \(text) " + items.map { "\"\($0.title)\" in \($0.folder)" }.joined(separator: ", "))
            underWay.remove(a.id)
            return
        }
        promptFor = a.id
        prompt = RestorePrompt(message: text, items: items) { [weak self] answer in
            guard let self else { return }
            self.prompt = nil
            self.promptFor = nil
            switch answer {
            case .resume(let always):
                if always { Settings.set(true, Settings.Key.restoreWithoutAsking) }
                self.resume(a, ready, launch: launch, gen: gen, until: Date().timeIntervalSince1970 + RestorePrompt.timeout)
            case .notNow:
                self.forget(ready, why: "not now")
                self.underWay.remove(a.id)
            case .timedOut:
                self.log("no answer in 2 minutes: not asking again (they stay for this launch only)")
                self.underWay.remove(a.id)
            }
        }
        prompt?.show()
    }

    /// Types the resume command into one tab at a time, each decided right before its typing: the
    /// tabs are listed again from this launch's Ghostty process, and the typing script itself checks
    /// that the checked shell is still in front and, if you pressed a key in the last 3 s, that the tab
    /// is not the one you are in. Nothing sent ("moved", "busy", no answer): tried again every 2 s
    /// until `deadline`. An error part way may have sent keys: that tab is never typed into again.
    private func resume(_ a: TerminalAdapter, _ queue: [RestoreEntry], later: [RestoreEntry] = [], launch: RestorePlan.Launch,
                        gen: Int, until deadline: Double) {
        guard generation[a.id] == gen else { return }
        guard let e = queue.first else {
            guard !later.isEmpty else { underWay.remove(a.id); return }
            guard Date().timeIntervalSince1970 < deadline else {
                forget(later, why: "still could not type after 2 minutes (you kept typing there, or the terminal did not answer)")
                underWay.remove(a.id)
                return
            }
            log("waiting: " + later.map { "\($0.sessionId.prefix(8))" }.joined(separator: ", "))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.resume(a, later, launch: launch, gen: gen, until: deadline) }
            return
        }
        let rest = Array(queue.dropFirst())
        let template = commandOverride ?? Settings.resumeCommand
        terminals.worker.run {
            let panes = a.restorablePanes(app: launch.pid)
            let step = RestorePlan.step(e, panes: panes, launch: launch, hostAlive: self.hostAlive(e), now: Date().timeIntervalSince1970,
                                        template: template)
            var result: TypeResult?
            var idle = 0.0
            if case let .type(command, shell) = step, let pid = launch.pid {
                idle = self.idleSeconds()
                result = a.type(command, into: e.pane, app: pid, ifForeground: shell, deferIfFocused: RestorePlan.recentlyTyped(idle: idle))
            }
            DispatchQueue.main.async {
                let id = "\(e.sessionId.prefix(8))"
                let typing = String(format: "last keystroke %.1f s ago, any input %.1f s ago", idle, Presence.idleSeconds)
                switch (step, result.map(RestorePlan.after)) {
                case (.later, _):
                    self.log("\(id): later (no answer from \(a.name))")
                    self.resume(a, rest, later: later + [e], launch: launch, gen: gen, until: deadline)
                case (.drop(let why), _):
                    self.forget([e], why: "not resumed, " + why)
                    self.resume(a, rest, later: later, launch: launch, gen: gen, until: deadline)
                case (.type, .done?):
                    self.log("\(id): resumed in pane \(e.pane.prefix(8)) (\(typing))")
                    self.forget([e], why: nil)
                    self.resume(a, rest, later: later, launch: launch, gen: gen, until: deadline)
                case (.type, .retry?), (.type, nil):
                    self.log("\(id): nothing sent (" + (result == .busy ? "you are typing in that tab: \(typing)" : "its shell or its Ghostty changed") + ")")
                    self.resume(a, rest, later: later + [e], launch: launch, gen: gen, until: deadline)
                case (.type, .forget?):
                    self.forget([e], why: "typing failed part way (keys may have been sent); never typing into that tab again")
                    self.resume(a, rest, later: later, launch: launch, gen: gen, until: deadline)
                }
            }
        }
    }

    private func forget(_ entries: [RestoreEntry], why: String?) {
        let ids = Set(entries.map(\.sessionId))
        write(why.map { "forgot " + entries.map { "\($0.sessionId.prefix(8))" }.joined(separator: ", ") + ": " + $0 }) { l in
            l.remove { ids.contains($0.sessionId) }
        }
    }

    private func spend(_ entries: [RestoreEntry], why: String) {
        forget(entries, why: why)
    }

    /// Every ledger change goes through here: under the lock, never in a read-only run.
    private func write(_ message: String?, _ change: (inout RestoreLedger) -> Void) {
        if readOnly {
            if let message { log("would have " + message) }
            return
        }
        if RestoreLedger.update(Paths.restore, change) == nil { log("restore.json is locked by another process; skipped: \(message ?? "an update")"); return }
        if let message { log(message) }
    }

    /// A read-only run leaves claws.log alone too.
    private func log(_ msg: String) {
        if !readOnly { AppLog.write("restore: " + msg) }
        if echo { print("restore: " + msg) }
    }
}

// MARK: - The question

/// The one question a restore asks: a small floating panel that leaves the keyboard with the
/// terminal you just reopened, never blocks anything while it waits, and goes after 2 minutes.
final class RestorePrompt: NSObject, NSWindowDelegate {
    enum Answer { case resume(always: Bool), notNow, timedOut }
    static let timeout: Double = 120
    private let panel: NSPanel
    private var answer: ((Answer) -> Void)?
    private var timer: Timer?

    /// `items`: what Resume brings back, each session's title and folder name.
    init(message: String, items: [(title: String, folder: String)], answer: @escaping (Answer) -> Void) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
                        styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        self.answer = answer
        panel.title = "Claws for Concern"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let host = NSHostingView(rootView: RestorePromptView(message: message, items: items) { [weak self] resume, always in
            self?.finish(resume ? .resume(always: always) : .notNow)
        })
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        timer = Timer.scheduledTimer(withTimeInterval: RestorePrompt.timeout, repeats: false) { [weak self] _ in self?.finish(.timedOut) }
    }

    func show() {
        panel.center()
        panel.orderFrontRegardless()
    }

    /// Without an answer (the terminal quit meanwhile).
    func close() {
        answer = nil
        timer?.invalidate()
        panel.close()
    }

    private func finish(_ a: Answer) {
        let f = answer
        answer = nil
        timer?.invalidate()
        panel.close()
        f?(a)
    }

    /// The close button means Not Now.
    func windowWillClose(_ notification: Notification) {
        let f = answer
        answer = nil
        timer?.invalidate()
        f?(.notNow)
    }
}

private struct RestorePromptView: View {
    let message: String
    let items: [(title: String, folder: String)]
    let answer: (Bool, Bool) -> Void
    @State private var always = false
    static let shown = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(message).font(.headline).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(items.prefix(Self.shown).enumerated()), id: \.offset) { _, it in
                        (Text(it.title) + Text("  ·  \(it.folder)").foregroundColor(.secondary))
                            .font(.callout).lineLimit(1).truncationMode(.tail)
                    }
                    if items.count > Self.shown {
                        Text("and \(items.count - Self.shown) more").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Toggle("Always resume without asking", isOn: $always)
            HStack {
                Spacer()
                Button("Not Now") { answer(false, false) }.keyboardShortcut(.cancelAction)
                Button("Resume") { answer(true, always) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}

// MARK: - Command line

/// `--restore-status`, `--restore-run` and `--watch`, for checking restore without the menu bar app.
/// `--bundle-id ID` points the Ghostty adapter at a copy of Ghostty with its own bundle ID, so tests
/// never quit or type into the Ghostty you work in.
enum RestoreCLI {
    static func option(_ name: String, _ args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Before anything touches `Terminals.shared`.
    private static func setUp(_ args: [String]) {
        if let id = option("--bundle-id", args) { GhosttyAdapter.target = id }
        // Each step as it happens, also when the output goes to a file.
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        // Tests: you count as typing for this many seconds, then as away.
        if let s = option("--assume-active", args).flatMap(Double.init) {
            let until = Date().addingTimeInterval(s)
            Restorer.shared.idleSeconds = { Date() < until ? 0 : 3600 }
        }
        // Restore switched off in Settings, but a test needs it in this process only.
        Restorer.shared.forceOn = args.contains("--restore-on")
    }

    /// `--watch` writes the ledger and app state as the app does: only into a data folder of its own.
    static func isScratchHome(_ env: [String: String], real: URL = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent("Library/Application Support/Claws for Concern")) -> Bool {
        guard let h = env["CLAWS_HOME"], !h.isEmpty else { return false }
        return !sameFolder(h, real.path)
    }

    /// The same folder, through symlinks too: the same device and inode when both exist.
    static func sameFolder(_ a: String, _ b: String) -> Bool {
        var sa = stat(), sb = stat()
        if stat(a, &sa) == 0, stat(b, &sb) == 0 { return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino }
        return URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }

    /// `--restore-run --yes` types into terminals and writes the ledger: never alongside a running
    /// Claws on the same data unless it has a data folder of its own.
    static func mayRunAlongside(appRunning: Bool, env: [String: String]) -> Bool {
        !appRunning || isScratchHome(env)
    }

    /// Another process of this app (the menu bar app) is running.
    static var appRunning: Bool {
        let me = getpid()
        return NSRunningApplication.runningApplications(withBundleIdentifier: ResumeRequest.appID)
            .contains { $0.processIdentifier != me && !$0.isTerminated }
    }

    /// The ledger, and for each restoring terminal that runs: what a restore would do with each
    /// entry now. Reads only.
    static func status(_ args: [String]) -> Int32 {
        setUp(args)
        let now = Date().timeIntervalSince1970
        print("Restore: \(Settings.restore ? "on" : "off") in Settings, \(Settings.restoreWithoutAsking ? "resumes without asking" : "asks first"). Types: \(Settings.resumeCommand)")
        let ledger = RestoreLedger.load()
        print("\n\(Paths.restore.path): \(ledger.entries.count) session\(ledger.entries.count == 1 ? "" : "s")")
        for e in ledger.entries.sorted(by: { $0.endedTs > $1.endedTs }) {
            let host = e.hostPid.map { "host \($0) \(ProcInfo.isAlive(pid: $0, start: e.hostStart) ? "running" : "gone")" } ?? "host unknown"
            print("  \(e.sessionId.prefix(8))  \(e.reason.padding(toLength: 9, withPad: " ", startingAt: 0)) ended \(age(now - e.endedTs)) ago  \(host)  \(e.adapter) pane \(e.pane.prefix(8))  \(e.folder)  \"\(e.title)\"")
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil)) ?? []
        let ended = files.filter { $0.pathExtension == "json" }.compactMap(SessionState.load).filter { $0.endedTs != nil }
        if !ended.isEmpty {
            print("Ended, waiting for the app to move them here: " + ended.map { "\($0.sessionId.prefix(8)) (\($0.endReason ?? "?"))" }.joined(separator: ", "))
        }
        for a in Terminals.shared.adapters where a.restoresPanes {
            let b = a.appBundleID ?? "?"
            print("\n\(a.name) (\(b)):")
            print("  " + (a.restoreProblem().map { "! " + $0 } ?? "reopens its tabs after quitting"))
            guard let app = Restorer.shared.running(a), let at = app.launchDate?.timeIntervalSince1970 else { print("  not running"); continue }
            Automation.refresh(b)
            guard Automation.cached(b) == .granted else { print("  not allowed to script it (Automation)"); continue }
            guard let panes = a.restorablePanes(app: nil) else { print("  could not list its tabs (needs Ghostty 1.4 or later, done launching)"); continue }
            let launch = RestorePlan.Launch(at: at, observed: RestorePlan.observed(launchAt: at, sawLaunch: false, startedAt: now))
            print("  pid \(app.processIdentifier), launched \(age(now - at)) ago (\(launch.observed ? "within" : "more than") 2 minutes before this check), \(panes.count) terminal\(panes.count == 1 ? "" : "s")")
            for p in panes {
                let started = p.started.map { String(format: "%+.0f s", $0 - at) } ?? "?"
                print("    \(p.id.prefix(8))  \(p.foreground.padding(toLength: 8, withPad: " ", startingAt: 0)) started \(started)  \(p.problem ?? "login shell at its prompt")  \(p.cwd ?? "?")")
            }
            for e in ledger.entries where e.adapter == a.id {
                let alive = e.hostPid.map { ProcInfo.isAlive(pid: $0, start: e.hostStart) }
                print("  \(e.sessionId.prefix(8)) -> \(RestorePlan.verdict(e, panes: panes, launch: launch, hostAlive: alive, now: now).why)")
            }
        }
        return 0
    }

    /// The app's restore, now, for each restoring terminal that runs (only within 2 minutes of its
    /// launch, like the app). `--yes`: type without asking. Without it nothing is written or typed.
    /// `--command TEMPLATE`: type this instead of Settings'.
    static func run(_ args: [String]) -> Int32 {
        setUp(args)
        let r = Restorer.shared
        r.headless = true
        r.echo = true
        let yes = args.contains("--yes")
        if yes, !mayRunAlongside(appRunning: appRunning, env: ProcessInfo.processInfo.environment) {
            print("Claws for Concern is running: --restore-run --yes would act on its data. Quit it, or set CLAWS_HOME to a folder of its own.")
            return 2
        }
        r.readOnly = !yes
        r.withoutAsking = yes ? true : nil
        r.commandOverride = option("--command", args)
        guard r.restoreNow() else { print("Nothing to restore (no remembered sessions for a running terminal, or Restore is off)."); return 0 }
        let deadline = Date().addingTimeInterval(RestorePrompt.timeout + 60)
        while !r.isIdle, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        return r.isIdle ? 0 : 1
    }

    /// The tracker and restore without the UI (no Clawds, menu, recaps, sounds or notifications),
    /// for a restore round trip: it maps sessions to tabs, remembers the ones that end with their
    /// terminal, and restores on relaunch. Prints mapping changes and restore steps. Needs a data
    /// folder of its own (CLAWS_HOME).
    static func watch(_ args: [String]) -> Int32 {
        guard isScratchHome(ProcessInfo.processInfo.environment) else {
            print("--watch writes restore and app state: set CLAWS_HOME to a folder of its own, not the app's.")
            return 2
        }
        setUp(args)
        let seconds = Double(option("--seconds", args) ?? "") ?? 600
        let tracker = Tracker(headless: true)
        Terminals.shared.start()
        tracker.start()
        let r = Restorer.shared
        r.tracker = tracker
        r.headless = true
        r.echo = true
        r.withoutAsking = args.contains("--yes") ? true : nil
        r.commandOverride = option("--command", args)
        r.start()
        print("watching for \(Int(seconds)) s; data in \(Paths.root.path)")
        var shown: [String: String] = [:]
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            var now: [String: String] = [:]
            for (sid, a, pane) in tracker.sessionPanes() { now[sid] = "\(a) \(pane ?? "no pane yet")" }
            for (sid, v) in now.sorted(by: { $0.key < $1.key }) where shown[sid] != v { print("session \(sid.prefix(8)): \(v)") }
            for sid in shown.keys.sorted() where now[sid] == nil { print("session \(sid.prefix(8)): gone") }
            shown = now
        }
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        timer.invalidate()
        return 0
    }

    private static func age(_ s: Double) -> String {
        s < 120 ? "\(Int(s)) s" : s < 7200 ? "\(Int(s / 60)) min" : s < 172_800 ? "\(Int(s / 3600)) h" : "\(Int(s / 86400)) d"
    }
}
