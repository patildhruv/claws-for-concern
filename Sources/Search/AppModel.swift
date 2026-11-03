import AppKit
import Combine
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            resumeFirstHit = false      // typing after Return changes your mind
            runSearch(after: 0.12)
        }
    }
    // Your choices are remembered, except in the demo, which always starts from the defaults, and in a
    // snapshot, which sets them from its flags.
    var remembers = !Demo.active
    @Published var scope: Scope {
        didSet {
            if remembers { UserDefaults.standard.set(Int(scope.rawValue), forKey: "scope") }
            if scope != oldValue { runSearch(after: 0) }
        }
    }
    @Published var sort: SortMode {
        didSet {
            if remembers { UserDefaults.standard.set(sort.rawValue, forKey: "sort") }
            if sort != oldValue { runSearch(after: 0) }
        }
    }
    /// The selected hit's `Hit.id`: its transcript (`Session.key`), not its session ID.
    @Published var selection: String? {
        didSet { if selection != oldValue { loadExcerpts() } }
    }
    /// The detail pane's Usage section open or folded away (remembered, except in the demo).
    @Published var usageShown: Bool {
        didSet { if remembers { UserDefaults.standard.set(usageShown, forKey: "usageShown") } }
    }
    @Published private(set) var hits: [Hit] = []
    @Published private(set) var snippets: [String: AttributedString] = [:]
    @Published private(set) var excerpts: [Excerpt] = []
    @Published private(set) var excerptTotal = 0
    /// The session (`Session.key`) the excerpts are for.
    @Published private(set) var excerptKey: String?
    @Published private(set) var indexing = false
    @Published private(set) var sessionCount = 0
    @Published private(set) var indexNote = ""
    @Published private(set) var flash: String?

    /// What Resume does with a session: ask Claws for Concern. The self-test records it instead.
    var resumer: (Session) -> Void = { ResumeClient.shared.resume($0) }

    private var index: SearchIndex?
    private var outcome: SearchOutcome?
    private let store: SessionStore
    private var searchTask: Task<Void, Never>?
    private var excerptTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var refreshQueued = false
    private var generation = 0
    /// The search the results on screen came from; Return waits until they match the field.
    private var shown: (generation: Int, query: String)?
    private var resumeFirstHit = false
    /// Each session's cost and context, for the Cost and Context sorts (`setUsage`).
    private var ranks: [String: UsageRank] = [:]
    private weak var usage: UsageModel?
    private var usageWatch: AnyCancellable?
    /// `show(sessionID:projectDir:)` waiting: for the index (`pendingShow`), or for results that hold
    /// the session (`pendingSelection`, a `Session.key`).
    private var pendingShow: (sessionID: String, projectDir: String?)?
    private var pendingSelection: String?

    init(store: SessionStore = SessionStore()) {
        self.store = store
        let saved = Demo.active ? nil : UserDefaults.standard.object(forKey: "scope") as? Int
        scope = saved.map { Scope(rawValue: UInt8(truncatingIfNeeded: $0)) } ?? .standard
        sort = Demo.active ? .relevance : SortMode(rawValue: UserDefaults.standard.string(forKey: "sort") ?? "") ?? .relevance
        usageShown = Demo.active ? true : UserDefaults.standard.object(forKey: "usageShown") as? Bool ?? true
        ResumeClient.shared.show = { [weak self] in self?.show(flash: $0) }
        // Made-up sessions: nothing to resume, and nothing is ever sent to Claws for Concern.
        if Demo.active { resumer = { [weak self] _ in self?.show(flash: "Demo sessions: there is nothing to resume.") } }
        refresh()
    }

    var selectedSession: Session? { session(selection) }

    /// The session among the results with this `Session.key`.
    func session(_ key: String?) -> Session? {
        guard let key else { return nil }
        return hits.first { $0.id == key }?.session
    }

    /// Selects one session and makes sure the list shows it: for the Usage window's "Open in Search".
    /// Of the transcripts with that ID, the one filed under `projectDir` (Claude Code's folder name,
    /// `Session.projectDir` and `SessionUsage.projectDir`), else the most recently active. If the
    /// results on screen leave it out, the query is cleared (an empty query lists every session). Called
    /// before the first read finishes, it waits for it. An ID Search does not know says so in the status line.
    func show(sessionID: String, projectDir: String?) {
        guard let index else { pendingShow = (sessionID, projectDir); return }
        let copies = index.sessions.filter { $0.id == sessionID }
        guard let pick = copies.first(where: { $0.projectDir == projectDir }) ?? copies.max(by: { $0.modified < $1.modified }) else {
            show(flash: "That session is not in Search any more.")
            return
        }
        resumeFirstHit = false
        if hits.contains(where: { $0.id == pick.key }) {
            pendingSelection = nil
            selection = pick.key
            return
        }
        pendingSelection = pick.key
        if query.trimmingCharacters(in: .whitespaces).isEmpty { runSearch(after: 0) } else { query = "" }
    }

    var statusLine: String {
        if sessionCount == 0 { return indexing ? "Reading your sessions…" : "No sessions in ~/.claude/projects yet" }
        let base = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? "\(sessionCount) sessions"
            : "\(hits.count) of \(sessionCount) sessions"
        return indexNote.isEmpty ? base : "\(base) · \(indexNote)"
    }

    // MARK: Indexing

    /// The usage figures this window shows: refreshed with the index, and the list re-sorted when they
    /// change while it is sorted by cost or context.
    func attach(_ usage: UsageModel) {
        guard self.usage !== usage else { return }
        self.usage = usage
        // `updated` is set once per read, after both maps; its publisher sends at once, then on each read
        // (as it is about to be stored, when bySession and byFile already hold the new figures).
        usageWatch = usage.$updated.sink { [weak self, weak usage] _ in
            guard let usage else { return }
            self?.setUsage(usage.bySession, byFile: usage.byFile)
        }
    }

    func setUsage(_ byID: [String: SessionUsage], byFile: [String: SessionUsage] = [:]) {
        let new = UsageRank.ranks(byID: byID, byFile: byFile)
        guard new != ranks else { return }
        ranks = new
        if sort.usesFigures { runSearch(after: 0) }
    }

    /// Re-reads changed transcripts and rebuilds the index if anything changed. Cheap when nothing did.
    /// The usage figures are read again too.
    func refresh() {
        usage?.refresh()
        if indexing { refreshQueued = true; return }
        indexing = true
        let store = store
        let first = index == nil
        Task.detached(priority: first ? .userInitiated : .utility) { [weak self] in
            let t0 = CFAbsoluteTimeGetCurrent()
            let (sessions, changed) = store.load()
            let parsed = CFAbsoluteTimeGetCurrent() - t0
            let built = (changed || first) ? SearchIndex(sessions: sessions) : nil
            await self?.finishRefresh(built, seconds: CFAbsoluteTimeGetCurrent() - t0, parseSeconds: parsed)
        }
    }

    private func finishRefresh(_ built: SearchIndex?, seconds: Double, parseSeconds: Double) {
        indexing = false
        if let built {
            index = built
            sessionCount = built.sessions.count
            indexNote = String(format: "indexed in %.1f s", seconds)
            runSearch(after: 0)
        }
        if let p = pendingShow, index != nil {
            pendingShow = nil
            show(sessionID: p.sessionID, projectDir: p.projectDir)
        }
        if refreshQueued {
            refreshQueued = false
            refresh()
        }
    }

    // MARK: Search

    private func runSearch(after delay: Double) {
        searchTask?.cancel()
        guard let index else { return }
        let raw = self.query
        let query = ParsedQuery(raw)
        let scope = scope
        let sort = sort
        let ranks = ranks
        generation += 1
        let gen = generation
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled,
                  let out = index.search(query, scope: scope, sort: sort, ranks: ranks, cancelled: { Task.isCancelled }),
                  !Task.isCancelled else { return }
            await self?.show(out, generation: gen, query: raw)

            // Previews for the rows people will actually look at.
            let map = Snippets.rows(Array(out.hits.prefix(150)), out)
            guard !Task.isCancelled else { return }
            await self?.showSnippets(map, generation: gen)
        }
    }

    private func show(_ out: SearchOutcome, generation gen: Int, query raw: String) {
        guard gen == generation else { return }
        outcome = out
        hits = out.hits
        shown = (gen, raw)
        if resumeFirstHit {
            resumeFirstHit = false
            if let first = hits.first { resume(first.session) }
        }
        if let want = pendingSelection, hits.contains(where: { $0.id == want }) {
            // A session asked for by `show(sessionID:projectDir:)`.
            pendingSelection = nil
            if selection == want { loadExcerpts() } else { selection = want }
        } else if let sel = selection, hits.contains(where: { $0.id == sel }) {
            // Every session, and not that one: it went in a refresh. Stop waiting for it.
            if pendingSelection != nil && raw.trimmingCharacters(in: .whitespaces).isEmpty { pendingSelection = nil }
            loadExcerpts()
        } else {
            if pendingSelection != nil && raw.trimmingCharacters(in: .whitespaces).isEmpty { pendingSelection = nil }
            // Next runloop turn, so the List has applied the new rows before selection moves.
            let first = hits.first?.id
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation, self.pendingSelection == nil else { return }
                self.selection = first
                if first == nil { self.excerpts = []; self.excerptTotal = 0 }
            }
        }
    }

    private func showSnippets(_ map: [String: AttributedString], generation gen: Int) {
        guard gen == generation else { return }
        snippets = map
    }

    private func loadExcerpts() {
        excerptTask?.cancel()
        guard let s = selectedSession else {
            excerpts = []; excerptTotal = 0; excerptKey = nil
            return
        }
        let out = outcome
        excerptTask = Task.detached(priority: .userInitiated) { [weak self] in
            let (items, total) = Snippets.list(s, out, limit: 300)
            guard !Task.isCancelled else { return }
            await self?.showExcerpts(items, total: total, for: s.key)
        }
    }

    private func showExcerpts(_ items: [Excerpt], total: Int, for key: String) {
        guard key == selection else { return }
        excerpts = items
        excerptTotal = total
        excerptKey = key
    }

    func moveSelection(_ delta: Int) {
        guard !hits.isEmpty else { return }
        let current = hits.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : hits.count)
        selection = hits[min(max(current + delta, 0), hits.count - 1)].id
    }

    func binding(_ part: Scope) -> Binding<Bool> {
        Binding(get: { self.scope.contains(part) },
                set: { on in if on { self.scope.insert(part) } else { self.scope.remove(part) } })
    }

    // MARK: Actions

    /// Through Claws for Concern (`ResumeClient`): its tab if it is still running, else a new one.
    func resume(_ s: Session) { resumer(s) }

    func copyCommand(_ s: Session) {
        guard let command = s.resumeCommand() else { return }
        copy(command, "Copied: \(command)")
    }
    func copyID(_ s: Session) { copy(s.id, "Copied session ID") }
    func reveal(_ s: Session) { NSWorkspace.shared.activateFileViewerSelecting([s.file]) }

    /// Return in the search field. Until the results for what is in the field are on screen, the
    /// selection belongs to the old ones: then Return resumes the first new hit when it arrives.
    func resumeSelected() {
        guard let shown, shown.generation == generation, shown.query == query else { resumeFirstHit = true; return }
        if let s = selectedSession { resume(s) }
    }

    private func copy(_ text: String, _ message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(flash: message)
    }

    private func show(flash message: String) {
        flash = message
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }
}
