import Foundation
import SwiftUI

/// Every session's usage for the screens: Search's panel and list, and the Usage window. One per app,
/// shared by both windows, so the transcripts are read once per refresh. Reads off the main thread;
/// cheap once `UsageCache` has the figures (it reads only what changed).
@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var bySession: [String: SessionUsage] = [:]
    /// By transcript path: 8 session IDs here are filed in two project folders, and Search lists both.
    private(set) var byFile: [String: SessionUsage] = [:]
    @Published private(set) var loading = false
    /// When the figures were last read; nil until the first read finishes.
    @Published private(set) var updated: Date?

    /// The currency shown next to dollars, when turned on and its rate is known. Set by the currency
    /// setting (opt-in, a rate fetched at most once a day); nil shows dollars only.
    @Published var second: SecondCurrency?

    struct SecondCurrency: Equatable {
        /// ISO code, "INR".
        var code: String
        var perUSD: Double
        /// The day the rate is for, as the service states it.
        var date: Date
    }

    private let store: UsageStore
    private var queued = false

    init(store: UsageStore = UsageStore()) {
        self.store = store
        refresh()
    }

    subscript(id: String) -> SessionUsage? { bySession[id] }

    /// The figures for one of Search's sessions: its own transcript's, so a session ID filed in two project
    /// folders shows each copy's own; else by ID (the demo). Prefer this wherever a `Session` is at hand.
    func usage(for session: Session) -> SessionUsage? { byFile[session.file.path] ?? bySession[session.id] }

    func refresh() {
        if loading { queued = true; return }
        loading = true
        let store = store
        Task.detached(priority: .utility) { [weak self] in
            let all = store.load()
            let files = store.byTranscript
            await self?.finish(all, files)
        }
    }

    private func finish(_ all: [String: SessionUsage], _ files: [String: SessionUsage]) {
        loading = false
        byFile = files
        if all != bySession { bySession = all }
        updated = Date()
        if queued { queued = false; refresh() }
    }

    /// A cost as the screens write it: "$12.40", plus the second currency when it is on. The caller adds
    /// "est." for an estimate (`SessionUsage.Cost.source`) and says "at API prices" where it fits.
    func money(_ usd: Double) -> String {
        UsageFormat.usd(usd)
    }
}

/// How the screens write usage figures, so Search and the Usage window say them the same way.
enum UsageFormat {
    /// "$0.42", "$12.40", "$1,284".
    static func usd(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = abs(v) >= 1000 ? 0 : 2
        f.minimumFractionDigits = abs(v) >= 1000 ? 0 : 2
        return f.string(from: NSNumber(value: v)) ?? String(format: "$%.2f", v)
    }

    /// "845", "12.3K", "1.24M", "3.1B".
    static func tokens(_ n: Int) -> String {
        let v = Double(n), a = abs(v)
        func trim(_ x: Double, _ digits: Int) -> String {
            var s = String(format: "%.\(digits)f", x)
            if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
            return s
        }
        if a < 1_000 { return "\(n)" }
        if a < 1_000_000 { return trim(v / 1_000, a < 10_000 ? 2 : 1) + "K" }
        if a < 1_000_000_000 { return trim(v / 1_000_000, a < 10_000_000 ? 2 : 1) + "M" }
        return trim(v / 1_000_000_000, 2) + "B"
    }

    /// "42s", "12m", "3h 05m".
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }

    /// "84%".
    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    /// "Opus 5.5", "Sonnet 4.5", "Sonnet 3.7", "Haiku 4.5 (1M)"; the ID itself for anything else.
    static func model(_ id: String) -> String {
        guard let key = Pricing.key(for: id) else { return id }
        let parts = key.dropFirst("claude-".count).split(separator: "-").map(String.init)
        let families = ["opus", "sonnet", "haiku", "fable", "mythos"]
        guard let family = parts.first(where: families.contains),
              case let numbers = parts.filter({ Int($0) != nil }), !numbers.isEmpty,
              parts.allSatisfy({ $0 == family || Int($0) != nil }) else { return id }
        let long = id.lowercased().contains("[1m]") ? " (1M)" : ""
        return family.prefix(1).uppercased() + family.dropFirst() + " " + numbers.joined(separator: ".") + long
    }
}
