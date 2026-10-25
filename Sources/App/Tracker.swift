import AppKit

/// One Clawd on screen: a session that is waiting on you or finished while you were elsewhere.
struct Alert: Equatable {
    enum Kind: String { case blocked, failed, finished }
    let sessionId: String
    let kind: Kind
    let blockedKind: String?
    let ts: Double
    var title: String
    var folder: String
    var recap: String
    var recapPending: Bool
    var sprite: String
    var mapped: Bool
}

/// The brain. Reads the hook's session files, decides which sessions need a Clawd, learns which
/// terminal pane each session lives in, and clears a Clawd once you have looked at that pane.
final class Tracker {
    var onChange: (([Alert]) -> Void)?
    private(set) var alerts: [Alert] = []

    private struct Meta: Codable {
        var terminalId: String?
        /// statusTs of the last alert you saw or dismissed; a Clawd shows only for newer ones.
        var ackTs: Double = 0
        var promptSeen: Double = 0
        var startSeen: Double = 0
        var sprite: String?
    }
    private struct Saved: Codable {
        var meta: [String: Meta] = [:]
        var recaps: [String: Recap] = [:]
    }
    private struct Recap: Codable { let text: String; let ts: Double }

    private var states: [String: SessionState] = [:]
    private var saved = Saved()
    private var titleCache: [String: (size: UInt64, title: String?)] = [:]
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadPending = false
    private var timer: Timer?
    private var lastFallbackMap = Date.distantPast
    private var demo: [Alert] = []
    private var recapFailures: [String: Date] = [:]
    private var demoUntil = Date.distantPast
    private let terminals = Terminals.shared
    private let sprites = SpriteLibrary.shared

    init() {
        if let d = try? Data(contentsOf: Paths.appState), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            saved = s
        }
    }

    func start() {
        try? FileManager.default.createDirectory(at: Paths.sessions, withIntermediateDirectories: true)
        let fd = Darwin.open(Paths.sessions.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                                queue: .main)
            src.setEventHandler { [weak self] in self?.scheduleReload() }
            src.setCancelHandler { close(fd) }
            src.resume()
            watcher = src
        }
        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: Tracker.tickInterval, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.1
    }

    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.reloadPending = false
            self?.reload()
        }
    }

    // MARK: Reading the hook's files

    func reload() {
        var fresh: [String: SessionState] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            if let s = SessionState.load(f) { fresh[s.sessionId] = s }
        }
        states = fresh
        for sid in saved.meta.keys where fresh[sid] == nil { saved.meta[sid] = nil }

        let now = Date().timeIntervalSince1970
        var capture: [String] = []
        for (sid, s) in fresh {
            var m = saved.meta[sid] ?? Meta()
            // You just typed into this session, or just started it: the focused tab is its tab.
            if let p = s.promptTs, p > m.promptSeen {
                m.promptSeen = p
                capture.append(sid)
            }
            if s.status == .idle, s.statusTs > m.startSeen {
                m.startSeen = s.statusTs
                if now - s.statusTs < 10 { capture.append(sid) }
            }
            // A new alert while you are looking right at that tab never needs a Clawd.
            if alertKind(s) != nil, s.statusTs > m.ackTs, !alerts.contains(where: { $0.sessionId == sid && $0.ts == s.statusTs }),
               isWatching(sid, maxIdle: 30) {
                m.ackTs = s.statusTs
            }
            saved.meta[sid] = m
        }
        // Sessions at work keep their terminal polled, so the moment one stops we know if you were looking.
        terminals.busy = Set(fresh.values.filter { $0.status == .working || $0.status == .blocked }
            .map { terminals.adapter(for: $0).id })
        let learners = Set(capture.compactMap { fresh[$0] }.map { terminals.adapter(for: $0) }.filter(\.learnsPanes).map(\.id))
        if !learners.isEmpty {
            terminals.pollNow(learners) { [weak self] in
                guard let self else { return }
                for sid in capture { self.captureFocusedTab(for: sid, maxIdle: 20) }
                self.rebuild()
                self.save()
            }
        }
        rebuild()
        save()
    }

    private func alertKind(_ s: SessionState) -> Alert.Kind? {
        switch s.status {
        case .blocked:
            let on: Bool
            switch s.blockedKind {
            case "question": on = Settings.showQuestions
            case "permission": on = Settings.showPermissions
            case "plan": on = Settings.showPlans
            default: on = Settings.showInput
            }
            return on ? .blocked : nil
        case .failed: return Settings.showFailed ? .failed : nil
        case .finished:
            guard Settings.showFinished else { return nil }
            let h = Settings.expireHours
            if h > 0, Date().timeIntervalSince1970 - s.statusTs > Double(h) * 3600 { return nil }
            return .finished
        default: return nil
        }
    }

    // MARK: Building the list

    func rebuild() {
        var list: [Alert] = []
        var used = Set<String>()
        for (sid, s) in states {
            guard let kind = alertKind(s), s.statusTs > (saved.meta[sid]?.ackTs ?? 0) else { continue }
            var m = saved.meta[sid] ?? Meta()
            let sprite: String
            switch kind {
            case .blocked: sprite = Settings.blockedSprite
            case .failed: sprite = Settings.failedSprite
            case .finished:
                if let sp = m.sprite, sprites.sprites[sp] != nil, sp != SpriteLibrary.placeholder,
                   sprites.finishedPool.contains(sp) { sprite = sp } else {
                    sprite = sprites.finishedSprite(for: sid, avoiding: used)
                    // Never pin the stand-in: real art may arrive a few seconds later.
                    if sprite != SpriteLibrary.placeholder { m.sprite = sprite; saved.meta[sid] = m }
                }
            }
            used.insert(sprite)
            let (text, recap, pending) = recapFor(s, kind: kind)
            _ = text
            list.append(Alert(sessionId: sid, kind: kind, blockedKind: s.blockedKind, ts: s.statusTs,
                              title: title(for: s), folder: (s.rootCwd as NSString).lastPathComponent,
                              recap: recap, recapPending: pending, sprite: sprite, mapped: location(s).pane != nil))
        }
        let order: [Alert.Kind: Int] = [.blocked: 0, .failed: 1, .finished: 2]
        list.sort { (order[$0.kind]!, $0.ts) < (order[$1.kind]!, $1.ts) }
        if Date() < demoUntil { list = demo + list } else { demo = [] }
        let watched = Set(list.compactMap { states[$0.sessionId].map { terminals.adapter(for: $0).id } })
        terminals.watched = watched
        askPermissionInContext(watched)
        announce(list)
        flushNotifications(list)
        if list != alerts {
            alerts = list
            onChange?(alerts)
        }
    }

    /// (source text, text to show, still waiting for Haiku)
    private func recapFor(_ s: SessionState, kind: Alert.Kind) -> (String, String, Bool) {
        let detail = s.detail ?? ""
        let source: String
        let fallback: String
        switch kind {
        case .failed:
            return ("", "Stopped: " + (detail.isEmpty ? "API error" : detail), false)
        case .blocked:
            switch s.blockedKind {
            case "question":
                source = "Claude stopped mid-task to ask the user:\n\n\(detail)"
                fallback = "Asks: " + Summarizer.fallback(detail)
            case "plan":
                source = "Claude stopped to get its plan approved. The plan:\n\n\(detail)"
                fallback = "Has a plan ready for your approval"
            case "permission":
                source = "Claude stopped mid-task and needs the user's permission for:\n\n\(detail)"
                fallback = "Needs permission: " + Summarizer.fallback(detail)
            default:
                source = "Claude stopped mid-task waiting for user input:\n\n\(detail)"
                fallback = detail.isEmpty ? "Waiting for your input" : Summarizer.fallback(detail)
            }
        case .finished:
            let msg = (s.lastMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.isEmpty { return ("", "Finished its turn", false) }
            source = "Claude's final message for this turn:\n\n\(msg)"
            fallback = Summarizer.fallback(msg)
        }
        guard Settings.recaps else { return (source, fallback, false) }
        let key = Summarizer.key(source)
        if let r = saved.recaps[key] { return (source, r.text, false) }
        if let failed = recapFailures[key], Date().timeIntervalSince(failed) < 120 { return (source, fallback, false) }
        Summarizer.shared.summarize(source, key: key) { [weak self] line in
            guard let self else { return }
            if let line {
                self.saved.recaps[key] = Recap(text: line, ts: Date().timeIntervalSince1970)
                self.pruneRecaps()
                self.save()
            } else {
                // Show the fallback and retry in two minutes rather than in a loop.
                self.recapFailures[key] = Date()
            }
            self.rebuild()
        }
        return (source, fallback, true)
    }

    private func pruneRecaps() {
        guard saved.recaps.count > 400 else { return }
        let keep = saved.recaps.sorted { $0.value.ts > $1.value.ts }.prefix(300)
        saved.recaps = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    // MARK: Titles

    func title(for s: SessionState) -> String {
        if let t = s.title, !t.isEmpty { return t }
        if let t = transcriptTitle(s), !t.isEmpty { return t }
        return (s.rootCwd as NSString).lastPathComponent
    }

    /// The name /resume shows: agent-name, else custom-title, else ai-title (each last-wins).
    private func transcriptTitle(_ s: SessionState) -> String? {
        guard let path = s.transcriptPath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return nil }
        if let c = titleCache[s.sessionId], c.size == size { return c.title }
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let window: UInt64 = 2_000_000
        try? h.seek(toOffset: size > window ? size - window : 0)
        let data = h.readDataToEndOfFile()
        var agent: String?, custom: String?, ai: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.count < 4000, line.starts(with: Array("{\"type\":\"".utf8)) || line.firstRange(of: Array("-title\"".utf8)) != nil
                    || line.firstRange(of: Array("agent-name".utf8)) != nil else { continue }
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = o["type"] as? String else { continue }
            switch type {
            case "agent-name": agent = o["agentName"] as? String ?? agent
            case "custom-title": custom = o["customTitle"] as? String ?? custom
            case "ai-title": ai = o["aiTitle"] as? String ?? ai
            default: break
            }
        }
        let t = agent ?? custom ?? ai
        titleCache[s.sessionId] = (size, t)
        return t
    }

    // MARK: Which terminal, which pane

    /// The session's terminal adapter and its pane, if known: recorded outright by the hook (tmux,
    /// herdr, cmux, iTerm2, Terminal) or learned (Ghostty).
    func location(_ s: SessionState) -> (adapter: TerminalAdapter, pane: String?) {
        let a = terminals.adapter(for: s)
        if let p = a.paneID(for: s) { return (a, p) }
        return (a, a.learnsPanes ? saved.meta[s.sessionId]?.terminalId : nil)
    }

    /// The terminal a session runs in, for menus ("Open in tmux").
    func terminalName(_ sid: String) -> String? { states[sid].map { terminals.adapter(for: $0).name } }

    /// Does pane `t` host session `s`? `strong`: you were typing in `t` a moment ago.
    private func matches(_ t: PaneInfo, _ s: SessionState, strong: Bool = false) -> Bool {
        TabMatch.matches(t, rootCwd: s.rootCwd, cwd: s.cwd, title: s.title ?? transcriptTitle(s), strong: strong)
    }

    private func assign(_ terminalId: String, to sid: String) {
        for (other, var m) in saved.meta where other != sid && m.terminalId == terminalId {
            m.terminalId = nil
            saved.meta[other] = m
        }
        var m = saved.meta[sid] ?? Meta()
        m.terminalId = terminalId
        saved.meta[sid] = m
    }

    /// Learning adapters: you just typed into this session, so the focused pane is its pane.
    private func captureFocusedTab(for sid: String, maxIdle: Double) {
        guard let s = states[sid], Presence.idleSeconds < maxIdle else { return }
        let a = terminals.adapter(for: s)
        guard a.learnsPanes, let t = terminals.focusedPane(a.id), matches(t, s, strong: true) else { return }
        assign(t.id, to: sid)
    }

    /// Learning adapters, for sessions that alert before we ever saw you type into them (for example,
    /// already running when the app started): match panes by folder and title.
    private func fallbackMap(force: Bool = false, only: [SessionState]? = nil, then: (() -> Void)? = nil) {
        let unmapped = (only ?? alerts.filter { !$0.mapped }.compactMap { states[$0.sessionId] })
            .filter { terminals.adapter(for: $0).learnsPanes }
        guard !unmapped.isEmpty, force || Date().timeIntervalSince(lastFallbackMap) > 5 else { then?(); return }
        lastFallbackMap = Date()
        let group = DispatchGroup()
        var changed = false
        for (aid, sessions) in Dictionary(grouping: unmapped, by: { terminals.adapter(for: $0).id }) {
            guard let a = terminals.adapter(id: aid) else { continue }
            group.enter()
            terminals.panes(a) { [weak self] panes in
                defer { group.leave() }
                guard let self, !panes.isEmpty else { return }
                let taken = Set(self.saved.meta.values.compactMap(\.terminalId))
                for s in sessions where self.saved.meta[s.sessionId]?.terminalId == nil {
                    let free = panes.filter { !taken.contains($0.id) }
                    // Unique match wins: by title among Claude tabs anywhere, else the one Claude tab in
                    // the session's folder.
                    let fits = free.filter { self.matches($0, s) }
                    let inFolder = fits.filter { $0.cwd == s.rootCwd || $0.cwd == s.cwd }
                    if let pick = fits.count == 1 ? fits.first : (inFolder.count == 1 ? inFolder.first : nil) {
                        self.assign(pick.id, to: s.sessionId)
                        changed = true
                    }
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            if changed { self?.rebuild(); self?.save() }
            then?()
        }
    }

    /// Are you looking at this session right now?
    private func isWatching(_ sid: String, maxIdle: Double) -> Bool {
        guard let s = states[sid] else { return false }
        let (a, pane) = location(s)
        guard let pane, terminals.lookedAt(a.id).contains(pane) else { return false }
        return a.tracksSeenItself || Presence.idleSeconds < maxIdle
    }

    // MARK: The 1-second loop

    static let tickInterval = 0.5
    /// Seconds each alerting session's tab has been in front while you were active.
    private var dwell: [String: Double] = [:]
    private var lastReap = Date(), lastReload = Date(), lastExpiry = Date()

    private func tick() {
        let now = Date()
        if !demo.isEmpty, now >= demoUntil { rebuild() }
        if now.timeIntervalSince(lastReap) > 10 { lastReap = now; reapDeadSessions() }
        if !pendingNotify.isEmpty { flushNotifications(alerts) }
        if now.timeIntervalSince(lastReload) > 10 { lastReload = now; reload() }  // in case an fs event was missed
        let real = alerts.filter { states[$0.sessionId] != nil }
        guard !real.isEmpty else { dwell.removeAll(); return }
        if now.timeIntervalSince(lastExpiry) > 30 { lastExpiry = now; rebuild() }

        fallbackMap()
        // Learning adapters: learn the focused pane if exactly one alerting, unmapped session fits it.
        for a in terminals.adapters where a.learnsPanes {
            guard let t = terminals.focusedPane(a.id) else { continue }
            let fits = real.filter { !$0.mapped }.compactMap { states[$0.sessionId] }
                .filter { terminals.adapter(for: $0) === a && matches(t, $0) }
            if fits.count == 1, !saved.meta.values.contains(where: { $0.terminalId == t.id }) {
                assign(t.id, to: fits[0].sessionId)
            }
        }
        guard Settings.clearOnLook else { dwell.removeAll(); return }
        let active = Presence.idleSeconds < 3
        for alert in real {
            guard let s = states[alert.sessionId] else { continue }
            let (a, pane) = location(s)
            guard let pane, terminals.lookedAt(a.id).contains(pane) else { dwell[alert.sessionId] = 0; continue }
            // herdr decides "seen" itself: trust it at once.
            if a.tracksSeenItself { acknowledge(alert.sessionId); continue }
            guard active else { dwell[alert.sessionId] = 0; continue }
            dwell[alert.sessionId, default: 0] += Tracker.tickInterval
            // A short dwell, so flicking through tabs does not clear everything.
            if dwell[alert.sessionId]! >= Settings.lookSeconds { acknowledge(alert.sessionId) }
        }
    }

    /// The first time a Clawd appears for a session in iTerm2 or Terminal (Ghostty is asked at first
    /// launch), ask for the Automation permission that lets it find and switch that terminal's tabs.
    private var askedPermission = Set<String>()

    private func askPermissionInContext(_ adapterIDs: Set<String>) {
        for id in adapterIDs where !askedPermission.contains(id) {
            guard let a = terminals.adapter(id: id), let b = a.scriptedBundleID,
                  !NSRunningApplication.runningApplications(withBundleIdentifier: b).isEmpty else { continue }
            askedPermission.insert(id)
            terminals.requestPermission(a)
        }
    }

    // MARK: Sound and notifications for new Clawds

    private var announced = Set<String>()
    private var primed = false

    private func announce(_ list: [Alert]) {
        let keys = Set(list.filter { states[$0.sessionId] != nil }.map { "\($0.sessionId)@\($0.ts)" })
        defer { announced = keys; primed = true }
        // Nothing on launch for Clawds that were already there, nothing while paused.
        guard primed, Settings.pausedUntil == nil else { return }
        let fresh = list.filter { states[$0.sessionId] != nil && !announced.contains("\($0.sessionId)@\($0.ts)") }
        guard !fresh.isEmpty else { return }
        if Settings.sound { NSSound(named: NSSound.Name(Settings.soundName))?.play() }
        if Settings.notify {
            for a in fresh where a.kind != .finished || Settings.notifyFinished { pendingNotify[a.sessionId] = Date() }
        }
    }

    /// Notifications wait (up to 8 s) for the Haiku recap, and are dropped if you saw the session first.
    private var pendingNotify: [String: Date] = [:]

    private func flushNotifications(_ list: [Alert]) {
        for (sid, since) in pendingNotify {
            guard let a = list.first(where: { $0.sessionId == sid }) else { pendingNotify[sid] = nil; continue }
            if !a.recapPending || Date().timeIntervalSince(since) > 8 {
                Notifier.shared.post(a)
                pendingNotify[sid] = nil
            }
        }
    }

    /// Sessions whose Claude process is gone (tab closed, crash) never send SessionEnd.
    private func reapDeadSessions() {
        let now = Date().timeIntervalSince1970
        for (sid, s) in states {
            let dead: Bool
            if let pid = s.claudePid { dead = !ProcInfo.isAlive(pid: pid, start: s.claudeStart) } else { dead = now - s.updatedTs > 48 * 3600 }
            if dead { try? FileManager.default.removeItem(at: Paths.sessions.appendingPathComponent("\(sid).json")) }
        }
    }

    // MARK: Actions

    func acknowledge(_ sid: String) {
        guard let s = states[sid] else { demo.removeAll { $0.sessionId == sid }; rebuild(); return }
        var m = saved.meta[sid] ?? Meta()
        m.ackTs = max(m.ackTs, s.statusTs)
        Notifier.shared.clear(sid)
        saved.meta[sid] = m
        dwell[sid] = 0
        rebuild()
        save()
    }

    func acknowledgeAll() {
        for a in alerts { acknowledge(a.sessionId) }
        demo = []
        rebuild()
    }

    /// Jump to the session's pane through its terminal's adapter, or at least bring its app forward.
    func open(_ sid: String) {
        guard let s = states[sid] else { acknowledge(sid); return }  // demo Clawd
        acknowledge(sid)  // the Clawd goes at once; the jump follows
        let go = { [weak self] in
            guard let self else { return }
            let (a, pane) = self.location(s)
            self.terminals.open(s, adapter: a, paneID: pane) { paneOK in
                // A learned pane that no longer answers is forgotten (the tab was closed or reused).
                if a.learnsPanes, pane != nil, !paneOK { self.saved.meta[sid]?.terminalId = nil }
            }
        }
        let (a, pane) = location(s)
        if pane == nil, a.learnsPanes { fallbackMap(force: true, only: [s], then: go) } else { go() }
    }

    func state(_ sid: String) -> SessionState? { states[sid] }

    /// The leftmost Clawd: questions and permission requests first, then errors, then the
    /// oldest finished session.
    func openMostUrgent() {
        guard let a = alerts.first(where: { states[$0.sessionId] != nil }) ?? alerts.first else { return }
        open(a.sessionId)
    }

    func showDemo() {
        let now = Date().timeIntervalSince1970
        demo = [
            Alert(sessionId: "demo-1", kind: .blocked, blockedKind: "question", ts: now, title: "Fix flaky login test",
                  folder: "webapp", recap: "Fix verified with 20 green runs; asks whether the PR targets main or release-2.4",
                  recapPending: false, sprite: SpriteLibrary.blocked, mapped: true),
            Alert(sessionId: "demo-2", kind: .finished, blockedKind: nil, ts: now, title: "Budgets and alerts setup",
                  folder: "infra", recap: "Budgets set on all 3 accounts; alert emails go to finance@ from tomorrow",
                  recapPending: false, sprite: "JumpingHappy", mapped: true),
            Alert(sessionId: "demo-3", kind: .finished, blockedKind: nil, ts: now, title: "Office 365 license tiers",
                  folder: "Office", recap: "Comparison table done; recommends Business Premium for the 12 field staff",
                  recapPending: false, sprite: "Book", mapped: true),
            Alert(sessionId: "demo-4", kind: .failed, blockedKind: nil, ts: now, title: "Play Store dev console",
                  folder: "SchoolERP2.0", recap: "Stopped: API Error: Rate limit reached", recapPending: false,
                  sprite: SpriteLibrary.failed, mapped: false),
        ]
        demoUntil = Date().addingTimeInterval(30)
        rebuild()
    }

    /// Settings → Recaps → Clear Saved Recaps.
    func clearRecaps() {
        saved.recaps = [:]
        recapFailures = [:]
        save()
        rebuild()
    }

    /// Live sessions per terminal adapter, for Settings → Integrations.
    func sessionsByTerminal() -> [String: Int] {
        var out: [String: Int] = [:]
        for s in states.values { out[terminals.adapter(for: s).id, default: 0] += 1 }
        return out
    }

    var mappedCount: Int { alerts.filter { $0.mapped && states[$0.sessionId] != nil }.count }

    var unmappedCount: Int { alerts.filter { !$0.mapped && states[$0.sessionId] != nil }.count }
    var liveSessionCount: Int { states.count }

    private func save() {
        let enc = JSONEncoder()
        guard let data = try? enc.encode(saved) else { return }
        try? data.write(to: Paths.appState, options: .atomic)
    }
}

/// The rule for "this pane hosts that session" (learning adapters), kept pure for the self-test.
enum TabMatch {
    /// Claude Code titles its tab "<status glyph> <session title>"; a plain shell tab has no glyph.
    static func isClaudeTab(_ t: PaneInfo) -> Bool { t.name != t.title && !t.title.isEmpty }

    static func titleMatches(_ t: PaneInfo, _ title: String) -> Bool {
        t.title == title || (t.title.count > 3 && (title.hasPrefix(t.title) || t.title.hasPrefix(title)))
    }

    static func matches(_ t: PaneInfo, rootCwd: String, cwd: String, title: String?, strong: Bool) -> Bool {
        let folderOK = t.cwd == rootCwd || t.cwd == cwd
        if isClaudeTab(t) {
            // A Claude tab's title is the session's title, so it decides.
            if let title, !title.isEmpty { return titleMatches(t, title) }
            return folderOK
        }
        // A plain tab: only on strong evidence, or when Claude Code's tab titles are off.
        return folderOK && (strong || title == nil)
    }
}
