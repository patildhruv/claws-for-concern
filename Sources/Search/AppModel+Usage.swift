import Combine
import Foundation

// What the Usage window needs from Search's model: every indexed session (the hits are only what the
// search field matches). Open in Search goes through Search's own `show(sessionID:projectDir:)`.

extension AppModel {
    /// Every session Search has read, whatever the search field says.
    var indexedSessions: [Session] { index?.sessions ?? [] }
}

// PM: remove at merge. A stand-in for Developer B's `AppModel.show(sessionID:projectDir:)` (branch
// usage-panel, 03419d7), so this branch compiles: it selects by session ID, as Search did before B keyed
// rows on the transcript path, and ignores `projectDir`. B's version picks the copy filed under
// `projectDir`, clears the field if needed and waits for the first read.
extension AppModel {
    func show(sessionID id: String, projectDir: String?) { SearchRevealStub.show(id, in: self) }
}

// PM: remove at merge (with the stand-in above).
@MainActor
enum SearchRevealStub {
    private static var pending: AnyCancellable?

    static func show(_ id: String, in model: AppModel) {
        pending = nil
        if !model.query.isEmpty && !model.hits.contains(where: { $0.id == id }) { model.query = "" }
        if model.selection == id { model.selection = nil }
        pending = model.$hits
            .first { $0.contains { $0.id == id } }
            .sink { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    MainActor.assumeIsolated {
                        model.selection = id
                        pending = nil
                    }
                }
            }
    }
}
