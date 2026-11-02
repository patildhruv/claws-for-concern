import AppKit
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
    // Your choices are remembered, except in the demo, which always starts from the defaults.
    @Published var scope: Scope {
        didSet {
            if !Demo.active { UserDefaults.standard.set(Int(scope.rawValue), forKey: "scope") }
            if scope != oldValue { runSearch(after: 0) }
        }
    }
    @Published var sort: SortMode {
        didSet {
            if !Demo.active { UserDefaults.standard.set(sort.rawValue, forKey: "sort") }
            if sort != oldValue { runSearch(after: 0) }
        }
    }
    @Published var selection: String? {
        didSet { if selection != oldValue { loadExcerpts() } }
    }
    @Published private(set) var hits: [Hit] = []
    @Published private(set) var snippets: [String: AttributedString] = [:]
    @Published private(set) var excerpts: [Excerpt] = []
    @Published private(set) var excerptTotal = 0
    @Published private(set) var excerptSessionID: String?
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

    init(store: SessionStore = SessionStore()) {
        self.store = store
        let saved = Demo.active ? nil : UserDefaults.standard.object(forKey: "scope") as? Int
        scope = saved.map { Scope(rawValue: UInt8(truncatingIfNeeded: $0)) } ?? .standard
        sort = Demo.active ? .relevance : SortMode(rawValue: UserDefaults.standard.string(forKey: "sort") ?? "") ?? .relevance
        ResumeClient.shared.show = { [weak self] in self?.show(flash: $0) }
        // Made-up sessions: nothing to resume, and nothing is ever sent to Claws for Concern.
        if Demo.active { resumer = { [weak self] _ in self?.show(flash: "Demo sessions: there is nothing to resume.") } }
        refresh()
    }

    var selectedSession: Session? { session(selection) }

    func session(_ id: String?) -> Session? {
        guard let id else { return nil }
        return hits.first { $0.id == id }?.session
    }

    var statusLine: String {
        if sessionCount == 0 { return indexing ? "Reading your sessions…" : "No sessions in ~/.claude/projects yet" }
        let base = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? "\(sessionCount) sessions"
            : "\(hits.count) of \(sessionCount) sessions"
        return indexNote.isEmpty ? base : "\(base) · \(indexNote)"
    }

    // MARK: Indexing

    /// Re-reads changed transcripts and rebuilds the index if anything changed. Cheap when nothing did.
    func refresh() {
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
        generation += 1
        let gen = generation
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled,
                  let out = index.search(query, scope: scope, sort: sort, cancelled: { Task.isCancelled }),
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
        if let sel = selection, hits.contains(where: { $0.id == sel }) {
            loadExcerpts()
        } else {
            // Next runloop turn, so the List has applied the new rows before selection moves.
            let first = hits.first?.id
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
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
            excerpts = []; excerptTotal = 0; excerptSessionID = nil
            return
        }
        let out = outcome
        excerptTask = Task.detached(priority: .userInitiated) { [weak self] in
            let (items, total) = Snippets.list(s, out, limit: 300)
            guard !Task.isCancelled else { return }
            await self?.showExcerpts(items, total: total, for: s.id)
        }
    }

    private func showExcerpts(_ items: [Excerpt], total: Int, for id: String) {
        guard id == selection else { return }
        excerpts = items
        excerptTotal = total
        excerptSessionID = id
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
