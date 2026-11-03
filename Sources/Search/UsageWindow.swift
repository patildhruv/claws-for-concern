import SwiftUI

/// The Usage window: every session's usage, opened from the crab menu (Usage…) and from Search's
/// toolbar. Same process as Search, so the figures are read once (`UsageModel`).
struct UsageWindow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var usage: UsageModel

    var body: some View {
        CrabThought(usage.loading && usage.updated == nil ? "Reading your sessions…" : "\(usage.bySession.count) sessions")
            .navigationTitle("Usage")
    }
}
