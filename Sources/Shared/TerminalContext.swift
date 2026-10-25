import Foundation

/// What the hook records about where a session runs, for the terminal adapters to read later.
/// The hook sees Claude Code's environment, which carries each terminal's identifiers.
///
/// An explicit allow-list, never prefixes: cmux, for one, puts a socket capability token in every
/// shell's environment (CMUX_SOCKET_CAPABILITY), and nothing like that may reach a file on disk.
/// Adding a terminal? Add its identifier variables here (see docs/adapters.md).
enum TerminalContext {
    static let keys: Set<String> = [
        // Generic
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "LC_TERMINAL", "__CFBundleIdentifier",
        // Ghostty
        "GHOSTTY_RESOURCES_DIR", "GHOSTTY_SURFACE_ID",
        // iTerm2
        "ITERM_SESSION_ID",
        // tmux
        "TMUX", "TMUX_PANE",
        // cmux
        "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_PANEL_ID", "CMUX_TAB_ID", "CMUX_SOCKET_PATH", "CMUX_BUNDLE_ID",
        // herdr
        "HERDR_ENV", "HERDR_SESSION", "HERDR_WORKSPACE_ID", "HERDR_TAB_ID", "HERDR_PANE_ID", "HERDR_SOCKET_PATH",
        // Others, for future adapters
        "ZELLIJ", "ZELLIJ_SESSION_NAME", "ZELLIJ_PANE_ID", "WEZTERM_PANE", "WEZTERM_UNIX_SOCKET",
        "KITTY_WINDOW_ID", "KITTY_LISTEN_ON", "WT_SESSION",
    ]

    /// A second guard, in case a secret ever lands on the list by mistake.
    static let secretWords = ["PASSWORD", "PASSWD", "TOKEN", "SECRET", "KEY", "COOKIE", "CREDENTIAL", "AUTH", "CAPABILITY"]

    static func capture(_ env: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in env where keys.contains(k) {
            let upper = k.uppercased()
            guard !secretWords.contains(where: { upper.contains($0) }), !v.isEmpty, v.count <= 512 else { continue }
            out[k] = v
        }
        return out
    }
}

extension ProcInfo {
    /// The controlling terminal of `pid` ("/dev/ttys004"), or nil.
    static func tty(_ pid: Int32) -> String? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        let dev = kp.kp_eproc.e_tdev
        guard dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    /// Every process ID on the system (for finding a multiplexer's client processes).
    static func allPIDs() -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { $0.kp_proc.p_pid }
    }
}
