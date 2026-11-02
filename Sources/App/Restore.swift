import AppKit
import SwiftUI

// MARK: - The ledger

/// A session that ended with its terminal tab (the terminal quit or crashed, the Mac restarted),
/// kept so it can be resumed once the terminal reopens that tab.
struct RestoreEntry: Codable, Equatable {
    var sessionId: String
    var adapter: String
    var pane: String
    /// The folder Claude was started in, which is the tab's working directory.
    var folder: String
    var title: String
    var endedTs: Double
    /// SessionEnd's reason ("other"), or "vanished" when the process went without one.
    var reason: String
    /// When the session's Claude process started: the terminal process that hosted it is one that
    /// launched before this.
    var claudeStart: Double?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id", adapter, pane, folder, title, endedTs = "ended_ts", reason, claudeStart = "claude_start"
    }
}

/// `restore.json`, written by the app only. An entry goes once it is resumed or dismissed, when its
/// pane hosts another session, after the relaunch that did not bring its tab back, or after a week.
struct RestoreLedger: Codable, Equatable {
    static let maxAge: Double = 7 * 24 * 3600
    var entries: [RestoreEntry] = []

    static func load(_ url: URL = Paths.restore) -> RestoreLedger {
        guard let d = try? Data(contentsOf: url), let l = try? JSONDecoder().decode(RestoreLedger.self, from: d) else {
            return RestoreLedger()
        }
        return l
    }

    func save(_ url: URL = Paths.restore) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }

    /// One entry per session, and one per pane: the last session to end in a pane is the one to
    /// bring back there.
    mutating func add(_ e: RestoreEntry) {
        entries.removeAll { $0.sessionId == e.sessionId || ($0.adapter == e.adapter && $0.pane == e.pane && $0.endedTs <= e.endedTs) }
        guard !entries.contains(where: { $0.adapter == e.adapter && $0.pane == e.pane }) else { return }
        entries.append(e)
    }

    /// True if anything went.
    @discardableResult
    mutating func remove(where drop: (RestoreEntry) -> Bool) -> Bool {
        let n = entries.count
        entries.removeAll(where: drop)
        return entries.count != n
    }

    @discardableResult
    mutating func expire(now: Double) -> Bool { remove { now - $0.endedTs > RestoreLedger.maxAge } }
}

// MARK: - The rules (pure, self-tested)

enum RestorePlan {
    enum Verdict: Equatable {
        case resume, noPane, busy(String), notReopened, otherFolder(String), expired

        var why: String {
            switch self {
            case .resume: return "resume"
            case .noPane: return "skip: no tab with that ID (closed, or not reopened)"
            case .busy(let p): return "skip: \(p) is running in that tab, not a shell"
            case .notReopened: return "skip: the tab was not reopened (its shell is older than the session's end)"
            case .otherFolder(let f): return "skip: the tab is in another folder (\(f))"
            case .expired: return "skip: ended more than a week ago"
            }
        }
    }

    /// The safety rules: type only into a tab that exists under the entry's pane ID, with a shell
    /// in front (nothing running), reopened since the session ended (its shell is newer), and in the
    /// session's folder.
    static func verdict(_ e: RestoreEntry, panes: [RestorePane], now: Double) -> Verdict {
        if now - e.endedTs > RestoreLedger.maxAge { return .expired }
        guard let p = panes.first(where: { $0.id == e.pane }) else { return .noPane }
        guard p.atShell else { return .busy(p.foreground.isEmpty ? "something" : p.foreground) }
        guard let started = p.started, started > e.endedTs else { return .notReopened }
        guard samePath(p.cwd, e.folder) else { return .otherFolder(p.cwd) }
        return .resume
    }

    /// The same folder once symlinks are resolved (/tmp is /private/tmp).
    static func samePath(_ a: String, _ b: String) -> Bool {
        !a.isEmpty && !b.isEmpty && canonical(a) == canonical(b)
    }

    static func canonical(_ path: String) -> String {
        var p = path
        if p.hasPrefix("file://"), let u = URL(string: p) { p = u.path }
        guard let r = realpath(p, nil) else { return (p as NSString).standardizingPath }
        defer { free(r) }
        return String(cString: r)
    }

    /// Every entry gets one chance per relaunch: one that ended before this terminal process
    /// started and cannot be resumed now never will be (its tab was not brought back).
    static func spent(_ e: RestoreEntry, _ v: Verdict, launched: Double?) -> Bool {
        guard let launched, e.endedTs < launched else { return false }
        return v != .resume
    }

    /// Restore is for a terminal that went away with its sessions (a quit, a crash, a restart), not
    /// for a tab closed with Cmd-W or a claude that ended in a tab that stayed open: then the
    /// terminal process that hosted the session, one launched before its Claude process, still runs.
    /// `launches`: launch times of the terminal's running processes.
    static func hostStayed(_ e: RestoreEntry, launches: [Double]) -> Bool {
        let start = e.claudeStart ?? e.endedTs
        return launches.contains { $0 < start }
    }

    static func command(_ template: String, _ e: RestoreEntry) -> String {
        template.replacingOccurrences(of: "{id}", with: e.sessionId)
    }
}

/// Waits for a relaunched terminal to settle: the same pane list two looks in a row with every
/// remembered pane at a shell, or the same list for 5 s (whatever runs there stays), or `limit` in all.
struct RestoreWait {
    let start: Double
    var limit: Double = 30
    private var last: [RestorePane]?
    private var since: Double = 0

    init(start: Double, limit: Double = 30) {
        self.start = start
        self.limit = limit
    }

    mutating func settled(_ panes: [RestorePane]?, at t: Double, watching ids: Set<String>) -> Bool {
        if t - start >= limit { return true }
        guard let panes else { last = nil; return false }
        if panes != last { last = panes; since = t; return false }
        guard t - start >= 1.5 else { return false }
        return panes.filter { ids.contains($0.id) }.allSatisfy(\.atShell) || t - since >= 5
    }
}

// MARK: - The coordinator

/// Notices a terminal relaunching (or already running when the app starts), waits for its tabs to
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
    /// Also print the log lines (the CLI).
    var echo = false
    private(set) var ledger = RestoreLedger.load()
    /// Adapters with a restore under way: one at a time, one question at a time.
    private var underWay = Set<String>()
    private var prompt: RestorePrompt?
    private var promptFor: String?
    private let terminals = Terminals.shared

    var adapters: [TerminalAdapter] { terminals.adapters.filter(\.restoresPanes) }

    func start() {
        if ledger.expire(now: Date().timeIntervalSince1970) { ledger.save() }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            for a in self.adapters where a.appBundleID == id {
                // A quick quit and relaunch (an update's restart) can beat the old sessions' SessionEnd
                // to the ledger: with nothing remembered yet, look once more a moment later.
                if !self.begin(a, why: "launched") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.begin(a, why: "launched") }
                }
            }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier,
                  let a = self.adapters.first(where: { $0.appBundleID == id }), self.promptFor == a.id else { return }
            // It quit with the question up: its tabs come back at the next launch, and so does the question.
            self.prompt?.close()
            self.prompt = nil
            self.promptFor = nil
            self.underWay.remove(a.id)
        }
        for a in adapters where running(a) != nil { begin(a, why: "running") }
    }

    /// The CLI's `--restore-run`: as if each restoring terminal that runs had just launched.
    func restoreNow() -> Bool {
        var any = false
        for a in adapters where running(a) != nil { any = begin(a, why: "asked to restore") || any }
        return any
    }

    var isIdle: Bool { underWay.isEmpty }

    func running(_ a: TerminalAdapter) -> NSRunningApplication? {
        guard let b = a.appBundleID else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: b).first { !$0.isTerminated }
    }

    // Tracker hooks.

    /// Sessions that ended with their tab: kept until their terminal reopens it.
    func remember(_ entries: [RestoreEntry]) {
        guard !entries.isEmpty else { return }
        entries.forEach { ledger.add($0) }
        ledger.save()
        log("remembered " + entries.map { "\($0.sessionId.prefix(8)) (\($0.reason), pane \($0.pane.prefix(8)))" }.joined(separator: ", "))
        dropIfHostStayed(entries)
    }

    /// Live sessions, on every reload: an entry whose session is back (resumed), or whose pane now
    /// hosts another session, is done.
    func live(_ sessions: [(id: String, adapter: String, pane: String?)]) {
        guard !ledger.entries.isEmpty else { return }
        let ids = Set(sessions.map(\.id))
        let panes = Set(sessions.compactMap { s in s.pane.map { "\(s.adapter)|\($0)" } })
        let gone = ledger.entries.filter { ids.contains($0.sessionId) || panes.contains("\($0.adapter)|\($0.pane)") }
        guard !gone.isEmpty else { return }
        ledger.remove { e in gone.contains(e) }
        ledger.save()
        log("forgot " + gone.map { "\($0.sessionId.prefix(8))" + (ids.contains($0.sessionId) ? " (running again)" : " (its tab hosts another session)") }
            .joined(separator: ", "))
    }

    /// How long after an entry is remembered its terminal must be gone. A quit takes a second or two
    /// after its sessions end; a session reaped as vanished after a crash or a restart finds it gone.
    static let hostWindow: Double = 12

    /// Cmd-W, or claude ending (Ctrl-C, a crash, a kill) in a tab that stays open: the terminal that
    /// hosted the session is still running a while later, so there is nothing to restore.
    private func dropIfHostStayed(_ entries: [RestoreEntry]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Restorer.hostWindow) { [weak self] in
            guard let self else { return }
            let stayed = entries.filter { e in
                self.terminals.adapter(id: e.adapter).map { RestorePlan.hostStayed(e, launches: self.launches($0)) } ?? false
            }
            guard self.ledger.remove(where: { stayed.contains($0) }) else { return }
            self.ledger.save()
            self.log("forgot " + stayed.map { "\($0.sessionId.prefix(8))" }.joined(separator: ", ")
                     + ": its terminal is still running (tab closed, or claude ended in an open tab)")
        }
    }

    private func launches(_ a: TerminalAdapter) -> [Double] {
        guard let b = a.appBundleID else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: b)
            .filter { !$0.isTerminated }.compactMap { $0.launchDate?.timeIntervalSince1970 }
    }

    // The restore itself.

    @discardableResult
    private func begin(_ a: TerminalAdapter, why: String) -> Bool {
        guard Settings.restore, !underWay.contains(a.id) else { return false }
        tracker?.reapNow()
        if ledger.expire(now: Date().timeIntervalSince1970) { ledger.save() }
        let ids = Set(ledger.entries.filter { $0.adapter == a.id }.map(\.pane))
        guard !ids.isEmpty else { return false }
        underWay.insert(a.id)
        log("\(a.name) \(why): waiting for its tabs to settle")
        var wait = RestoreWait(start: Date().timeIntervalSince1970)
        func look() {
            terminals.worker.run {
                if let b = a.scriptedBundleID { Automation.refresh(b) }
                let panes = self.permitted(a) ? a.restorablePanes() : nil
                DispatchQueue.main.async {
                    if wait.settled(panes, at: Date().timeIntervalSince1970, watching: ids) {
                        self.plan(a, panes)
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { look() }
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

    private func plan(_ a: TerminalAdapter, _ panes: [RestorePane]?) {
        // A session whose process vanished without SessionEnd joins the ledger now, not in 10 s.
        tracker?.reapNow()
        guard let panes else {
            log("\(a.name): could not list its tabs (not allowed, or older than 1.4); trying again at its next launch")
            underWay.remove(a.id)
            return
        }
        let now = Date().timeIntervalSince1970
        let launched = running(a)?.launchDate?.timeIntervalSince1970
        var ready: [RestoreEntry] = []
        var spent = Set<String>()
        for e in ledger.entries where e.adapter == a.id {
            let v = RestorePlan.verdict(e, panes: panes, now: now)
            log("\(e.sessionId.prefix(8)) \"\(e.title)\": \(v.why)")
            if v == .resume { ready.append(e) } else if RestorePlan.spent(e, v, launched: launched) { spent.insert(e.sessionId) }
        }
        if ledger.remove(where: { spent.contains($0.sessionId) }) { ledger.save() }
        guard !ready.isEmpty else { underWay.remove(a.id); return }
        if withoutAsking ?? Settings.restoreWithoutAsking { resume(a, ready); return }
        let n = ready.count
        let text = n == 1 ? "\(a.name) reopened a tab that was running Claude Code. Resume it?"
            : "\(a.name) reopened \(n) tabs that were running Claude Code. Resume them?"
        let items = ready.map { (title: $0.title, folder: ($0.folder as NSString).lastPathComponent) }
        if headless {
            log("would ask: \(text) " + items.map { "\"\($0.title)\" in \($0.folder)" }.joined(separator: ", ") + " (pass --yes to resume)")
            underWay.remove(a.id)
            return
        }
        promptFor = a.id
        prompt = RestorePrompt(message: text, items: items) { [weak self] resume, always in
            guard let self else { return }
            self.prompt = nil
            self.promptFor = nil
            if resume {
                if always { Settings.set(true, Settings.Key.restoreWithoutAsking) }
                self.resume(a, ready)
            } else {
                self.log("not now: dismissed \(ready.count)")
                self.forget(ready)
                self.underWay.remove(a.id)
            }
        }
        prompt?.show()
    }

    /// Types the resume command into each tab, checking it once more first: you may have used the
    /// tab while the question was up.
    private func resume(_ a: TerminalAdapter, _ ready: [RestoreEntry]) {
        let template = commandOverride ?? Settings.resumeCommand
        terminals.worker.run {
            let panes = a.restorablePanes() ?? []
            let now = Date().timeIntervalSince1970
            var lines: [String] = []
            for e in ready {
                let v = RestorePlan.verdict(e, panes: panes, now: now)
                guard v == .resume else { lines.append("\(e.sessionId.prefix(8)): not resumed, \(v.why)"); continue }
                let ok = a.type(RestorePlan.command(template, e), into: e.pane)
                lines.append("\(e.sessionId.prefix(8)): \(ok ? "resumed" : "typing failed") in pane \(e.pane.prefix(8))")
            }
            DispatchQueue.main.async {
                lines.forEach { self.log($0) }
                // Resumed or not, these had their chance.
                self.forget(ready)
                self.underWay.remove(a.id)
            }
        }
    }

    private func forget(_ entries: [RestoreEntry]) {
        let ids = Set(entries.map(\.sessionId))
        if ledger.remove(where: { ids.contains($0.sessionId) }) { ledger.save() }
    }

    private func log(_ msg: String) {
        AppLog.write("restore: " + msg)
        if echo { print("restore: " + msg) }
    }
}

// MARK: - The question

/// The one question a restore asks: a small floating panel that leaves the keyboard with the
/// terminal you just reopened, and never blocks anything while it waits.
final class RestorePrompt: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private var answer: ((_ resume: Bool, _ always: Bool) -> Void)?

    /// `items`: what Resume brings back, each session's title and folder name.
    init(message: String, items: [(title: String, folder: String)], answer: @escaping (_ resume: Bool, _ always: Bool) -> Void) {
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
        let host = NSHostingView(rootView: RestorePromptView(message: message, items: items) { [weak self] r, a in self?.finish(r, a) })
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
    }

    func show() {
        panel.center()
        panel.orderFrontRegardless()
    }

    /// Without an answer (the terminal quit meanwhile).
    func close() {
        answer = nil
        panel.close()
    }

    private func finish(_ resume: Bool, _ always: Bool) {
        let a = answer
        answer = nil
        panel.close()
        a?(resume, always)
    }

    /// The close button means Not Now.
    func windowWillClose(_ notification: Notification) {
        let a = answer
        answer = nil
        a?(false, false)
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
    }

    /// The ledger, and for each restoring terminal that runs: what a restore would do with each entry.
    static func status(_ args: [String]) -> Int32 {
        setUp(args)
        let now = Date().timeIntervalSince1970
        print("Restore: \(Settings.restore ? "on" : "off"), \(Settings.restoreWithoutAsking ? "resumes without asking" : "asks first"). Types: \(Settings.resumeCommand)")
        let ledger = RestoreLedger.load()
        print("\n\(Paths.restore.path): \(ledger.entries.count) session\(ledger.entries.count == 1 ? "" : "s")")
        for e in ledger.entries.sorted(by: { $0.endedTs > $1.endedTs }) {
            print("  \(e.sessionId.prefix(8))  \(e.reason.padding(toLength: 9, withPad: " ", startingAt: 0)) ended \(age(now - e.endedTs)) ago  \(e.adapter) pane \(e.pane.prefix(8))  \(e.folder)  \"\(e.title)\"")
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
            guard let app = Restorer.shared.running(a) else { print("  not running"); continue }
            Automation.refresh(b)
            guard Automation.cached(b) == .granted else { print("  not allowed to script it (Automation)"); continue }
            guard let panes = a.restorablePanes() else { print("  could not list its tabs (needs Ghostty 1.4 or later)"); continue }
            let since = app.launchDate.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? "?"
            print("  running since \(since), \(panes.count) terminal\(panes.count == 1 ? "" : "s")")
            for p in panes {
                print("    \(p.id.prefix(8))  \((p.atShell ? "shell" : "busy").padding(toLength: 6, withPad: " ", startingAt: 0)) \(p.foreground.padding(toLength: 10, withPad: " ", startingAt: 0)) \(p.cwd)")
            }
            for e in ledger.entries where e.adapter == a.id {
                print("  \(e.sessionId.prefix(8)) -> \(RestorePlan.verdict(e, panes: panes, now: now).why)")
            }
        }
        return 0
    }

    /// The app's restore, now, for each restoring terminal that runs. `--yes`: resume without
    /// asking (else report what it would ask). `--command TEMPLATE`: type this instead of Settings'.
    static func run(_ args: [String]) -> Int32 {
        setUp(args)
        let r = Restorer.shared
        r.headless = true
        r.echo = true
        r.withoutAsking = args.contains("--yes") ? true : nil
        r.commandOverride = option("--command", args)
        guard r.restoreNow() else { print("Nothing to restore (no remembered sessions for a running terminal, or Restore is off)."); return 0 }
        let deadline = Date().addingTimeInterval(45)
        while !r.isIdle, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        return r.isIdle ? 0 : 1
    }

    /// The tracker and restore without the UI (no Clawds, menu, recaps, sounds or notifications),
    /// for a restore round trip: it maps sessions to tabs, remembers the ones that end with their
    /// tab, and restores on relaunch. Prints mapping changes and restore steps.
    static func watch(_ args: [String]) -> Int32 {
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
