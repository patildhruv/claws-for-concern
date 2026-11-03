import Foundation

// What the Usage window needs from Search's model: every indexed session (the hits are only what the
// search field matches). Open in Search goes through Search's own `show(sessionID:projectDir:)`.

extension AppModel {
    /// Every session Search has read, whatever the search field says.
    var indexedSessions: [Session] { index?.sessions ?? [] }
}
