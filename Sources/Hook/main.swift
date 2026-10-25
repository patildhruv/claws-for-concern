import Foundation

// claws-for-concern-hook — the command Claude Code runs for every Claws for Concern hook event.
// Reads the event JSON on stdin, updates sessions/<session id>.json, exits 0. It never prints,
// never blocks Claude, and stays quiet on failure (one line in claws.log at most).

let env = ProcessInfo.processInfo.environment
let input = FileHandle.standardInput.readDataToEndOfFile()

// The app's own recap calls (`claude -p`) set this; they must not report themselves.
if env["CLAWS_INTERNAL"] == "1" { exit(0) }

func log(_ msg: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) hook: \(msg)\n"
    guard let h = try? FileHandle(forWritingTo: Paths.log) else {
        try? line.write(to: Paths.log, atomically: true, encoding: .utf8); return
    }
    defer { try? h.close() }
    if let end = try? h.seekToEnd(), end > 512_000 { try? h.truncate(atOffset: 0) }
    h.write(line.data(using: .utf8)!)
}

guard let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
      let sid = json["session_id"] as? String, !sid.isEmpty,
      // Session IDs are UUIDs; refuse anything that could escape the directory.
      sid.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { exit(0) }

let fm = FileManager.default
try? fm.createDirectory(at: Paths.sessions, withIntermediateDirectories: true)

let lockFD = open(Paths.sessions.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
if lockFD >= 0 { flock(lockFD, LOCK_EX) }
defer { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }

let url = Paths.sessions.appendingPathComponent("\(sid).json")
var state = SessionState.load(url)
let claude = ProcInfo.claudeAncestor(of: getppid())

switch HookEvent.apply(json, to: &state, now: Date().timeIntervalSince1970,
                       pid: claude?.pid, pidStart: claude?.start, termProgram: env["TERM_PROGRAM"]) {
case .write:
    do { try state?.save(to: url) } catch { log("write \(sid): \(error)") }
case .delete:
    try? fm.removeItem(at: url)
case .ignore:
    break
}
exit(0)
