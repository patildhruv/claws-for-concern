import AppKit
import SwiftUI

extension Notification.Name {
    static let focusSearch = Notification.Name("ClawsSearch.focusSearch")
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            ResultsColumn()
                .navigationSplitViewColumnWidth(min: 340, ideal: 440, max: 720)
        } detail: {
            if let s = model.selectedSession {
                DetailView(session: s)
            } else if model.sessionCount == 0 && model.indexing {
                ProgressView("Reading transcripts…")
            } else {
                ContentUnavailableView(model.query.isEmpty ? "No Sessions" : "No Matches",
                                       systemImage: "magnifyingglass",
                                       description: Text(model.query.isEmpty
                                           ? "Nothing in ~/.claude/projects yet."
                                           : "Try fewer words, or turn on more places under Search In."))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Sort", selection: $model.sort) {
                    Text("Relevance").tag(SortMode.relevance)
                    Text("Recent").tag(SortMode.recent)
                }
                .pickerStyle(.segmented)
                .help("Sort results")

                Menu {
                    Toggle("Your prompts", isOn: model.binding(.prompts))
                    Toggle("Claude's replies", isOn: model.binding(.replies))
                    Toggle("Tool calls (commands, paths, edits)", isOn: model.binding(.toolCalls))
                    Toggle("Subagent transcripts", isOn: model.binding(.subagents))
                    Divider()
                    Text("Names, folders and session IDs are always searched.")
                    Text("Tool output is not indexed.")
                } label: {
                    Label("Search In", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Choose which parts of a conversation to search")

                Button { model.refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Re-read changed transcripts (⌘R)")
                .disabled(model.indexing)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}

struct ResultsColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $model.query, onMove: model.moveSelection, onSubmit: model.resumeSelected)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)
            ScrollViewReader { proxy in
                List(model.hits, selection: $model.selection) { hit in
                    ResultRow(hit: hit, snippet: model.snippets[hit.id])
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let s = model.session(ids.first) {
                        Button("Resume") { model.resume(s) }.disabled(!s.canResume)
                        Button("Copy Resume Command") { model.copyCommand(s) }
                        Button("Copy Session ID") { model.copyID(s) }
                        Divider()
                        Button("Show Transcript in Finder") { model.reveal(s) }
                    }
                } primaryAction: { ids in
                    if let s = model.session(ids.first) { model.resume(s) }
                }
                .onChange(of: model.selection) { _, id in
                    // Deferred: scrolling while the table is mid-update is a reentrant delegate call.
                    if let id { DispatchQueue.main.async { proxy.scrollTo(id) } }
                }
            }
            HStack(spacing: 6) {
                if model.indexing { ProgressView().controlSize(.small) }
                Text(model.flash ?? model.statusLine)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

struct ResultRow: View {
    let hit: Hit
    let snippet: AttributedString?

    var body: some View {
        let s = hit.session
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(s.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(s.modified.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .imageScale(.small)
                Text(s.displayCwd)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(s.id.prefix(8))
                    .monospaced()
                    .fixedSize()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // Always two lines, so rows keep one height and the list doesn't jump as previews arrive.
            Text(snippet ?? AttributedString(" "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .padding(.vertical, 3)
    }
}

struct DetailView: View {
    @EnvironmentObject var model: AppModel
    let session: Session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions
                Divider()
                matches
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(session.title)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    label("Location")
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(session.cwd.map(Paths.abbreviate) ?? "\(session.projectDir) (folder not recorded)")
                                .textSelection(.enabled)
                            if session.folderMissing == true {
                                Text("folder no longer exists")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        if session.cwdUncertain {
                            Text("Filed under \(session.projectDir), which doesn't match this folder; resuming may not find it from here.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if let first = session.recordedCwd {
                            Text("Conversation began in \(Paths.abbreviate(first)); Claude Code files it under this folder.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow {
                    label("Session ID")
                    Text(session.id).monospaced().textSelection(.enabled)
                }
                GridRow {
                    label("Name from")
                    Text(session.titleSource.rawValue).foregroundStyle(.secondary)
                }
                if !session.altTitles.isEmpty {
                    GridRow {
                        label("Also named")
                        Text(session.altTitles.joined(separator: " · ")).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if let branch = session.gitBranch, branch != "HEAD" {
                    GridRow { label("Branch"); Text(branch).textSelection(.enabled) }
                }
                if let created = session.created {
                    GridRow { label("Started"); Text(created.formatted(date: .abbreviated, time: .shortened)) }
                }
                GridRow {
                    label("Last active")
                    Text("\(session.modified.formatted(date: .abbreviated, time: .shortened)) · \(session.modified.formatted(.relative(presentation: .named)))")
                }
                GridRow {
                    label("Transcript")
                    Text(transcriptLine).foregroundStyle(.secondary)
                }
                if let e = session.entrypoint, e != "cli" {
                    GridRow { label("Started by"); Text(e == "sdk-cli" ? "claude -p or the SDK (headless)" : e) }
                }
            }
        }
    }

    private var transcriptLine: String {
        var parts = [ByteCountFormatter.string(fromByteCount: Int64(session.fileSize), countStyle: .file),
                     "\(session.promptCount) prompts"]
        if session.subagentCount > 0 {
            parts.append("\(session.subagentCount) subagent transcript\(session.subagentCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { model.resume(session) } label: {
                    Label("Resume", systemImage: "terminal")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.canResume)
                .help("Switches to its tab if it is still open, else resumes it in a new terminal tab")
                Button { model.copyCommand(session) } label: {
                    Label("Copy Command", systemImage: "doc.on.doc")
                }
                Button { model.copyID(session) } label: {
                    Label("Copy ID", systemImage: "number")
                }
                Button { model.reveal(session) } label: {
                    Label("Show Transcript", systemImage: "doc.text.magnifyingglass")
                }
            }
            Text(session.resumeCommand())
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var matches: some View {
        let ready = model.excerptSessionID == session.id
        VStack(alignment: .leading, spacing: 10) {
            Text(heading(ready: ready))
                .font(.headline)
            if ready {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.excerpts) { ExcerptView(excerpt: $0) }
                }
            }
        }
    }

    private func heading(ready: Bool) -> String {
        guard ready else { return "Looking for matches…" }
        let total = model.excerptTotal
        let shown = model.excerpts.count
        let more = total > shown ? " (first \(shown) shown)" : ""
        if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            return total == 0 ? "No prompts recorded" : "Your prompts\(more)"
        }
        if total == 0 { return "Matched on the name, folder or ID" }
        return "\(total) matching message\(total == 1 ? "" : "s")\(more)"
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}

struct ExcerptView: View {
    let excerpt: Excerpt

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(role)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(excerpt.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let date = excerpt.date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var role: String {
        if excerpt.subagent { return "Subagent" }
        switch excerpt.kind {
        case .prompt: return "You"
        case .reply: return "Claude"
        case .toolCall: return "Tool call"
        }
    }

    private var color: Color {
        if excerpt.subagent { return .purple }
        switch excerpt.kind {
        case .prompt: return .accentColor
        case .reply: return .orange
        case .toolCall: return .secondary
        }
    }
}

/// NSSearchField, so arrow keys can move the result selection and Return can resume
/// without the field losing focus.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var onMove: (Int) -> Void
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search conversations: words, \"exact phrase\", folder or ID"
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        field.controlSize = .large
        context.coordinator.field = field
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        weak var field: NSSearchField?
        private var observer: NSObjectProtocol?

        init(_ parent: SearchField) {
            self.parent = parent
            super.init()
            observer = NotificationCenter.default.addObserver(forName: .focusSearch, object: nil, queue: .main) { [weak self] _ in
                guard let field = self?.field else { return }
                field.window?.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                (control as? NSSearchField)?.stringValue = ""
                parent.text = ""
                return true
            default: return false
            }
        }
    }
}
