import Combine
import Foundation

// What the Usage window needs from Search's model: every indexed session (the hits are only what the
// search field matches), and showing one session in Search's window.

extension AppModel {
    /// Every session Search has read, whatever the search field says.
    var indexedSessions: [Session] { index?.sessions ?? [] }

    /// Selects `id` in Search's list and scrolls to it. If the search field hides it, the field is
    /// cleared (every session shows); the selection waits until its row is in the list.
    func showInSearch(_ id: String) { SearchReveal.show(id, in: self) }
}

@MainActor
enum SearchReveal {
    private static var pending: AnyCancellable?

    static func show(_ id: String, in model: AppModel) {
        pending = nil
        if !model.query.isEmpty && !model.hits.contains(where: { $0.id == id }) { model.query = "" }
        // The list scrolls when the selection changes: make it change, even to the same session.
        if model.selection == id { model.selection = nil }
        pending = model.$hits
            .first { $0.contains { $0.id == id } }
            .sink { _ in
                // Once the list has the row, and a window that has just opened has its list.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    MainActor.assumeIsolated {
                        model.selection = id
                        pending = nil
                    }
                }
            }
    }
}
