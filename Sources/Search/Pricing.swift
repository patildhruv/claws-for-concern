import Foundation

/// Anthropic's API prices per model, for estimating what a session cost when Claude Code's own figure
/// does not cover it. Data in code, so a release carries the prices it was checked against.
///
/// Checked 2026-11-03 against platform.claude.com/docs/en/about-claude/pricing (read in a browser) and
/// the claude-api skill bundled with Claude Code 2.1.316 (its table cached 2026-10-06). They agree on
/// every rate but one: Claude Sonnet 5.5's cache read is $0.10 on the page (0.05x, as for Opus 5.5) and
/// $0.20 in the skill; the page is the newer source. Claude Code's own `costUSD` matched these rates in
/// the cross-check (docs/usage.md).
enum Pricing {
    static let checked = "2026-11-03"

    /// US dollars per million tokens.
    struct Rates: Equatable {
        var input: Double
        var output: Double
        var cacheWrite5m: Double
        var cacheWrite1h: Double
        var cacheRead: Double

        /// Base input × the cache multipliers Anthropic applies to every model (1.25x, 2x) and this
        /// model's own read multiplier.
        init(input: Double, output: Double, cacheRead: Double) {
            self.input = input; self.output = output
            cacheWrite5m = input * 1.25; cacheWrite1h = input * 2; self.cacheRead = cacheRead
        }
    }

    struct Price {
        var rates: Rates
        /// A prompt (input + cache read + cache write) over `limit` tokens is billed at `rates`, or
        /// cannot be priced here when they are nil (a long-context premium the page does not state).
        var above: (limit: Int, rates: Rates?)?
        /// Fast mode's input and output price (`usage.speed == "fast"`); the cache multipliers apply on top.
        var fast: (input: Double, output: Double)?
        /// `inference_geo: "us"` costs 1.1x on every token kind, for Claude 4.6 and later.
        var residency = false
    }

    static let webSearch = 0.01     // $10 per 1,000 searches

    private static func p(_ input: Double, _ output: Double, read: Double, fast: (Double, Double)? = nil,
                          residency: Bool = true) -> Price {
        Price(rates: Rates(input: input, output: output, cacheRead: read), fast: fast.map { (input: $0.0, output: $0.1) },
              residency: residency)
    }

    /// Keyed by model ID without date, platform prefix or Claude Code's "[1m]" (`key(for:)`).
    static let table: [String: Price] = [
        "claude-fable-5-1": p(10, 50, read: 0.25),
        "claude-mythos-5-1": p(10, 50, read: 0.25),
        "claude-fable-5": p(10, 50, read: 1),
        "claude-mythos-5": p(10, 50, read: 1),
        "claude-opus-5-5": p(4, 20, read: 0.20, fast: (8, 40)),
        "claude-opus-5": p(5, 25, read: 0.50, fast: (10, 50)),
        "claude-opus-4-8": p(5, 25, read: 0.50, fast: (10, 50)),
        "claude-opus-4-7": p(5, 25, read: 0.50),
        "claude-opus-4-6": p(5, 25, read: 0.50),
        "claude-opus-4-5": p(5, 25, read: 0.50, residency: false),
        "claude-opus-4-1": p(15, 75, read: 1.50, residency: false),
        "claude-opus-4": p(15, 75, read: 1.50, residency: false),
        "claude-sonnet-5-5": p(2, 10, read: 0.10),
        "claude-sonnet-5": p(2, 10, read: 0.20),
        "claude-sonnet-4-6": p(3, 15, read: 0.30),
        // The page gives 4.6 and later the whole 1M window at these rates; it says nothing for these two.
        "claude-sonnet-4-5": Price(rates: Rates(input: 3, output: 15, cacheRead: 0.30), above: (200_000, nil)),
        "claude-sonnet-4": Price(rates: Rates(input: 3, output: 15, cacheRead: 0.30), above: (200_000, nil)),
        "claude-haiku-5-5": Price(rates: Rates(input: 0.10, output: 0.50, cacheRead: 0.01),
                                  above: (100_000, Rates(input: 0.50, output: 2.50, cacheRead: 0.05)), residency: true),
        "claude-haiku-4-5": p(1, 5, read: 0.10, residency: false),
        "claude-3-5-haiku": p(0.80, 4, read: 0.08, residency: false),
    ]

    /// The table's key for a model ID: Bedrock's `us.anthropic.` and `-v1:0`, Vertex's `@date`, Claude
    /// Code's `[1m]` and a trailing `-YYYYMMDD` come off. nil for an ID that is not a Claude model.
    static func key(for model: String) -> String? {
        var m = model.lowercased()
        if let r = m.range(of: "[") { m = String(m[..<r.lowerBound]) }
        if let r = m.range(of: "@") { m = String(m[..<r.lowerBound]) }
        if let r = m.range(of: "anthropic.") { m = String(m[r.upperBound...]) }
        if let r = m.range(of: #"-v\d+(:\d+)?$"#, options: .regularExpression) { m.removeSubrange(r) }
        if let r = m.range(of: #"-\d{8}$"#, options: .regularExpression) { m.removeSubrange(r) }
        return m.hasPrefix("claude-") ? m : nil
    }

    static func price(for model: String) -> Price? { key(for: model).flatMap { table[$0] } }

    /// One API call at API prices, or nil when it cannot be priced.
    static func cost(model: String, _ t: SessionUsage.Tokens, speed: String? = nil, geo: String? = nil,
                     webSearches: Int = 0) -> Double? {
        guard let price = price(for: model) else { return nil }
        var r = price.rates
        if let above = price.above, t.prompt > above.limit {
            guard let higher = above.rates else { return nil }
            r = higher
        }
        if speed == "fast", let fast = price.fast {
            let readShare = r.cacheRead / r.input
            r = Rates(input: fast.input, output: fast.output, cacheRead: fast.input * readShare)
        }
        var usd = (Double(t.input) * r.input + Double(t.output) * r.output + Double(t.cacheWrite5m) * r.cacheWrite5m
                   + Double(t.cacheWrite1h) * r.cacheWrite1h + Double(t.cacheRead) * r.cacheRead) / 1_000_000
        if geo == "us" && price.residency { usd *= 1.1 }
        return usd + Double(webSearches) * webSearch
    }
}

/// Context window per model, for "context now" as a share. Transcripts never state it, and Claude
/// Code's status line under-reports on some providers. Checked 2026-11-03: current models against the
/// claude-api skill bundled with Claude Code 2.1.316 (models.md) and platform.claude.com's models
/// overview; Opus 4.5, Sonnet 4.5 and Haiku 4.5 against their own pages there
/// (docs/en/models/<model>/overview: "Context window: 200K tokens"). Retired models have no page any
/// more (Opus 4.1 and 4, Sonnet 4, the 3.x line), so they are unknown here: nil.
enum ContextWindows {
    static let checked = "2026-11-03"
    /// Where "near the limit" starts for a model with no known window (the client's choice, plan-1.4).
    static let nearLimitWithoutWindow = 800_000

    static let table: [String: Int] = [
        "claude-fable-5-1": 1_000_000, "claude-mythos-5-1": 1_000_000,
        "claude-fable-5": 1_000_000, "claude-mythos-5": 1_000_000,
        "claude-opus-5-5": 1_000_000, "claude-opus-5": 1_000_000,
        "claude-opus-4-8": 1_000_000, "claude-opus-4-7": 1_000_000, "claude-opus-4-6": 1_000_000,
        "claude-sonnet-5-5": 1_000_000, "claude-sonnet-5": 1_000_000, "claude-sonnet-4-6": 1_000_000,
        "claude-haiku-5-5": 1_000_000,
        "claude-opus-4-5": 200_000, "claude-sonnet-4-5": 200_000, "claude-haiku-4-5": 200_000,
    ]

    static func size(for model: String) -> Int? { Pricing.key(for: model).flatMap { table[$0] } }
}
