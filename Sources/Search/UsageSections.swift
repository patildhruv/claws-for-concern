import AppKit
import Charts
import SwiftUI

// The Usage window's sections. Every figure that is not Claude Code's own says "est."; costs are "at
// API prices" and go through `UsageModel.money`, so the second currency shows wherever dollars do.

/// Colours and shades for the Usage window, computed for WCAG AA (docs/usage-window.md has the ratios):
/// text 4.5:1 and marks 3:1 on the cards, in light and dark, stronger with Increase Contrast.
enum UsageStyle {
    static func rgb(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    static func adaptive(_ light: Int, _ dark: Int, high: (Int, Int)? = nil) -> NSColor {
        NSColor(name: nil) { a in
            switch a.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua?: return rgb(dark)
            case .accessibilityHighContrastAqua?: return rgb(high?.0 ?? light)
            case .accessibilityHighContrastDarkAqua?: return rgb(high?.1 ?? dark)
            default: return rgb(light)
            }
        }
    }

    /// Secondary text: `Brand.quietText`, the one AA grey both windows use. The system's secondary label
    /// is 3.9:1 on white on macOS 27 (black at 50%), under AA.
    static let secondaryText = Color(nsColor: Brand.quietText)
    /// Search's context bar below the limit: 3.95:1 on white, 3.35:1 on the selected row (light);
    /// 5.92:1 and 3.97:1 (dark).
    static let fill = adaptive(0x808080, 0x9A9A9A, high: (0x5E5E5E, 0xBDBDBD))
    /// Cards on the window's background (white, #1E1E1E).
    static let card = Color(nsColor: adaptive(0xF5F5F5, 0x262626, high: (0xF0F0F0, 0x2C2C2C)))
    static let cardEdge = Color(nsColor: adaptive(0xE3E3E3, 0x353535, high: (0x9A9A9A, 0x8A8A8A)))
    /// The empty part of a bar (decorative: the filled part carries the value, 3:1 on the card).
    static let track = Color(nsColor: adaptive(0xE0E0E0, 0x3C3C3C, high: (0xBDBDBD, 0x5A5A5A)))

    /// Project colours, in this fixed order (validated as a set: adjacent pairs apart under protan and
    /// deutan simulation, each 3:1 on the card): clay, blue, green, violet, magenta; the rest grey.
    static let series: [Color] = [
        adaptive(0xC45A35, 0xD9734F), adaptive(0x2A78D6, 0x3987E5), adaptive(0x16875F, 0x199E70),
        adaptive(0x6250D6, 0x9085E9), adaptive(0xC4457C, 0xD55181),
    ].map { Color(nsColor: $0) }
    static let other = Color(nsColor: adaptive(0x808080, 0x8C8C8C))
    static func color(slot: Int?) -> Color { slot.map { series[$0 % series.count] } ?? other }

    /// A context bar at 80% or more: deeper than clay, so it stands out from the rest.
    static let near = Color(nsColor: adaptive(0x8F3A1C, 0xF09A7A))
    static let contextBar = series[0]

    /// The heatmap: one hue (clay), light to dark with the amount; no work at all is the track grey.
    static func heat(_ t: Double) -> Color {
        guard t > 0 else { return track }
        let x = min(1, pow(t, 0.7))
        return Color(nsColor: NSColor(name: nil) { a in
            let dark = a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (lo, hi) = dark ? (0x4D3027, 0xF4AE93) : (0xF4D8CC, 0x983A1A)
            func ch(_ v: Int, _ s: Int) -> CGFloat { CGFloat((v >> s) & 255) / 255 }
            func mix(_ s: Int) -> CGFloat { ch(lo, s) + (ch(hi, s) - ch(lo, s)) * x }
            return NSColor(srgbRed: mix(16), green: mix(8), blue: mix(0), alpha: 1)
        })
    }
}

extension View {
    func usageCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UsageStyle.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UsageStyle.cardEdge, lineWidth: 0.5))
    }
}

struct SectionTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(UsageStyle.secondaryText) }
        }
    }
}

/// Secondary text in a table cell: our grey on the plain row, the system's own secondary style on a
/// selected row's accent colour (where a fixed grey would be unreadable).
struct QuietText: View {
    let text: String
    var font: Font = .caption
    @Environment(\.backgroundProminence) private var prominence

    init(_ text: String, font: Font = .caption) {
        self.text = text
        self.font = font
    }

    var body: some View {
        Text(text).font(font)
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(UsageStyle.secondaryText))
    }
}

/// A rounded bar, filled to `fraction` of its width.
struct UsageBar: View {
    let fraction: Double
    var color: Color = UsageStyle.contextBar

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(UsageStyle.track)
                Capsule().fill(color).frame(width: max(fraction > 0 ? 3 : 0, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Formatting a row

extension UsageRow {
    /// "$12.40", "$12.40 est.", "≥ $3.10 est." when part could not be priced, "Unknown" when none of it
    /// could. The table writes the second currency (`UsageModel.secondMoney`) on a line under it.
    var dollarsText: String {
        UsageCost.text(cost, atLeast: costPartial, money: UsageFormat.usd) + (cost != nil && costEstimate ? " est." : "")
    }

    var costHelp: String {
        guard cost != nil else { return "No price for \(unpriced.joined(separator: ", ")): the cost is unknown, not zero." }
        switch costKind {
        case .claudeCode: return "Claude Code's own figure, at API prices."
        case .claudeCodeSplit: return "Claude Code's figure for the whole session, split by day for this range (est.), at API prices."
        case .estimate:
            var s = "Estimated here from the session's tokens, at API prices."
            if costPartial { s += " Part could not be priced (\(unpriced.joined(separator: ", "))): the cost is at least this." }
            return s
        }
    }

    /// "85%", or tokens when the model's window is not known.
    var contextText: String {
        if let f = contextFraction { return UsageFormat.percent(f) }
        return contextNow.map(UsageFormat.tokens) ?? "–"
    }

    /// "85% · 855K of 1M", "855K tokens".
    var contextLine: String {
        guard let now = contextNow else { return "–" }
        guard let f = contextFraction, let w = contextWindow else { return "\(UsageFormat.tokens(now)) tokens" }
        return "\(UsageFormat.percent(f)) · \(UsageFormat.tokens(now)) of \(UsageFormat.tokens(w))"
    }

    var contextHelp: String {
        guard let now = contextNow else { return "No reply yet" }
        guard let f = contextFraction, let w = contextWindow else {
            return "\(UsageFormat.tokens(now)) tokens in context; this model's window is not known" + (nearLimit ? ", near the limit" : "")
        }
        return "\(UsageFormat.tokens(now)) of \(UsageFormat.tokens(w)) tokens (\(UsageFormat.percent(f)))" + (nearLimit ? ", near the limit" : "")
    }

    /// "+120 −8", "+120", "−8", "0"; a side that is zero is left out.
    var linesText: String {
        UsageRow.lines(linesAdded, linesRemoved) + (linesEstimate && linesAdded + linesRemoved > 0 ? " est." : "")
    }

    static func lines(_ added: Int, _ removed: Int) -> String {
        let parts = (added > 0 ? ["+" + added.formatted(.number)] : []) + (removed > 0 ? ["−" + removed.formatted(.number)] : [])
        return parts.isEmpty ? "0" : parts.joined(separator: " ")
    }

    var lastActiveText: String {
        lastActive.map { $0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)) } ?? "–"
    }
}

// MARK: Tiles

struct UsageTiles: View {
    @EnvironmentObject var vm: UsageWindowModel
    @EnvironmentObject var usage: UsageModel

    var body: some View {
        let t = vm.report.totals
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: Self.heading(vm.filter))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 172), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                UsageTile(label: "Cost at API prices", value: Self.costValue(t, money: UsageFormat.usd),
                          tag: t.costEstimate && !t.costUnknown ? "est." : nil, sub: costSub(t))
                UsageTile(label: "Written by Claude", value: UsageFormat.tokens(t.written), sub: "output tokens")
                UsageTile(label: "Claude worked", value: UsageFormat.duration(t.workSeconds),
                          sub: "on \(t.workDays) day\(t.workDays == 1 ? "" : "s")")
                UsageTile(label: "Sessions", value: t.sessions.formatted(.number),
                          sub: "in \(t.projects) project\(t.projects == 1 ? "" : "s")")
                UsageTile(label: "Lines changed", value: "+\(t.linesAdded.formatted(.number))", tag: t.linesEstimate ? "est." : nil,
                          sub: "−\(t.linesRemoved.formatted(.number)) removed")
                UsageTile(label: "Compactions", value: t.compactions.formatted(.number),
                          sub: "\(t.autoCompactions) automatic, \(t.manualCompactions) by /compact")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("At API prices: what these tokens would cost on Anthropic's API. On a Pro or Max plan this is not your bill. est.: worked out here from the tokens, not Claude Code's own figure.")
                if let note = unpricedNote(t) { Text(note) }
            }
            .font(.caption)
            .foregroundStyle(UsageStyle.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Totals for the last 30 days", and with a model filter, what the figures then are: whole sessions.
    nonisolated static func heading(_ f: UsageFilter) -> String {
        let span: String
        switch f.range {
        case .today: span = "Totals for today"
        case .week: span = "Totals for the last 7 days"
        case .month: span = "Totals for the last 30 days"
        case .all: span = "Totals for all time"
        }
        guard let m = f.model else { return span }
        return "\(span): sessions where \(m) replied, all their models counted"
    }

    /// "Unknown" when nothing could be priced, "≥ $12.40" when part could not, else "$12.40".
    nonisolated static func costValue(_ t: UsageTotals, money: (Double) -> String) -> String {
        UsageCost.text(t.costUnknown ? nil : t.cost, atLeast: t.costAtLeast, money: money)
    }

    private func costSub(_ t: UsageTotals) -> String {
        if t.costUnknown { return "no API price for these models" }
        if let second = usage.secondMoney(t.cost), let rate = usage.rateLine { return "\(t.costAtLeast ? "≥ " : "")\(second) · \(rate)" }
        if t.costAtLeast { return "what could be priced" }
        return t.costEstimate ? "includes estimates" : "Claude Code's own figures"
    }

    private func unpricedNote(_ t: UsageTotals) -> String? {
        let models = vm.report.unpriced.map(UsageFormat.model).joined(separator: ", ")
        var parts: [String] = []
        if t.unknownSessions > 0 {
            parts.append(t.unknownSessions == 1 ? "1 session could not be priced; it counts as unknown, not $0"
                         : "\(t.unknownSessions) sessions could not be priced; they count as unknown, not $0")
        }
        if t.partialSessions > 0 {
            parts.append(t.partialSessions == 1 ? "1 session could be priced only in part (≥ in the table)"
                         : "\(t.partialSessions) sessions could be priced only in part (≥ in the table)")
        }
        guard !parts.isEmpty else { return nil }
        return "No API price for \(models): " + parts.joined(separator: "; ") + "."
    }
}

struct UsageTile: View {
    let label: String
    let value: String
    var tag: String?
    let sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout).foregroundStyle(UsageStyle.secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                if let tag { Text(tag).font(.callout).foregroundStyle(UsageStyle.secondaryText) }
            }
            Text(sub).font(.caption).foregroundStyle(UsageStyle.secondaryText).lineLimit(2, reservesSpace: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UsageStyle.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UsageStyle.cardEdge, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Cost per day

struct CostPerDaySection: View {
    @EnvironmentObject var vm: UsageWindowModel
    @EnvironmentObject var usage: UsageModel
    @State private var hover: Date?
    private let calendar = Calendar.usage

    var body: some View {
        let r = vm.report
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Cost per day, by project")
            if r.days.isEmpty {
                Text(r.totals.costUnknown ? "No API price for these sessions' models: their cost is unknown." : "No cost in this range.")
                    .font(.callout).foregroundStyle(UsageStyle.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
            } else {
                legend(r)
                chart(r).frame(height: 190)
            }
        }
        .usageCard()
    }

    private func legend(_ r: UsageReport) -> some View {
        HStack(spacing: 14) {
            ForEach(r.series, id: \.key) { s in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(UsageStyle.color(slot: s.slot)).frame(width: 10, height: 10)
                    Text(s.name).font(.caption).lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Projects: " + r.series.map(\.name).joined(separator: ", "))
    }

    private func domain(_ r: UsageReport) -> ClosedRange<Date> {
        let start = r.dayDomain?.lowerBound ?? calendar.startOfDay(for: Date())
        let last = r.dayDomain?.upperBound ?? start
        return start...(calendar.date(byAdding: .day, value: 1, to: last) ?? last)
    }

    private func chart(_ r: UsageReport) -> some View {
        let d = domain(r)
        let dayCount = max(1, calendar.dateComponents([.day], from: d.lowerBound, to: d.upperBound).day ?? 1)
        let stride = dayCount <= 8 ? 1 : Int((Double(dayCount) / 6).rounded(.up))
        let ratio = dayCount <= 2 ? 0.25 : 0.72
        return Chart {
            ForEach(r.days) { day in
                BarMark(x: .value("Day", day.day, unit: .day), yStart: .value("Cost", day.start), yEnd: .value("Cost", day.start + day.cost),
                        width: .ratio(ratio))
                    // Keyed by project key: two projects may share a folder name, never a key.
                    .foregroundStyle(by: .value("Project", day.series))
                    .accessibilityLabel("\(r.seriesName(day.series)), \(Self.dayText(day.day))")
                    .accessibilityValue(UsageFormat.usd(day.cost) + " at API prices")
            }
            // A 2 pt gap of the card's colour where two parts of a day meet, so neighbours never touch.
            ForEach(r.days.filter { $0.start > 0 }) { day in
                RuleMark(xStart: .value("Day", day.day.addingTimeInterval(86_400 * (1 - ratio) / 2)),
                         xEnd: .value("Day", day.day.addingTimeInterval(86_400 * (1 + ratio) / 2)),
                         y: .value("Cost", day.start))
                    .foregroundStyle(UsageStyle.card)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .accessibilityHidden(true)
            }
            if let hover {
                RuleMark(x: .value("Day", hover, unit: .day))
                    .foregroundStyle(UsageStyle.secondaryText.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(hover, r)
                    }
            }
        }
        .chartForegroundStyleScale(domain: r.series.map(\.key), range: r.series.map { UsageStyle.color(slot: $0.slot) })
        .chartLegend(.hidden)
        .chartXScale(domain: d)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: stride)) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let date = v.as(Date.self) {
                        Text(date, format: .dateTime.day().month(.abbreviated)).foregroundStyle(UsageStyle.secondaryText)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = v.as(Double.self) { Text(Self.axisUSD(amount)).foregroundStyle(UsageStyle.secondaryText) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { g in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            let x = p.x - (proxy.plotFrame.map { g[$0].origin.x } ?? 0)
                            if let date: Date = proxy.value(atX: x) {
                                let day = calendar.startOfDay(for: date)
                                hover = r.days.contains { $0.day == day } ? day : nil
                            }
                        case .ended:
                            hover = nil
                        }
                    }
            }
        }
        .accessibilityLabel("Cost per day, by project")
        .accessibilityValue(summary(r))
    }

    private func tooltip(_ day: Date, _ r: UsageReport) -> some View {
        let parts = r.days.filter { $0.day == day }.sorted { $0.cost > $1.cost }
        let total = parts.reduce(0) { $0 + $1.cost }
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(Self.dayText(day)): \(usage.money(total))").font(.caption.weight(.semibold))
            ForEach(parts) { p in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(UsageStyle.color(slot: r.series.first { $0.key == p.series }?.slot)).frame(width: 8, height: 8)
                    Text("\(r.seriesName(p.series)) \(UsageFormat.usd(p.cost))").font(.caption)
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(UsageStyle.cardEdge, lineWidth: 1))
    }

    private func summary(_ r: UsageReport) -> String {
        var byDay: [Date: Double] = [:]
        for d in r.days { byDay[d.day, default: 0] += d.cost }
        guard let top = byDay.max(by: { $0.value < $1.value }) else { return "No cost" }
        return "\(byDay.count) days with cost, highest \(UsageFormat.usd(top.value)) on \(Self.dayText(top.key))"
    }

    static func dayText(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }

    /// "$0", "$2.50", "$40", "$1.2K" for the axis.
    static func axisUSD(_ v: Double) -> String {
        if v >= 1000 { return "$" + UsageCSV.number(v / 1000, 1) + "K" }
        if v == v.rounded() { return String(format: "$%.0f", v) }
        return String(format: "$%.2f", v)
    }
}

// MARK: Near the context limit

struct NearLimitSection: View {
    @EnvironmentObject var vm: UsageWindowModel
    let open: (String) -> Void

    var body: some View {
        let rows = vm.report.near
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Near the context limit",
                         subtitle: "Running sessions at 80% of their context window or more: the next compaction is close.")
            if rows.isEmpty {
                Text(vm.live.isEmpty ? "No running sessions reported. Claws for Concern's hooks report them." : "None right now.")
                    .font(.callout)
                    .foregroundStyle(UsageStyle.secondaryText)
            } else {
                VStack(spacing: 6) {
                    ForEach(rows.prefix(5)) { NearRow(row: $0, open: open) }
                }
                if rows.count > 5 { Text("and \(rows.count - 5) more").font(.caption).foregroundStyle(UsageStyle.secondaryText) }
            }
        }
        .usageCard()
    }
}

struct NearRow: View {
    @EnvironmentObject var vm: UsageWindowModel
    let row: UsageRow
    let open: (String) -> Void

    var body: some View {
        let selected = vm.selection == row.id
        VStack(alignment: .leading, spacing: 5) {
            Text(row.title).font(.callout.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            UsageBar(fraction: row.contextFraction ?? 1, color: UsageStyle.near).frame(height: 7)
            HStack(alignment: .firstTextBaseline) {
                Text(row.folder).font(.caption).foregroundStyle(selected ? .primary : UsageStyle.secondaryText)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(row.contextLine).font(.callout.weight(.semibold)).monospacedDigit().fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SelectionBackground(selected: selected).padding(.horizontal, -6).padding(.vertical, -2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UsageStyle.cardEdge, lineWidth: selected ? 0 : 0.5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(row.id) }
        .simultaneousGesture(TapGesture().onEnded { vm.selection = row.id })
        .contextMenu { RowActions(id: row.id, open: open) }
        .help(row.contextHelp)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open in Search") { open(row.id) }
    }
}

/// Resume: clay with ink when it can act (5.9:1, as in Search); a plain grey bordered button when it
/// cannot, since a disabled prominent button keeps most of its clay and looks ready to press.
struct ResumeButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        if enabled {
            Button(action: action) { Label("Resume", systemImage: "terminal").foregroundStyle(Color.ink) }
                .buttonStyle(.borderedProminent)
                .tint(.clay)
        } else {
            Button(action: action) { Label("Resume", systemImage: "terminal") }
                .buttonStyle(.bordered)
                .disabled(true)
        }
    }
}

/// The row actions, for context menus.
struct RowActions: View {
    @EnvironmentObject var vm: UsageWindowModel
    let id: String
    let open: (String) -> Void

    var body: some View {
        let s = vm.session(id)
        Button("Open in Search") { open(id) }.disabled(s == nil)
        Button("Resume") { vm.resume(id) }.disabled(s?.canResume != true)
        Button("Copy Session ID") { vm.copyID(id) }
    }
}

// MARK: All sessions

struct AllSessionsSection: View {
    @EnvironmentObject var vm: UsageWindowModel
    @EnvironmentObject var usage: UsageModel
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                SectionTitle(title: "All sessions")
                Spacer(minLength: 12)
                actions
            }
            if vm.rows.isEmpty {
                CrabThought(emptyLine).frame(maxWidth: .infinity).frame(height: 300)
            } else {
                table.frame(height: 340)
            }
            Text(footnote).font(.caption).foregroundStyle(UsageStyle.secondaryText)
        }
        .usageCard()
    }

    private var emptyLine: String {
        if !vm.filter.find.isEmpty || vm.filter.project != nil || vm.filter.model != nil { return "No session matches these filters." }
        switch vm.filter.range {
        case .today: return "Claude has not worked today yet."
        case .week, .month: return "No sessions \(vm.filter.range.phrase)."
        case .all: return "No sessions yet."
        }
    }

    private var footnote: String {
        var s = "Click a column to sort. Return or a double-click opens the session in Search."
        if vm.rows.contains(where: \.costPartial) { s += " ≥: part of the session could not be priced." }
        return s
    }

    private var actions: some View {
        // Only a row that is shown and selected (`selectedRow`): a hidden one is never acted on.
        let id = vm.selectedRow?.id
        let s = vm.selectedSession
        let canResume = s?.canResume == true
        return HStack(spacing: 8) {
            Button { if let id { open(id) } } label: { Label("Open in Search", systemImage: "magnifyingglass") }
                .disabled(s == nil)
                .help(id == nil ? "Select a session first" : "Shows it in the Search window")
            ResumeButton(enabled: canResume) { if let id { vm.resume(id) } }
                .help(s?.whyNotResumable ?? (id == nil ? "Select a session first" : "Switches to its tab if it is still open, else resumes it in a new terminal tab"))
            Button { if let id { vm.copyID(id) } } label: { Label("Copy ID", systemImage: "number") }
                .disabled(id == nil)
            Button { vm.exportCSV(second: usage.second) } label: { Label("Export CSV…", systemImage: "square.and.arrow.up") }
                .disabled(vm.rows.isEmpty)
                .help("Saves the sessions shown, with these filters, as a CSV file")
        }
        .controlSize(.regular)
    }

    private var table: some View {
        Table(vm.rows, selection: $vm.selection, sortOrder: $vm.sortOrder) {
            TableColumn("Session", value: \UsageRow.title) { r in
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.title).lineLimit(1)
                    QuietText(r.folder).lineLimit(1).truncationMode(.middle)
                }
                // Titles truncate in the column: the whole name and folder on hover.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .help("\(r.title)\n\(r.folder)")
            }
            .width(min: 180, ideal: 214)
            TableColumn("Project", value: \UsageRow.projectName) { r in Text(r.projectName).lineLimit(1) }
                .width(min: 64, ideal: 96)
            TableColumn("Last active", value: \UsageRow.lastActiveKey) { r in
                Text(r.lastActiveText).lineLimit(1).help(r.lastActive?.formatted(date: .abbreviated, time: .shortened) ?? "")
            }
            .width(min: 70, ideal: 82)
            TableColumn("Context", value: \UsageRow.contextKey) { r in ContextCell(row: r) }
                .width(min: 90, ideal: 100)
            TableColumn("Compactions", value: \UsageRow.compactions) { r in
                Text(r.compactions.formatted(.number)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 62, ideal: 80)
            TableColumn("Cost", value: \UsageRow.costKey) { r in
                // The second currency on its own line under the dollars (rows are two lines anyway),
                // so the column stays narrow when it is on.
                VStack(alignment: .trailing, spacing: 1) {
                    Text(r.dollarsText).monospacedDigit().lineLimit(1)
                    if let c = r.cost, let second = usage.secondMoney(c) {
                        QuietText(second).monospacedDigit().lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(r.costHelp)
                .accessibilityElement(children: .combine)
            }
            .width(min: 80, ideal: 108)
            TableColumn("Written", value: \UsageRow.written) { r in
                Text(UsageFormat.tokens(r.written)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                    .help("\(r.written.formatted(.number)) output tokens")
            }
            .width(min: 58, ideal: 64)
            TableColumn("Claude time", value: \UsageRow.workSeconds) { r in
                Text(UsageFormat.duration(r.workSeconds)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 62, ideal: 74)
            TableColumn("Lines", value: \UsageRow.linesKey) { r in
                Text(r.linesText).monospacedDigit().lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
                    .help(r.linesEstimate ? "Counted here from Edit and Write calls (est.)" : "Claude Code's own count")
            }
            .width(min: 80, ideal: 120)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first { RowActions(id: id, open: open) }
        } primaryAction: { ids in
            if let id = ids.first { open(id) }
        }
        .accessibilityLabel("All sessions")
    }
}

struct ContextCell: View {
    let row: UsageRow

    var body: some View {
        HStack(spacing: 6) {
            if let f = row.contextFraction {
                UsageBar(fraction: f, color: row.nearLimit ? UsageStyle.near : UsageStyle.contextBar).frame(width: 48, height: 6)
            }
            Text(row.contextText).monospacedDigit().fontWeight(row.nearLimit ? .semibold : .regular)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .help(row.contextHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.contextHelp)
    }
}

// MARK: By project, by model

struct ByProjectSection: View {
    @EnvironmentObject var vm: UsageWindowModel
    @EnvironmentObject var usage: UsageModel

    var body: some View {
        let projects = vm.report.projects
        let top = projects.map(\.cost).max() ?? 0
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "By project")
            if projects.isEmpty {
                Text("Nothing in this range.").font(.callout).foregroundStyle(UsageStyle.secondaryText)
            }
            ForEach(projects.prefix(6)) { p in
                Button { vm.filter.project = vm.filter.project == p.key ? nil : p.key } label: {
                    HStack(spacing: 10) {
                        Text(p.name).lineLimit(1).frame(width: 104, alignment: .leading)
                        UsageBar(fraction: top > 0 ? p.cost / top : 0, color: UsageStyle.color(slot: p.slot)).frame(height: 9)
                        Text(Self.costText(p, money: usage.money)).monospacedDigit().lineLimit(1).fixedSize()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(vm.filter.project == p.key ? "Show every project again" : "Show only \(p.name)")
                .accessibilityLabel(p.name)
                .accessibilityValue("\(Self.costText(p, money: usage.money)), \(UsageFormat.percent(p.share)) of the cost, \(p.sessions) sessions")
            }
            if projects.count > 6 {
                let rest = projects.dropFirst(6)
                let atLeast = rest.contains { $0.incomplete }
                Text("+\(rest.count) more: \(UsageCost.text(rest.reduce(0) { $0 + $1.cost }, atLeast: atLeast, money: usage.money))")
                    .foregroundStyle(UsageStyle.secondaryText)
                    .help(rest.map(\.name).joined(separator: ", "))
            }
        }
        .usageCard()
    }

    /// "$12.40 est.", "≥ $3.10 est." when some of its sessions could not be priced, "Unknown" when none could.
    nonisolated static func costText(_ p: UsageReport.ProjectTotal, money: (Double) -> String) -> String {
        UsageCost.text(p.known ? p.cost : nil, atLeast: p.incomplete, money: money) + (p.known && p.estimate ? " est." : "")
    }
}

struct ByModelSection: View {
    @EnvironmentObject var vm: UsageWindowModel
    @EnvironmentObject var usage: UsageModel

    var body: some View {
        let models = vm.report.models
        // Parts under 1% go together at the end, in grey, so the bar never needs more room than it has.
        let big = models.filter { $0.share >= 0.01 }
        let small = models.filter { $0.share > 0 && $0.share < 0.01 }.reduce(0) { $0 + $1.share }
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "By model")
            if let m = vm.filter.model {
                // The filter picks whole sessions: the figures here are every model in them, not m's alone.
                Text(Self.filterNote(m)).font(.caption).foregroundStyle(UsageStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if models.isEmpty {
                Text("Nothing in this range.").font(.callout).foregroundStyle(UsageStyle.secondaryText)
            } else {
                // One bar split by share of the cost, a 2 pt gap between the parts.
                GeometryReader { g in
                    let parts = big.map { (name: $0.name, share: $0.share, color: color($0.name)) }
                        + (small > 0 ? [(name: "", share: small, color: UsageStyle.other)] : [])
                    let room = g.size.width - CGFloat(max(parts.count - 1, 0)) * 2
                    HStack(spacing: 2) {
                        ForEach(parts, id: \.name) { p in
                            Rectangle().fill(p.color).frame(width: max(2, room * p.share))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 12)
                .accessibilityElement()
                .accessibilityLabel("Cost by model")
                .accessibilityValue(big.map { "\($0.name) \(UsageFormat.percent($0.share))" }.joined(separator: ", "))
                // The six that cost most, then the rest in one line; models with no price always show,
                // so an unknown cost is never hidden.
                let priced = models.filter { $0.cost != nil }
                let rest = priced.dropFirst(Self.shown)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(priced.prefix(Self.shown)) + models.filter { $0.cost == nil }) { m in
                        Button { vm.filter.model = vm.filter.model == m.name ? nil : m.name } label: {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(m.cost == nil ? UsageStyle.track : color(m.name)).frame(width: 10, height: 10)
                                Text(line(m)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(vm.filter.model == m.name ? "Show every model again" : Self.filterHelp(m.name))
                    }
                    if !rest.isEmpty {
                        Text("+\(rest.count) more: \(usage.money(rest.reduce(0) { $0 + ($1.cost ?? 0) })) est.")
                            .foregroundStyle(UsageStyle.secondaryText)
                            .help(rest.map(\.name).joined(separator: ", "))
                    }
                }
                Text("Each session's cost split by its models' share of its estimate.")
                    .font(.caption).foregroundStyle(UsageStyle.secondaryText)
            }
        }
        .usageCard()
    }

    static let shown = 6

    /// What clicking a model does: it keeps whole sessions, so it never isolates that model's cost.
    nonisolated static func filterHelp(_ m: String) -> String { "Show only sessions in which \(m) replied, with every model in them counted" }
    nonisolated static func filterNote(_ m: String) -> String { "Sessions where \(m) replied, all their models counted: not \(m)'s cost alone." }

    /// By the model's place in the all-time list, so a filter never repaints the others; under 1% grey.
    private func color(_ name: String) -> Color {
        guard let m = vm.report.models.first(where: { $0.name == name }), m.share >= 0.01,
              let i = vm.report.allModels.firstIndex(of: name), i < UsageStyle.series.count else { return UsageStyle.other }
        return UsageStyle.series[i]
    }

    private func line(_ m: UsageReport.ModelTotal) -> String {
        guard let c = m.cost else { return "\(m.name) · cost unknown · \(UsageFormat.tokens(m.written)) written" }
        return "\(m.name) · \(usage.money(c)) est. · \(m.share < 0.01 && m.share > 0 ? "under 1%" : UsageFormat.percent(m.share))"
    }
}

// MARK: When Claude works

struct WhenClaudeWorksSection: View {
    @EnvironmentObject var vm: UsageWindowModel

    var body: some View {
        let heat = vm.report.heat
        let top = heat.flatMap { $0 }.max() ?? 0
        let cal = Calendar.current
        let order = (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 }
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "When Claude works", subtitle: "Claude's working time by weekday and hour; darker is busier.")
            if top == 0 {
                Text("No working time in this range.").font(.callout).foregroundStyle(UsageStyle.secondaryText)
            } else {
                VStack(spacing: 3) {
                    ForEach(order, id: \.self) { w in
                        HStack(spacing: 3) {
                            Text(cal.shortWeekdaySymbols[w]).font(.caption).foregroundStyle(UsageStyle.secondaryText)
                                .frame(width: 34, alignment: .leading)
                            ForEach(0..<24, id: \.self) { h in
                                RoundedRectangle(cornerRadius: 2.5)
                                    .fill(UsageStyle.heat(heat[w][h] / top))
                                    .frame(maxWidth: .infinity, minHeight: 15, maxHeight: 15)
                                    .help("\(cal.weekdaySymbols[w]) \(Self.hour(h))–\(Self.hour(h + 1)): \(UsageFormat.duration(heat[w][h]))")
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(cal.weekdaySymbols[w])
                        .accessibilityValue(rowSummary(heat[w]))
                    }
                    HStack(spacing: 3) {
                        Color.clear.frame(width: 34, height: 1)
                        ForEach(0..<24, id: \.self) { h in
                            Text(h % 3 == 0 ? String(format: "%02d", h) : " ").font(.caption2).foregroundStyle(UsageStyle.secondaryText)
                                .lineLimit(1).fixedSize().frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .accessibilityHidden(true)
                }
                HStack(spacing: 4) {
                    Text(busiest(heat, order: order, cal: cal)).font(.caption).foregroundStyle(UsageStyle.secondaryText)
                    Spacer(minLength: 8)
                    Text("Less").font(.caption).foregroundStyle(UsageStyle.secondaryText)
                    ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { t in
                        RoundedRectangle(cornerRadius: 2).fill(UsageStyle.heat(t == 0 ? 0 : t)).frame(width: 11, height: 11)
                    }
                    Text("More").font(.caption).foregroundStyle(UsageStyle.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .usageCard()
    }

    static func hour(_ h: Int) -> String { String(format: "%02d:00", h % 24) }

    private func rowSummary(_ hours: [Double]) -> String {
        let total = hours.reduce(0, +)
        guard total > 0, let h = hours.indices.max(by: { hours[$0] < hours[$1] }) else { return "no work" }
        return "\(UsageFormat.duration(total)) in all, busiest \(Self.hour(h)) to \(Self.hour(h + 1)), \(UsageFormat.duration(hours[h]))"
    }

    private func busiest(_ heat: [[Double]], order: [Int], cal: Calendar) -> String {
        var best: (w: Int, h: Int, v: Double) = (0, 0, 0)
        for w in order { for h in 0..<24 where heat[w][h] > best.v { best = (w, h, heat[w][h]) } }
        return "Busiest: \(cal.weekdaySymbols[best.w]) \(Self.hour(best.h))–\(Self.hour(best.h + 1)), \(UsageFormat.duration(best.v))"
    }
}
