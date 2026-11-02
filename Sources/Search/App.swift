import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { exit(SelfTest.run()) }
        if args.contains("--search") { exit(CLI.search(args)) }
        if args.contains("--resume") { exit(CLI.resume(args)) }
        if args.contains("--snapshot") { exit(MainActor.assumeIsolated { Snapshot.run(args) }) }
        ClawsSearchApp.main()
    }
}

/// The search window. Claws for Concern opens this helper from its menu; it quits when the window
/// closes, so the index (a few hundred MB) only lives while you search.
struct ClawsSearchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Claws Search", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 480)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { SessionCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opened from a menu bar app, which is not active itself: ask to come forward.
        NSApp.activate()
        // Never linger as a Dock icon with nothing to close: if no window came up, quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if !NSApp.windows.contains(where: { $0.isVisible || $0.isMiniaturized }) { NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// ⌘W or ⌘Q right after Resume: wait up to 3 s for Claws' answer, else copy the command, then quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard ResumeClient.shared.hasPending else { return .terminateNow }
            ResumeClient.shared.settle(within: 3) { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
    }
}

struct SessionCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Search Conversations") { NotificationCenter.default.post(name: .focusSearch, object: nil) }
                .keyboardShortcut("f")
        }
        CommandMenu("Session") {
            let s = model.selectedSession
            Button("Resume") { if let s { model.resume(s) } }
                .keyboardShortcut("o")
                .disabled(s?.canResume != true)
            Button("Copy Resume Command") { if let s { model.copyCommand(s) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(s?.resumeCommand() == nil)
            Button("Copy Session ID") { if let s { model.copyID(s) } }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(s == nil)
            Button("Show Transcript in Finder") { if let s { model.reveal(s) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(s == nil)
            Divider()
            Button("Refresh Index") { model.refresh() }
                .keyboardShortcut("r")
        }
    }
}

enum CLI {
    private static func value(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// `ClawsSearch --search <query> [--limit N] [--recent] [--scope prompts,replies,tools,subagents]`
    static func search(_ args: [String]) -> Int32 {
        guard let raw = value(args, "--search") else {
            FileHandle.standardError.write("usage: ClawsSearch --search <query> [--limit N] [--recent] [--scope prompts,replies,tools,subagents]\n".data(using: .utf8)!)
            return 2
        }
        let limit = value(args, "--limit").flatMap(Int.init) ?? 15
        var scope = Scope.standard
        if let list = value(args, "--scope") {
            scope = []
            for part in list.split(separator: ",") {
                switch part {
                case "prompts": scope.insert(.prompts)
                case "replies": scope.insert(.replies)
                case "tools": scope.insert(.toolCalls)
                case "subagents": scope.insert(.subagents)
                default: break
                }
            }
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        let (sessions, _) = SessionStore().load()
        let t1 = CFAbsoluteTimeGetCurrent()
        let index = SearchIndex(sessions: sessions)
        let t2 = CFAbsoluteTimeGetCurrent()
        guard let out = index.search(ParsedQuery(raw), scope: scope, sort: args.contains("--recent") ? .recent : .relevance,
                                     cancelled: { false }) else { return 1 }
        let t3 = CFAbsoluteTimeGetCurrent()

        let ansi = isatty(1) != 0
        for (n, hit) in out.hits.prefix(limit).enumerated() {
            let s = hit.session
            let when = s.modified.formatted(date: .abbreviated, time: .shortened)
            print("\(n + 1). \(s.title)")
            print("   \(s.displayCwd)   \(s.id)   \(when)")
            if let snip = Snippets.row(s, out) { print("   " + Snippets.terminal(snip, ansi: ansi)) }
        }
        let timing = String(format: "%d of %d sessions · read %.2fs, index %.2fs, query %.0fms\n",
                            out.hits.count, sessions.count, t1 - t0, t2 - t1, (t3 - t2) * 1000)
        FileHandle.standardError.write(timing.data(using: .utf8)!)
        return 0
    }

    /// `ClawsSearch --resume <session id or prefix>`: the Resume button's request to Claws for Concern,
    /// printing each answer; exits 0 once the tab is focused or opened, 1 otherwise. It carries a nonce
    /// Claws never issued and comes from a terminal, not the Search window, so a correct Claws refuses
    /// it: this checks that refusal.
    static func resume(_ args: [String]) -> Int32 {
        guard let prefix = value(args, "--resume"), !prefix.isEmpty else {
            print("usage: ClawsSearch --resume <session id or prefix>"); return 2
        }
        let matches = SessionStore().load().sessions.filter { $0.id.hasPrefix(prefix) }
        guard matches.count == 1, let s = matches.first else {
            print(matches.isEmpty ? "no session \(prefix)" : "\(matches.count) sessions start with \(prefix)"); return 1
        }
        print("\(s.title)\n  \(s.displayCwd)  \(s.id)\n  \(s.resumeCommand() ?? "(no resume command)")")
        guard s.canResume, let cwd = s.cwd else { print("not resumable: \(s.whyNotResumable ?? "no folder")"); return 1 }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: ResumeRequest.appID).isEmpty else {
            print("Claws for Concern is not running"); return 1
        }
        let request = ResumeRequest(sessionId: s.id, folder: cwd, nonce: "cli-" + UUID().uuidString)
        var outcome: Int32?
        var answered = false
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: ResumeReply.note, object: nil, queue: .main) { note in
            guard let r = ResumeReply(userInfo: note.userInfo), r.token == request.token else { return }
            print("\(r.status.rawValue): \(r.message)")
            answered = true
            if r.status != .opening { outcome = r.status == .failed ? 1 : 0 }
        }
        defer { center.removeObserver(observer) }
        center.postNotificationName(ResumeRequest.note, object: nil, userInfo: request.userInfo, deliverImmediately: true)
        // Same patience as the window: 2 s for a first answer, then up to 30 s for a new tab.
        let start = Date()
        while outcome == nil {
            let waited = Date().timeIntervalSince(start)
            if (!answered && waited > 2) || waited > 30 { print(answered ? "no final answer" : "no answer"); return 1 }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return outcome!
    }
}

/// `--snapshot <png> [--query <q>]`: indexes, renders the window offscreen and quits. For checking the
/// UI from a script: it never shows a window or takes focus, and needs no screen recording permission.
enum Snapshot {
    @MainActor
    static func run(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else {
            print("usage: ClawsSearch --snapshot <out.png> [--query <q>]"); return 2
        }
        let path = args[i + 1]
        let query = args.firstIndex(of: "--query").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        let model = AppModel()
        while model.indexing { wait(0.2) }
        model.query = query
        wait(2)     // the search, then the row previews and the detail pane

        let size = NSSize(width: 1180, height: 760)
        let host = NSHostingView(rootView: ContentView().environmentObject(model).frame(width: size.width, height: size.height))
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        wait(1)
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return 1 }
        print("wrote \(path)")
        return 0
    }
}
