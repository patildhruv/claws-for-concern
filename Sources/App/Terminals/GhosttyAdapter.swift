import AppKit

/// Ghostty 1.3+ over AppleScript. Ghostty does not tell a shell which terminal it is in, so this
/// adapter learns panes: the tab you type a prompt into, then folder and title matching
/// (Claude Code titles its tab "<status glyph> <session title>").
final class GhosttyAdapter: TerminalAdapter {
    let id = "ghostty"
    let name = "Ghostty"
    static let bundleID = "com.mitchellh.ghostty"
    let scriptedBundleID: String? = GhosttyAdapter.bundleID
    var learnsPanes: Bool { true }
    private var lastFocused: PaneInfo?

    func claims(_ s: SessionState) -> Bool {
        (s.env("TERM_PROGRAM") ?? s.termProgram) == "ghostty" || s.env("GHOSTTY_RESOURCES_DIR") != nil
    }

    func lookedAt(front: FrontApp) -> Set<String> {
        lastFocused = front.bundleID == scriptedBundleID ? focusedTerminal() : nil
        return lastFocused.map { [$0.id] } ?? []
    }

    /// The poll calls `lookedAt` first; reuse its answer instead of asking Ghostty twice.
    func focusedPane(front: FrontApp) -> PaneInfo? {
        front.bundleID == scriptedBundleID ? lastFocused : nil
    }

    func panes() -> [PaneInfo] {
        let src = """
        with timeout of 3 seconds
          tell application id "com.mitchellh.ghostty" to get {id, working directory, name} of every terminal
        end timeout
        """
        guard let d = Script.run(src, cacheKey: "ghostty.all"), d.numberOfItems == 3,
              let ids = d.atIndex(1), let cwds = d.atIndex(2), let names = d.atIndex(3) else { return [] }
        let n = ids.numberOfItems
        guard n > 0, cwds.numberOfItems == n, names.numberOfItems == n else { return [] }
        return (1...n).compactMap { i in
            guard let id = ids.atIndex(i)?.stringValue else { return nil }
            return PaneInfo(id: id, cwd: cwds.atIndex(i)?.stringValue ?? "", name: names.atIndex(i)?.stringValue ?? "")
        }
    }

    func focus(paneID: String, session: SessionState) -> Bool {
        let safe = paneID.filter { $0.isHexDigit || $0 == "-" }
        return Script.run("""
        with timeout of 3 seconds
          tell application id "com.mitchellh.ghostty"
            focus (terminal id "\(safe)")
            activate
          end tell
        end timeout
        """) != nil
    }

    func health() -> AdapterHealth {
        Automation.healthFor("com.mitchellh.ghostty", appName: "Ghostty",
                             ready: "Finds each session's tab, clears its Clawd when you look, and jumps there on click.")
    }

    private func focusedTerminal() -> PaneInfo? {
        // `tab` is a Ghostty class, so the tab character is bound outside the tell block.
        let src = """
        set sep to tab
        with timeout of 2 seconds
          tell application id "com.mitchellh.ghostty"
            if (count of windows) is 0 then return ""
            set t to focused terminal of selected tab of front window
            return (id of t) & sep & (working directory of t) & sep & (name of t)
          end tell
        end timeout
        """
        guard let s = Script.run(src, cacheKey: "ghostty.focused")?.stringValue else { return nil }
        let p = s.components(separatedBy: "\t")
        return p.count >= 3 ? PaneInfo(id: p[0], cwd: p[1], name: p[2...].joined(separator: "\t")) : nil
    }
}

/// Everything else (VS Code, Warp, Zed, Alacritty…): no pane-level control, but a click still brings
/// forward the app hosting the session, found by walking up from its Claude process.
final class HostAppAdapter: TerminalAdapter {
    let id = "app"
    let name = "Other terminals"

    func claims(_ s: SessionState) -> Bool { true }
    func lookedAt(front: FrontApp) -> Set<String> { [] }

    func focus(paneID: String, session: SessionState) -> Bool {
        if let pid = session.claudePid, let app = HostApp.of(pid: pid) {
            DispatchQueue.main.async { app.activate() }
            return true
        }
        // A daemonised multiplexer has no GUI ancestor: fall back to the terminal it was started from.
        let bundle: String? = ["ghostty": "com.mitchellh.ghostty", "Apple_Terminal": "com.apple.Terminal",
                               "iTerm.app": "com.googlecode.iterm2", "WarpTerminal": "dev.warp.Warp-Stable",
                               "vscode": "com.microsoft.VSCode"][session.env("TERM_PROGRAM") ?? session.termProgram ?? ""]
        if let bundle, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            DispatchQueue.main.async { app.activate() }
            return true
        }
        return false
    }

    func health() -> AdapterHealth {
        AdapterHealth(level: .ready, detail: "Clicking brings the terminal or editor forward. A Clawd clears when you prompt that session or dismiss it.")
    }
}
