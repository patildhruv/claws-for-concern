import AppKit
import SwiftUI

/// The Usage window: every session's usage and cost, opened from the crab menu (Usage…) and from
/// Search's toolbar. Same process as Search, so the figures are read once (`UsageModel`). Filters sit
/// in the toolbar; below them the totals, cost per day, sessions near their context limit, every
/// session in a sortable table with its actions, then by project, by model and when Claude works.
/// Guide: docs/usage-window.md.
struct UsageWindow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var usage: UsageModel
    @StateObject private var vm: UsageWindowModel
    @ObservedObject private var currency = SecondCurrencySetting.shared
    @Environment(\.openWindow) private var openWindow

    /// `selectFirst`: the first row selected once figures arrive (the snapshot).
    init(filter: UsageFilter? = nil, selectFirst: Bool = false) {
        _vm = StateObject(wrappedValue: UsageWindowModel(filter: filter, selectFirst: selectFirst))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Usage")
        .toolbar { toolbar }
        // Only a row that is shown and selected: the Session menu's Resume, Copy ID and Show Transcript.
        .focusedSceneValue(\.usagePick, UsagePick(session: vm.selectedSession))
        .onAppear {
            vm.attach(app: model, usage: usage)
            vm.startLive()
            currency.refreshIfNeeded()
        }
        .onDisappear { vm.stopLive() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            usage.refresh()
            vm.refreshLive()
            vm.dayMayHaveChanged()
            currency.refreshIfNeeded()
        }
        .environmentObject(vm)
    }

    @ViewBuilder
    private var content: some View {
        if usage.updated == nil {
            CrabThought("Reading your sessions…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.report.sessionCount == 0 {
            CrabThought("No usage yet. Your Claude Code sessions will show up here.").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    UsageTiles()
                    HStack(alignment: .top, spacing: 16) {
                        CostPerDaySection()
                            .frame(maxWidth: .infinity)
                            .layoutPriority(1)
                        NearLimitSection(open: open)
                            .frame(minWidth: 300, idealWidth: 380, maxWidth: 420)
                    }
                    AllSessionsSection(open: open)
                    UsageBreakdown()
                }
                .padding(20)
            }
        }
    }

    private func open(_ id: String) {
        vm.openInSearch(id) { openWindow(id: HelperWindow.search.rawValue) }
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            if usage.loading { ProgressView().controlSize(.small) }
            Text(model.flash ?? vm.flash ?? statusLine)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(UsageStyle.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var statusLine: String {
        guard let updated = usage.updated else { return "Reading your sessions…" }
        let shown = vm.report.rows.count, all = vm.report.sessionCount
        let what = shown == all ? "\(all) sessions" : "\(shown) of \(all) sessions"
        return "\(what) · read at \(updated.formatted(date: .omitted, time: .shortened))"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Range", selection: $vm.filter.range) {
                ForEach(UsageRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Which days to count")

            Picker("Project", selection: $vm.filter.project) {
                Text("All Projects").tag(String?.none)
                Divider()
                ForEach(vm.report.allProjects, id: \.key) { p in Text(p.name).tag(Optional(p.key)) }
            }
            .pickerStyle(.menu)
            // A pop-up is as wide as its longest item: real project names pushed the rest into overflow.
            .frame(width: 150)
            .help("Only one project")

            Picker("Model", selection: $vm.filter.model) {
                Text("All Models").tag(String?.none)
                Divider()
                ForEach(vm.report.allModels, id: \.self) { m in Text(m).tag(Optional(m)) }
            }
            .pickerStyle(.menu)
            .frame(width: 130)
            .help("Only sessions in which this model replied, with every model in them counted")

            CurrencyMenu()

            Button { usage.refresh(); model.refresh(); vm.refreshLive() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Read changed transcripts again")
            .disabled(usage.loading)
        }
        // Its own field (⌘F comes here while this window is in front), a fixed width so it never folds away.
        ToolbarItem(placement: .primaryAction) {
            UsageFindField(text: $vm.filter.find, onSubmit: vm.applyFind)
                .frame(width: 190)
                .help("Find a session by name, folder, project or ID")
        }
    }
}

extension Notification.Name {
    /// ⌘F while the Usage window is in front: its Find field, not Search's.
    static let focusUsageFind = Notification.Name("ClawsSearch.focusUsageFind")
}

/// Where Edit → Find… (⌘F) goes: the window in front's own field.
enum FindTarget {
    static func note(usageInFront: Bool) -> Notification.Name { usageInFront ? .focusUsageFind : .focusSearch }
}

/// The Usage window's Find: an NSSearchField, so ⌘F can focus it (a SwiftUI `.searchable` field cannot
/// be focused from code on macOS 14). Esc clears it; Return applies it without waiting.
struct UsageFindField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Find a session"
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Find a session")
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: UsageFindField
        weak var field: NSSearchField?
        private var observer: NSObjectProtocol?

        init(_ parent: UsageFindField) {
            self.parent = parent
            super.init()
            observer = NotificationCenter.default.addObserver(forName: .focusUsageFind, object: nil, queue: .main) { [weak self] _ in
                guard let field = self?.field else { return }
                field.window?.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }

        deinit { observer.map(NotificationCenter.default.removeObserver) }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                (control as? NSSearchField)?.stringValue = ""
                parent.text = ""
                return true
            default:
                return false
            }
        }
    }
}

/// By project, by model and when Claude works: side by side when they fit, else one under another.
struct UsageBreakdown: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) { parts }
            VStack(alignment: .leading, spacing: 22) { parts }
        }
    }

    @ViewBuilder
    private var parts: some View {
        ByProjectSection().frame(minWidth: 260, maxWidth: .infinity, alignment: .topLeading)
        ByModelSection().frame(minWidth: 260, maxWidth: .infinity, alignment: .topLeading)
        WhenClaudeWorksSection().frame(minWidth: 400, maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The second currency, in the toolbar: off until you turn it on.
struct CurrencyMenu: View {
    @ObservedObject private var setting = SecondCurrencySetting.shared

    var body: some View {
        Menu {
            Toggle("Show a Second Currency", isOn: Binding(get: { setting.code != nil },
                                                           set: { setting.set($0 ? setting.lastCode : nil) }))
            Picker("Currency", selection: Binding(get: { setting.code ?? "" }, set: { setting.set($0) })) {
                ForEach(Currencies.offered) { c in Text("\(c.name) (\(c.symbol))").tag(c.code) }
            }
            Divider()
            Text(setting.statusLine)
            Text("Rates from frankfurter.dev, at most once a day while this is on.")
        } label: {
            Text(setting.code.flatMap { Currencies.info($0) }.map { "$ + \($0.symbol)" } ?? "$")
                .monospacedDigit()
        }
        .help(setting.code == nil ? "Show costs in a second currency too" : setting.statusLine)
    }
}

/// The two windows of the helper, by their scene IDs.
enum HelperWindow: String, CaseIterable {
    case search = "main", usage

    var title: String { self == .search ? "Search Sessions" : "Usage" }
    var defaultSize: CGSize { self == .search ? CGSize(width: 1180, height: 760) : CGSize(width: 1280, height: 860) }

    /// Which window comes up at launch: `--window usage` (the crab menu's Usage…) opens only Usage.
    static func atLaunch(_ args: [String]) -> HelperWindow {
        guard let i = args.firstIndex(of: "--window"), i + 1 < args.count else { return .search }
        return HelperWindow(rawValue: args[i + 1]) ?? .search
    }

    /// SwiftUI opens the first scene at launch (macOS 14 has no way to hold one back), so the window
    /// asked for is declared first.
    static func order(first: HelperWindow) -> [HelperWindow] { [first] + allCases.filter { $0 != first } }

    /// Set from the command line before the app starts.
    static var first = HelperWindow.search
}

/// Claws for Concern asks a running helper to bring up a window: `…search.openWindow` with the window
/// and the helper's PID (another copy of the helper ignores it). It only opens a window. The helper
/// answers `…search.openedWindow` with the same two, so Claws stops asking (it asks again until then:
/// a helper still starting up has no window listening yet).
enum WindowRequest {
    static let note = Notification.Name(ResumeRequest.appID + ".search.openWindow")
    static let answer = Notification.Name(ResumeRequest.appID + ".search.openedWindow")

    static func window(from userInfo: [AnyHashable: Any]?, pid: Int32 = getpid()) -> HelperWindow? {
        guard let name = userInfo?["window"] as? String, let w = HelperWindow(rawValue: name) else { return nil }
        if let target = userInfo?["pid"] as? Int, Int32(truncatingIfNeeded: target) != pid { return nil }
        return w
    }

    static func answer(_ w: HelperWindow, pid: Int32 = getpid()) -> [String: Any] { ["window": w.rawValue, "pid": Int(pid)] }
}

extension View {
    /// Opens the window Claws asks for (`WindowRequest`). On both windows, as either may be the only one.
    func opensRequestedWindows() -> some View { background(WindowRequestListener()) }
}

private struct WindowRequestListener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onReceive(DistributedNotificationCenter.default().publisher(for: WindowRequest.note).receive(on: RunLoop.main)) { note in
                guard let w = WindowRequest.window(from: note.userInfo) else { return }
                openWindow(id: w.rawValue)
                NSApp.activate()
                DistributedNotificationCenter.default().postNotificationName(WindowRequest.answer, object: nil,
                                                                             userInfo: WindowRequest.answer(w), deliverImmediately: true)
            }
    }
}
