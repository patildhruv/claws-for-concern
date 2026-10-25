import AppKit

/// `ClawsForConcern --terminals`: what the adapters make of every live session, for checking an
/// adapter you are writing. Runs the adapters directly, in this process.
enum Diagnostics {
    /// `--open-session <id prefix>`: runs the click path (adapter focus, then the app fallback).
    static func open(_ prefix: String) -> Int32 {
        _ = NSApplication.shared
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil)) ?? []
        guard let s = files.filter({ $0.pathExtension == "json" }).compactMap(SessionState.load)
            .first(where: { $0.sessionId.hasPrefix(prefix) }) else { print("no session \(prefix)"); return 1 }
        let a = Terminals.shared.adapter(for: s)
        guard let pane = a.paneID(for: s) else { print("\(a.name) has no recorded pane (learning adapters need the app)"); return 1 }
        let ok = a.focus(paneID: pane, session: s)
        print("\(a.name): focus \(pane) -> \(ok ? "ok" : "failed")")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))  // let the activate() land
        return ok ? 0 : 1
    }

    static func terminals() -> Int32 {
        _ = NSApplication.shared
        let t = Terminals.shared
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil)) ?? []
        let sessions = files.filter { $0.pathExtension == "json" }.compactMap(SessionState.load)
        let front = Terminals.front
        print("In front: \(front.bundleID ?? "nothing")\n")
        if sessions.isEmpty { print("No live Claude Code sessions.") }
        var looked: [String: Set<String>] = [:]
        // Panes first: multiplexer adapters learn which servers to ask from them (as in the app).
        let panes = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, t.adapter(for: $0).paneID(for: $0)) })
        for s in sessions.sorted(by: { $0.updatedTs > $1.updatedTs }) {
            let a = t.adapter(for: s)
            for b in [a.scriptedBundleID].compactMap({ $0 }) { Automation.refresh(b) }
            if looked[a.id] == nil {
                looked[a.id] = (a.scriptedBundleID.map { Automation.cached($0) == .granted } ?? true) ? a.lookedAt(front: front) : []
            }
            let pane = (panes[s.sessionId] ?? nil) ?? (a.learnsPanes ? "(learned by the app)" : "-")
            let seen = looked[a.id]?.contains(pane) == true ? "looking at it" : ""
            print("\(s.sessionId.prefix(8))  \(s.status.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(a.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(pane)  \(seen)")
        }
        print("\nIntegrations:")
        for a in t.adapters + [t.fallback] {
            if let b = a.scriptedBundleID { Automation.refresh(b) }
            let h = a.health()
            let mark = ["ready": "✓", "limited": "!", "unavailable": "-"]["\(h.level)"] ?? "?"
            print("  \(mark) \(a.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(h.detail)")
        }
        return 0
    }
}
