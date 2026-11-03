import Darwin
import Foundation

/// Which Claude Code sessions are running now, for the Usage window's "Near the context limit". Claws
/// for Concern's hook writes one `<session id>.json` per live session in its support folder; this
/// reads those files and nothing else there, and never writes (the helper does not compile
/// `Sources/Shared`, so the few fields it needs are decoded here).
///
/// Running means what Claws' resume path means (`SearchHelper.isRunning`): not ended, and its Claude
/// process alive (the same PID with the same start time); a file with no process on record counts only
/// if it changed in the last 5 minutes (such a file can otherwise linger for 48 h).
enum LiveSessions {
    struct Entry: Decodable, Equatable {
        var sessionId: String
        var updatedTs: Double?
        var claudePid: Int32?
        var claudeStart: Double?
        var endedTs: Double?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id", updatedTs = "updated_ts", claudePid = "claude_pid"
            case claudeStart = "claude_start", endedTs = "ended_ts"
        }
    }

    /// Claws' sessions folder: `CLAWS_HOME/sessions` when set (as Claws itself reads it), else in
    /// Application Support. Under `--demo`, the same layout inside the demo's own home.
    static var folder: URL {
        if !Demo.active, let o = ProcessInfo.processInfo.environment["CLAWS_HOME"], !o.isEmpty {
            return URL(fileURLWithPath: o, isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
        }
        return URL(fileURLWithPath: Paths.home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Claws for Concern/sessions", isDirectory: true)
    }

    static func isRunning(_ e: Entry, now: Double, alive: (Int32, Double?) -> Bool) -> Bool {
        guard e.endedTs == nil else { return false }
        if let pid = e.claudePid { return alive(pid, e.claudeStart) }
        return now - (e.updatedTs ?? 0) < 300
    }

    /// IDs of the running sessions. Reads only `*.json` directly in the folder; a missing folder is none.
    static func running(in folder: URL = folder, now: Double = Date().timeIntervalSince1970,
                        alive: (Int32, Double?) -> Bool = Proc.isAlive) -> Set<String> {
        if Demo.active { DemoFiles.write(into: folder) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var out = Set<String>()
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(name).path),
                  let e = try? JSONDecoder().decode(Entry.self, from: data), ResumeRequest.isSessionID(e.sessionId),
                  isRunning(e, now: now, alive: alive) else { continue }
            out.insert(e.sessionId)
        }
        return out
    }

    /// The liveness check Claws uses (`ProcInfo.isAlive`), with sysctl.
    enum Proc {
        static func start(_ pid: Int32) -> Double? {
            var kp = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
            let tv = kp.kp_proc.p_starttime
            return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
        }

        static func isAlive(_ pid: Int32, _ start: Double?) -> Bool {
            guard pid > 0, let s = Proc.start(pid) else { return false }
            if let start { return abs(s - start) < 1 }
            return true
        }
    }

    /// `--demo`: the hook's files for three made-up sessions, in the demo's own home. Two run as this
    /// process (so the liveness check passes for real), one ended.
    enum DemoFiles {
        static let running = ["b1f7e3a9-4c62-4e8d-95b0-6a3d8c2f1e74", "7c1e4b2a-93d5-4f0e-8a6b-2d9f1c3e5a71"]
        static let ended = "2b8f6d14-0a7e-4c39-b5d2-91e3f07a6c48"

        static func write(into folder: URL) {
            guard Demo.active, folder.path.hasPrefix(Paths.home + "/"),
                  !FileManager.default.fileExists(atPath: folder.appendingPathComponent(ended + ".json").path) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let pid = getpid(), start = Proc.start(pid) ?? 0, now = Date().timeIntervalSince1970
            func file(_ id: String, ended: Bool) {
                var o: [String: Any] = ["session_id": id, "cwd": Paths.home, "root_cwd": Paths.home, "status": "working",
                                        "updated_ts": now - 60, "claude_pid": Int(pid), "claude_start": start]
                if ended { o["ended_ts"] = now - 3600; o["end_reason"] = "other" }
                if let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) {
                    FileManager.default.createFile(atPath: folder.appendingPathComponent(id + ".json").path, contents: data)
                }
            }
            running.forEach { file($0, ended: false) }
            file(ended, ended: true)
        }
    }
}
