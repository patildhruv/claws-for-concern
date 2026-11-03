import AppKit
import Combine
import SwiftUI

/// The Usage window's state: the filters, the report they give, the table's order and selection, the
/// running sessions, and the row actions (open in Search, resume, copy ID, export CSV).
///
/// Rows are session IDs, as `UsageModel.bySession` has them: a session ID filed in two project folders
/// (a copied transcript) counts once, so the totals do not count its replies twice. Search lists both
/// copies; the window names and opens the copy whose project the figures came from.
///
/// The report is built in two steps (`UsageReport.prepare`, then `finish`): typing in Find only redoes
/// the second, 150 ms after the last key.
@MainActor
final class UsageWindowModel: ObservableObject {
    @Published var filter: UsageFilter {
        didSet {
            guard filter != oldValue else { return }
            if filter.range != oldValue.range { remember?.set(filter.range.rawValue, Self.rangeKey) }
            var a = filter, b = oldValue
            a.find = ""
            b.find = ""
            if a == b { findSoon() } else { rebuild() }
        }
    }
    /// Where the range you picked is kept: the helper's defaults, never under `--demo` or in a test.
    private let remember: SettingStore?
    @Published var sortOrder = [KeyPathComparator(\UsageRow.lastActiveKey, order: .reverse)] {
        didSet { rows = report.rows.sorted(using: sortOrder) }
    }
    /// The row you picked, in the table or near the limit. Cleared as soon as that row is no longer
    /// shown, so the actions (and the Session menu) never act on a row you cannot see.
    @Published var selection: String?
    @Published private(set) var report = UsageReport()
    @Published private(set) var rows: [UsageRow] = []
    @Published private(set) var flash: String?

    static let rangeKey = "usageRange"
    static let findDelay = 0.15

    private var usage: [String: SessionUsage] = [:]
    private var indexed: [String: [Session]] = [:]
    private var indexID: ObjectIdentifier?
    private(set) var sessions: [String: Session] = [:]
    private(set) var live: Set<String> = []
    private var prepared: UsageReport.Prepared?
    /// The day the report was built for: "Today" moves on at midnight.
    private var builtFor: String?
    private weak var app: AppModel?
    private var bag: Set<AnyCancellable> = []
    private var liveTimer: Timer?
    private var flashTask: Task<Void, Never>?
    private var findWork: DispatchWorkItem?
    private var rebuildQueued = false
    var now: () -> Date = Date.init
    /// How many times the report was prepared (the Find-independent step): the self-test counts them.
    private(set) var preparations = 0

    private var selectFirst: Bool

    init(filter: UsageFilter? = nil, selectFirst: Bool = false,
         remember: SettingStore? = Demo.active ? nil : UserDefaults.standard) {
        self.remember = remember
        let saved = (remember?.value(Self.rangeKey) as? String).flatMap(UsageRange.init(rawValue:))
        self.filter = filter ?? UsageFilter(range: saved ?? .month)
        self.selectFirst = selectFirst
        // Midnight: today is another day ("Today", "7 Days" and "30 Days" move on).
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.rebuild() } }
            .store(in: &bag)
    }

    // MARK: Inputs

    func attach(app: AppModel, usage model: UsageModel) {
        guard self.app == nil else { return }
        self.app = app
        // Both publishers fire before the value changes, so read them on the next turn.
        model.$bySession.sink { [weak self] all in
            self?.usage = all
            self?.rebuildSoon()
        }.store(in: &bag)
        app.$hits.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.noteIndex() } }
        }.store(in: &bag)
        noteIndex()
        refreshLive()
    }

    /// Search's index changed (a refresh found new or changed transcripts): new names and folders.
    private func noteIndex() {
        guard let index = app?.index else { return }
        let id = ObjectIdentifier(index)
        guard id != indexID else { return }
        indexID = id
        indexed = Dictionary(grouping: index.sessions, by: \.id)
        rebuildSoon()
    }

    /// While the window is open: Claws' session files, every 15 s (a directory of small files).
    func startLive() {
        refreshLive()
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLive() }
        }
    }

    func stopLive() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    func refreshLive() {
        Task.detached(priority: .utility) { [weak self] in
            let running = LiveSessions.running()
            await self?.setLive(running)
        }
    }

    private func setLive(_ running: Set<String>) {
        guard running != live else { return }
        live = running
        rebuild()
    }

    /// When the app comes forward: a new day since the report was built means a new report.
    func dayMayHaveChanged() {
        if builtFor != UsageDay.key(now(), .usage) { rebuild() }
    }

    /// For the self-test and the snapshot: figures, names and running sessions given directly.
    func load(usage: [String: SessionUsage], sessions: [Session], live: Set<String>) {
        self.usage = usage
        indexed = Dictionary(grouping: sessions, by: \.id)
        self.live = live
        rebuild()
    }

    private func rebuildSoon() {
        guard !rebuildQueued else { return }
        rebuildQueued = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.rebuildQueued = false
                self.rebuild()
            }
        }
    }

    /// Both steps: figures, names, running sessions, the day, range, project or model changed.
    func rebuild() {
        findWork?.cancel()
        findWork = nil
        // The copy whose project the figures came from, else the newest.
        sessions = indexed.compactMapValues { copies in
            copies.first { $0.projectDir == usage[$0.id]?.projectDir } ?? copies.max { $0.modified < $1.modified }
        }
        let info = sessions.mapValues { SessionInfo(title: $0.title, cwd: $0.cwd) }
        let at = now()
        builtFor = UsageDay.key(at, .usage)
        let p = UsageReport.prepare(usage: usage, info: info, live: live, filter: filter, now: at)
        prepared = p
        unfiltered = nil
        preparations += 1
        publish(finish(p))
    }

    /// The report with no Find, kept until the next full build: clearing Find is the costliest step
    /// (every session; 26 ms for all time on 542 real sessions), so it is done once.
    private var unfiltered: UsageReport?

    private func finish(_ p: UsageReport.Prepared) -> UsageReport {
        let blank = filter.find.trimmingCharacters(in: .whitespaces).isEmpty
        if blank, let unfiltered { return unfiltered }
        let r = UsageReport.finish(p, find: filter.find)
        if blank { unfiltered = r }
        return r
    }

    /// Find changed: only the second step, once typing pauses.
    private func findSoon() {
        findWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.applyFind() } }
        findWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.findDelay, execute: work)
    }

    /// Now, without waiting (the self-test; Return in the field).
    func applyFind() {
        findWork?.cancel()
        findWork = nil
        guard let prepared else { rebuild(); return }
        publish(finish(prepared))
    }

    private func publish(_ r: UsageReport) {
        report = r
        rows = r.rows.sorted(using: sortOrder)
        if selectFirst, !sessions.isEmpty, let first = rows.first {
            selectFirst = false
            selection = first.id
        }
        if let s = selection, !rows.contains(where: { $0.id == s }), !r.near.contains(where: { $0.id == s }) { selection = nil }
    }

    // MARK: The selection and its actions

    /// The selected row, only while it is shown.
    var selectedRow: UsageRow? {
        guard let selection else { return nil }
        return rows.first { $0.id == selection } ?? report.near.first { $0.id == selection }
    }

    func session(_ id: String?) -> Session? { id.flatMap { sessions[$0] } }

    /// The selected row's session, only while that row is shown.
    var selectedSession: Session? { selectedRow.flatMap { sessions[$0.id] } }

    /// Search's entry point: the copy filed under the figures' project folder. The self-test records it.
    lazy var showInSearch: (String, String?) -> Void = { [weak self] id, projectDir in
        self?.app?.show(sessionID: id, projectDir: projectDir)
    }

    /// Search's window with the session selected and in view; `open` brings the window up.
    func openInSearch(_ id: String, open: () -> Void) {
        guard sessions[id] != nil else { show("Search has not read this session yet."); return }
        open()
        showInSearch(id, usage[id]?.projectDir)
    }

    /// The 1.3 path: through Search's model, which asks Claws for Concern (its answer shows below).
    func resume(_ id: String) {
        guard let app, let s = sessions[id] else { return }
        guard s.canResume else { show(s.whyNotResumable ?? "This session cannot be resumed."); return }
        app.resume(s)
    }

    func copyID(_ id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
        show("Copied session ID")
    }

    /// What the filters show, as CSV, where you choose.
    func exportCSV(second: UsageModel.SecondCurrency?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = UsageCSV.fileName(filter.range, now: now())
        panel.canCreateDirectories = true
        let text = UsageCSV.make(rows, second: second)
        let count = rows.count
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                self?.show("Exported \(count) session\(count == 1 ? "" : "s") to \(url.lastPathComponent)")
            } catch {
                self?.show("Could not save: \(error.localizedDescription)")
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    func show(_ message: String) {
        flash = message
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }
}

/// The Usage window's selection, for the Session menu: while the Usage window is in front, Resume,
/// Copy Session ID and Show Transcript act on its row, not on Search's selection.
struct UsagePick {
    var session: Session?
}

struct UsagePickKey: FocusedValueKey { typealias Value = UsagePick }

extension FocusedValues {
    var usagePick: UsagePick? {
        get { self[UsagePickKey.self] }
        set { self[UsagePickKey.self] = newValue }
    }
}
