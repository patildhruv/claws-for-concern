import Accessibility
import AppKit
import Charts
import SwiftUI

/// Colours for the usage graphics. Text uses `Brand.quietText` (AA on Search's backgrounds); bar fills
/// meet 3:1 on them and on the selected row (docs/search.md "Usage" has the ratios).
enum UsageStyle {
    /// A context bar's fill below the limit: 3.95:1 on white, 3.35:1 on the selected row (light);
    /// 5.92:1 and 3.97:1 (dark).
    static let fill = adaptive(light: 0x808080, dark: 0x9A9A9A, lightHigh: 0x5E5E5E, darkHigh: 0xBDBDBD)

    static func adaptive(light: Int, dark: Int, lightHigh: Int, darkHigh: Int) -> NSColor {
        func rgb(_ v: Int) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        }
        return NSColor(name: nil) { a in
            switch a.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua?: return rgb(dark)
            case .accessibilityHighContrastAqua?: return rgb(lightHigh)
            case .accessibilityHighContrastDarkAqua?: return rgb(darkHigh)
            default: return rgb(light)
            }
        }
    }
}

extension Color {
    /// Secondary text that meets AA (`Brand.quietText`).
    static let quiet = Color(nsColor: Brand.quietText)
}

/// How full the context is: grey, or clay once it is near the limit. The figure next to it says the
/// same in words, so the colour is never the only sign.
struct ContextBar: View {
    let fraction: Double
    let near: Bool

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(near ? Color.clayText : Color(nsColor: UsageStyle.fill))
                    .frame(width: max(g.size.height, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// One line under a list row's folder: the context bar and the cost. Empty, at the same height, for
/// a session with no figures yet, so rows keep one height.
struct RowUsage: View {
    @EnvironmentObject var usage: UsageModel
    let figures: SessionUsage?
    let selected: Bool

    var body: some View {
        // On the clay selection all text is primary, as in the rest of the row.
        let quiet: Color = selected ? .primary : .quiet
        HStack(spacing: 6) {
            if let u = figures, u.replies > 0 {
                if let f = u.contextFraction {
                    ContextBar(fraction: f, near: u.isNearContextLimit)
                        .frame(width: 56, height: 4)
                }
                if let c = UsageText.rowContext(u) {
                    Text(c)
                        .foregroundStyle(u.isNearContextLimit && !selected ? Color.clayText : quiet)
                        .help(UsageText.context(u).map { "Context: " + $0 } ?? "")
                }
                Spacer(minLength: 6)
                Text(UsageText.rowCost(u, money: usage.money))
                    .monospacedDigit()
                    .foregroundStyle(quiet)
                    .help(UsageText.rowCostHelp(u))
            } else {
                Text(" ")
            }
        }
        .font(.caption)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// The selected session's Usage section in the detail pane: what the conversation used and cost.
/// Folds away to one line (remembered), as the matching messages come after it.
struct UsageSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var usage: UsageModel
    let session: Session

    var body: some View {
        let u = usage.usage(for: session).flatMap { $0.replies > 0 ? $0 : nil }
        VStack(alignment: .leading, spacing: 12) {
            Button { model.usageShown.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.quiet)
                        .rotationEffect(.degrees(model.usageShown ? 90 : 0))
                    Text("Usage").font(.headline)
                    if !model.usageShown, let u {
                        Text(UsageText.summary(u, money: usage.money))
                            .foregroundStyle(Color.quiet)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Usage")
            .accessibilityValue(model.usageShown ? "shown" : "hidden")
            .help(model.usageShown ? "Hide this session's usage" : "Show this session's usage")

            if model.usageShown {
                if let u {
                    UsageDetails(u: u)
                } else {
                    Text(placeholder)
                        .foregroundStyle(Color.quiet)
                }
            }
        }
    }

    /// Never zeros: no figures yet is said in words.
    private var placeholder: String {
        if usage.updated == nil { return "Reading usage…" }
        if usage.usage(for: session) != nil { return "Claude has not replied in this session yet." }
        return "No usage figures for this session yet."
    }
}

/// Every field the client kept, in the wireframe's groups.
struct UsageDetails: View {
    @EnvironmentObject var usage: UsageModel
    let u: SessionUsage

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
            heading("Context")
            GridRow {
                DetailLabel("Context now")
                contextNow
            }
            GridRow(alignment: .top) {
                DetailLabel("Over time")
                ContextChart(u: u)
                    .frame(maxWidth: 520)
            }
            GridRow {
                DetailLabel("Compactions")
                compactions
            }

            heading("Cost at API prices", help: UsageText.pricesHelp)
            GridRow {
                DetailLabel("Cost")
                let c = UsageText.cost(u, money: usage.money)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.value).font(.body.weight(.semibold)).monospacedDigit()
                    Text(c.note).font(.caption).foregroundStyle(Color.quiet)
                }
                .help(UsageText.pricesHelp)
            }
            GridRow {
                DetailLabel("Tokens")
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 2) {
                    tokenRow("Written by Claude", u.tokens.output)
                    tokenRow("Read from cache", u.tokens.cacheRead)
                    tokenRow("Written to cache", u.tokens.cacheWrite)
                    tokenRow("Fresh input", u.tokens.input)
                }
            }
            GridRow {
                DetailLabel("By model")
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 2) {
                    ForEach(UsageText.byModel(u, money: usage.money), id: \.id) { m in
                        GridRow {
                            Text(m.name)
                            Text(m.cost).monospacedDigit().gridColumnAlignment(.trailing)
                            Text(m.replies).foregroundStyle(Color.quiet).monospacedDigit().gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
            if u.cost.usd != nil {      // with the cost unknown, so is this: the Cost row says why
                GridRow {
                    DetailLabel("Per hour")
                    Text(UsageText.perHour(u, money: usage.money)).monospacedDigit()
                }
            }

            heading("Time")
            GridRow {
                DetailLabel("Claude worked")
                Text(UsageText.worked(u)).monospacedDigit()
            }
            GridRow {
                DetailLabel("Turns")
                Text(UsageText.turns(u)).monospacedDigit()
            }

            heading("Work")
            GridRow {
                DetailLabel("Tools used")
                let t = UsageText.tools(u)
                Text(t.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(t.all)
            }
            GridRow {
                DetailLabel("Subagents")
                Text(UsageText.subagents(u, money: usage.money)).monospacedDigit()
                    .help(u.subagents.count > 0 ? "Already counted in the cost and tokens above" : "")
            }

            heading("Problems")
            GridRow {
                DetailLabel("API errors")
                errors
            }
        }
        .textSelection(.enabled)
    }

    /// A group's name across both columns.
    @ViewBuilder
    private func heading(_ name: String, help: String = "") -> some View {
        GridRow {
            Text(name.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(Color.quiet)
                .padding(.top, 8)
                .gridCellColumns(2)
                .help(help)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func tokenRow(_ kind: String, _ n: Int) -> some View {
        GridRow {
            Text(kind).foregroundStyle(Color.quiet)
            Text(UsageFormat.tokens(n)).monospacedDigit().gridColumnAlignment(.trailing)
                .help(n.formatted(.number) + " tokens")
        }
    }

    @ViewBuilder
    private var contextNow: some View {
        if let text = UsageText.context(u) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // In a narrow pane the bar gives way, never the figure.
                    if let f = u.contextFraction {
                        ContextBar(fraction: f, near: u.isNearContextLimit)
                            .frame(minWidth: 48, maxWidth: 160)
                            .frame(height: 8)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    }
                    Text(text).monospacedDigit()
                        .fixedSize()
                        .layoutPriority(1)
                }
                if u.isNearContextLimit {
                    Text("Near the limit")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.clayText)
                }
            }
        } else {
            Text("No replies yet").foregroundStyle(Color.quiet)
        }
    }

    @ViewBuilder
    private var compactions: some View {
        let all = u.context.compactions
        if all.isEmpty {
            Text("None")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(all.suffix(6).enumerated()), id: \.offset) { _, c in
                    Text(UsageText.compaction(c)).monospacedDigit()
                }
                if all.count > 6 { Text("and \(all.count - 6) earlier").foregroundStyle(Color.quiet) }
            }
        }
    }

    @ViewBuilder
    private var errors: some View {
        let e = UsageText.errors(u)
        VStack(alignment: .leading, spacing: 2) {
            Text(e.summary).monospacedDigit()
            ForEach(Array(e.lines.enumerated()), id: \.offset) { _, line in
                Text(line.text).foregroundStyle(Color.quiet).monospacedDigit()
                    .help(line.message ?? "")
            }
            if e.more > 0 { Text("and \(e.more) earlier").foregroundStyle(Color.quiet) }
        }
    }
}

/// A row label in the detail pane: quiet, right-aligned, one width for every grid in the pane.
struct DetailLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(Color.quiet)
            .frame(minWidth: 92, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }
}

/// Context over time: the main thread's context after each reply, on a reply axis (a session resumed
/// days later has no long gap), with each compaction marked and, with a known window, its 80% line.
struct ContextChart: View {
    let u: SessionUsage

    var body: some View {
        let points = UsageText.chartPoints(u)
        let marks = UsageText.compactionMarks(u)
        let n = max(u.context.replies.count, 1)
        let lastX = max(points.last?.x ?? 1, Double(n))
        let window = u.contextWindow.map(Double.init)
        let peak = Double(points.map(\.tokens).max() ?? 0)
        let top = max(window ?? 0, peak, 1)
        VStack(alignment: .leading, spacing: 4) {
            Chart {
                if let window {
                    RuleMark(y: .value("Near the limit", window * 0.8))
                        .foregroundStyle(Color.clayText.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if points.count == 1, let p = points.first {
                    // One reply: a line needs two points, so a dot.
                    PointMark(x: .value("Reply", p.x), y: .value("Tokens", p.tokens))
                        .foregroundStyle(Color(nsColor: UsageStyle.fill))
                        .symbolSize(40)
                } else {
                    ForEach(points) { p in
                        AreaMark(x: .value("Reply", p.x), y: .value("Tokens", p.tokens))
                            .foregroundStyle(Color(nsColor: UsageStyle.fill).opacity(0.18))
                        LineMark(x: .value("Reply", p.x), y: .value("Tokens", p.tokens))
                            .foregroundStyle(Color(nsColor: UsageStyle.fill))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                    RuleMark(x: .value("Compaction", min(max(m.x, 1), lastX)))
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1.25))
                }
            }
            // One point: in the middle, with one label under it.
            .chartXScale(domain: points.count == 1 ? 0.5...1.5 : 1...max(lastX, 2))
            .chartYScale(domain: 0...top)
            .chartXAxis {
                AxisMarks(values: points.count == 1 ? [1] : [1, lastX]) { v in
                    let x = v.as(Double.self) ?? 1
                    AxisValueLabel(anchor: points.count == 1 ? .top : x <= 1 ? .topLeading : .topTrailing) {
                        Text(x <= 1 ? "reply 1" : "reply \(n.formatted(.number))")
                    }
                    .foregroundStyle(Color.quiet)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, top / 2, top]) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel(anchor: .leading) {
                        if let y = v.as(Double.self) { Text(UsageFormat.tokens(Int(y))) }
                    }
                    .foregroundStyle(Color.quiet)
                }
            }
            .frame(height: 110)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Context over time")
            .accessibilityValue(UsageText.chartSummary(u))
            .accessibilityChartDescriptor(ContextChartDescriptor(u: u))

            Text(legend(window: window))
                .font(.caption)
                .foregroundStyle(Color.quiet)
        }
    }

    private func legend(window: Double?) -> String {
        var parts = ["After each reply"]
        if !u.context.compactions.isEmpty { parts.append("vertical lines: compactions") }
        if window != nil { parts.append("dashed line: 80%, near the limit") }
        return parts.joined(separator: "; ")
    }
}

/// Audio Graphs for VoiceOver: the same points as the chart.
struct ContextChartDescriptor: AXChartDescriptorRepresentable {
    let u: SessionUsage

    func makeChartDescriptor() -> AXChartDescriptor {
        let points = UsageText.chartPoints(u)
        let top = Double(max(u.contextWindow ?? 0, points.map(\.tokens).max() ?? 0, 1))
        let x = AXNumericDataAxisDescriptor(title: "Reply", range: 1...Double(max(points.last.map { Int($0.x.rounded(.up)) } ?? 1, 2)),
                                            gridlinePositions: []) { "reply \(Int($0))" }
        let y = AXNumericDataAxisDescriptor(title: "Tokens in context", range: 0...top, gridlinePositions: []) {
            UsageFormat.tokens(Int($0))
        }
        let series = AXDataSeriesDescriptor(name: "Context", isContinuous: true,
                                            dataPoints: points.map { AXDataPoint(x: $0.x, y: Double($0.tokens)) })
        return AXChartDescriptor(title: "Context over time", summary: UsageText.chartSummary(u), xAxis: x, yAxis: y,
                                 additionalAxes: [], series: [series])
    }
}
