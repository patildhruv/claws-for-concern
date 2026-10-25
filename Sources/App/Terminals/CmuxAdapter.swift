import AppKit

/// cmux (Ghostty-based, by Manaflow): the surface comes from CMUX_SURFACE_ID, driven through the
/// bundled `cmux` CLI. cmux's default socket mode ("cmuxOnly") refuses apps not started inside cmux,
/// so pane-level control needs cmux → Settings → Automation → Socket control set to "Automation".
/// Without it, clicking still brings cmux forward.
final class CmuxAdapter: TerminalAdapter {
    let id = "cmux"
    let name = "cmux"
    static let bundleID = "com.cmuxterm.app"

    func claims(_ s: SessionState) -> Bool { s.env("CMUX_SURFACE_ID") != nil || s.env("CMUX_WORKSPACE_ID") != nil }

    /// "<workspace>|<surface>": focusing a surface needs its workspace.
    func paneID(for s: SessionState) -> String? {
        guard let surface = s.env("CMUX_SURFACE_ID") ?? s.env("CMUX_PANEL_ID") else { return nil }
        return "\(s.env("CMUX_WORKSPACE_ID") ?? "")|\(surface)"
    }

    private var cli: String? {
        Command.find("cmux", extra: ["/Applications/cmux.app/Contents/Resources/bin/cmux",
                                     "\(NSHomeDirectory())/Applications/cmux.app/Contents/Resources/bin/cmux"])
    }

    private func run(_ args: [String]) -> Command.Result? {
        guard let cli else { return nil }
        return Command.run(cli, args)
    }

    func lookedAt(front: FrontApp) -> Set<String> {
        guard front.bundleID == CmuxAdapter.bundleID,
              let obj = Command.json(run(["--json", "--id-format", "uuids", "identify"])) as? [String: Any],
              let f = obj["focused"] as? [String: Any], let surface = f["surface_id"] as? String else { return [] }
        return ["\(f["workspace_id"] as? String ?? "")|\(surface)", "|\(surface)"]
    }

    func focus(paneID: String, session: SessionState) -> Bool {
        let parts = paneID.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return false }
        let (workspace, surface) = (parts[0], parts[1])
        if !workspace.isEmpty { _ = run(["select-workspace", "--workspace", workspace]) }
        var args = ["focus-panel", "--panel", surface]
        if !workspace.isEmpty { args += ["--workspace", workspace] }
        guard let r = run(args), r.status == 0 else { return false }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: CmuxAdapter.bundleID).first {
            DispatchQueue.main.async { app.activate() }
        }
        return true
    }

    func health() -> AdapterHealth {
        guard cli != nil else { return AdapterHealth(level: .unavailable, detail: "cmux is not installed.") }
        let mode = (Command.json(run(["socket-status", "--json"])) as? [String: Any])?["effective_mode"] as? String ?? "unknown"
        switch mode {
        case "automation", "allowAll", "openAccess", "fullOpenAccess", "full":
            return AdapterHealth(level: .ready, detail: "Finds each session's surface, clears its Clawd when you look, and jumps there on click.")
        default:
            // In these modes cmux refuses even "open settings" from outside, so point the way instead.
            let why = mode == "password" ? "cmux's socket wants a password" : "cmux only lets its own terminals use its socket"
            return AdapterHealth(level: .limited,
                                 detail: "\(why), so a click just brings cmux forward. For full support: cmux → Settings (⌘,) → Automation → Socket control → Automation.",
                                 fix: .openApp(bundleID: CmuxAdapter.bundleID, label: "Open cmux"))
        }
    }
}
