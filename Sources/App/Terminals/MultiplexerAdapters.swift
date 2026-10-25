import AppKit

/// tmux: the pane comes from TMUX_PANE, the server from TMUX's socket path. "Looking" means the pane
/// is the active one in a tmux client whose terminal app is in front. Clicking switches that client.
final class TmuxAdapter: TerminalAdapter {
    let id = "tmux"
    let name = "tmux"
    private let lock = NSLock()
    private var sockets = Set<String>()
    private var tmux: String? { Command.find("tmux") }

    func claims(_ s: SessionState) -> Bool { s.env("TMUX") != nil && s.env("TMUX_PANE") != nil }

    /// "<socket>|<pane>": tmux pane IDs (%3) are only unique per server.
    func paneID(for s: SessionState) -> String? {
        guard let t = s.env("TMUX"), let pane = s.env("TMUX_PANE"),
              let socket = t.split(separator: ",").first.map(String.init), !socket.isEmpty else { return nil }
        lock.lock(); sockets.insert(socket); lock.unlock()
        return "\(socket)|\(pane)"
    }

    private struct Client { let pid: Int32; let tty: String; let pane: String; let activity: Double }

    private func clients(_ socket: String) -> [Client] {
        guard let tmux, let r = Command.run(tmux, ["-S", socket, "list-clients", "-F",
                                                    "#{client_pid}\t#{client_tty}\t#{pane_id}\t#{client_activity}"]),
              r.status == 0 else { return [] }
        return r.out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, let pid = Int32(f[0]) else { return nil }
            return Client(pid: pid, tty: f[1], pane: f[2], activity: Double(f[3]) ?? 0)
        }
    }

    func lookedAt(front: FrontApp) -> Set<String> {
        lock.lock(); let all = sockets; lock.unlock()
        var out = Set<String>()
        for socket in all {
            for c in clients(socket) where HostApp.of(pid: c.pid)?.processIdentifier == front.pid {
                out.insert("\(socket)|\(c.pane)")
            }
        }
        return out
    }

    func focus(paneID: String, session: SessionState) -> Bool {
        let parts = paneID.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let tmux else { return false }
        let (socket, pane) = (parts[0], parts[1])
        // The most recently used client shows it; with none attached there is nothing to bring forward.
        guard let client = clients(socket).max(by: { $0.activity < $1.activity }) else { return false }
        _ = Command.run(tmux, ["-S", socket, "switch-client", "-c", client.tty, "-t", pane])
        _ = Command.run(tmux, ["-S", socket, "select-window", "-t", pane])
        _ = Command.run(tmux, ["-S", socket, "select-pane", "-t", pane])
        if let app = HostApp.of(pid: client.pid) { DispatchQueue.main.async { app.activate() } }
        return true
    }

    func health() -> AdapterHealth {
        tmux == nil ? AdapterHealth(level: .unavailable, detail: "tmux is not installed.")
            : AdapterHealth(level: .ready, detail: "Finds each session's pane, clears its Clawd when that pane is active in a tmux window you have in front, and switches to it on click.")
    }
}

/// herdr: the pane comes from HERDR_PANE_ID. herdr tracks "seen" itself (an agent is `done` until
/// you view it, then `idle`), so its answer is used directly. Clicking runs `herdr agent focus`.
final class HerdrAdapter: TerminalAdapter {
    let id = "herdr"
    let name = "herdr"
    var tracksSeenItself: Bool { true }
    private let lock = NSLock()
    private var sockets = Set<String>()
    private var herdr: String? { Command.find("herdr") }

    static var defaultSocket: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/herdr/herdr.sock").path
    }

    func claims(_ s: SessionState) -> Bool { s.env("HERDR_PANE_ID") != nil }

    /// "<socket>|<pane>": pane IDs (w1:p2) are only unique per herdr server.
    func paneID(for s: SessionState) -> String? {
        guard let pane = s.env("HERDR_PANE_ID") else { return nil }
        let socket = s.env("HERDR_SOCKET_PATH") ?? HerdrAdapter.defaultSocket
        lock.lock(); sockets.insert(socket); lock.unlock()
        return "\(socket)|\(pane)"
    }

    private func run(_ socket: String, _ args: [String]) -> Command.Result? {
        guard let herdr else { return nil }
        return Command.run(herdr, args, env: ["HERDR_SOCKET_PATH": socket])
    }

    func lookedAt(front: FrontApp) -> Set<String> {
        lock.lock(); let all = sockets; lock.unlock()
        // Without a client attached, herdr counts its own focused pane as seen though nobody is
        // looking: only trust "seen" while a herdr client is running somewhere.
        guard HerdrAdapter.clientRunning() else { return [] }
        var out = Set<String>()
        for socket in all {
            guard let obj = Command.json(run(socket, ["agent", "list"])) as? [String: Any],
                  let agents = (obj["result"] as? [String: Any])?["agents"] as? [[String: Any]] else { continue }
            for a in agents where (a["agent_status"] as? String) == "idle" {
                if let pane = a["pane_id"] as? String { out.insert("\(socket)|\(pane)") }
            }
        }
        return out
    }

    func focus(paneID: String, session: SessionState) -> Bool {
        let parts = paneID.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let r = run(parts[0], ["agent", "focus", parts[1]]), r.status == 0 else { return false }
        // Bring forward the terminal showing herdr.
        if let app = HerdrAdapter.clientHosts().first { DispatchQueue.main.async { app.activate() } }
        return true
    }

    func health() -> AdapterHealth {
        herdr == nil ? AdapterHealth(level: .unavailable, detail: "herdr is not installed.")
            : AdapterHealth(level: .ready, detail: "Uses herdr's own seen state, so a Clawd clears as soon as herdr shows you that agent, and jumps there with herdr agent focus.")
    }

    /// GUI apps hosting a herdr client (the terminal you attached from). herdr does not report its
    /// clients, but a client runs in a terminal and so has a controlling tty; the server has none.
    static func clientHosts() -> [NSRunningApplication] {
        var apps: [NSRunningApplication] = []
        for pid in ProcInfo.allPIDs() where ProcInfo.info(pid)?.name == "herdr" && ProcInfo.tty(pid) != nil {
            if let app = HostApp.of(pid: pid), !apps.contains(app) { apps.append(app) }
        }
        return apps
    }

    static func clientRunning() -> Bool { !clientHosts().isEmpty }
}
