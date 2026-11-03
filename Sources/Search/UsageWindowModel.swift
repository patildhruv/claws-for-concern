import AppKit
import Combine
import SwiftUI

/// The Usage window's state: the filters, the report they give, the table's order and selection, the
/// running sessions, and the row actions (open in Search, resume, copy ID, export CSV).
///
/// Rows are session IDs, as `UsageModel.bySession` has them: a session ID filed in two project folders
/// (a copied transcript) counts once, so the totals do not count its replies twice. Search lists both
/// copies; the window names and opens the copy whose project the figures came from.
@MainActor
final class UsageWindowModel: ObservableObject {
    @Published var filter: UsageFilter {
        didSet {
            guard filter != oldValue else { return }
            if filter.range != oldValue.range { remember?.set(filter.range.rawValue, Self.rangeKey) }
            rebuild()
        }
    }
    /// Where the range you picked is kept: the helper's defaults, never under `--demo` or in a test.
    private let remember: SettingStore?
    @Published var sortOrder = [KeyPathComparator(\UsageRow.lastActiveKey, order: .reverse)] {
        didSet { rows = report.rows.sorted(using: sortOrder) }
    }
    @Published var selection: String?
    @Published private(set) var report = UsageReport()
    @Published private(set) var rows: [UsageRow] = []
    @Published private(set) var flash: String?

    static let rangeKey = "usageRange"

    private var usage: [String: SessionUsage] = [:]
    private var indexed: [String: [Session]] = [:]
    private var indexID: ObjectIdentifier?
    private(set) var sessions: [String: Session] = [:]
    private(set) var live: Set<String> = []
    private weak var app: AppModel?
    private var bag: Set<AnyCancellable> = []
    private var liveTimer: Timer?
    private var flashTask: Task<Void, Never>?
    private var rebuildQueued = false
    var now: () -> Date = Date.init

    private var selectFirst: Bool

    init(filter: UsageFilter? = nil, selectFirst: Bool = false,
         remember: SettingStore? = Demo.active ? nil : UserDefaults.standard) {
        self.remember = remember
        let saved = (remember?.value(Self.rangeKey) as? String).flatMap(UsageRange.init(rawValue:))
        self.filter = filter ?? UsageFilter(range: saved ?? .month)
        self.selectFirst = selectFirst
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

    func rebuild() {
        // The copy whose project the figures came from, else the newest.
        sessions = indexed.compactMapValues { copies in
            copies.first { $0.projectDir == usage[$0.id]?.projectDir } ?? copies.max { $0.modified < $1.modified }
        }
        let info = sessions.mapValues { SessionInfo(title: $0.title, cwd: $0.cwd) }
        report = UsageReport.build(usage: usage, info: info, live: live, filter: filter, now: now())
        rows = report.rows.sorted(using: sortOrder)
        if selectFirst, !sessions.isEmpty, let first = rows.first {
            selectFirst = false
            selection = first.id
        }
    }

    // MARK: The selection and its actions

    var selectedRow: UsageRow? {
        guard let selection else { return nil }
        return rows.first { $0.id == selection } ?? report.near.first { $0.id == selection }
    }

    func session(_ id: String?) -> Session? { id.flatMap { sessions[$0] } }

    var selectedSession: Session? { session(selection) }

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
