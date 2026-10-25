import AppKit
import CoreServices

/// Talks to Ghostty (1.3+) over AppleScript: which terminal is focused, every terminal's folder
/// and title, and focusing one. Needs the Automation permission ("Claws for Concern wants to
/// control Ghostty"); without it the app still works but cannot tell which tab you are looking at.
///
/// Every Apple Event goes through one background thread. Asking for the permission blocks until
/// you answer the system prompt, and even the no-prompt check waits while that prompt is up:
/// on the main thread that froze the whole app (seen 2026-10-25), so nothing here runs there.
final class Ghostty {
    static let bundleID = "com.mitchellh.ghostty"
    static let shared = Ghostty()

    struct Terminal: Equatable {
        let id: String
        let cwd: String
        let name: String
        /// Tab title without Claude Code's status glyph ("✳ Fix login" -> "Fix login").
        var title: String { Ghostty.stripGlyph(name) }
    }

    enum Permission { case granted, denied, undetermined, notRunning }

    /// Main-thread state, refreshed in the background.
    private(set) var permission: Permission = .undetermined
    /// The terminal you are in, as of `focusedAt`; nil when Ghostty is not frontmost.
    private(set) var focused: Terminal?
    private(set) var focusedAt = Date.distantPast
    var onFocusChange: ((Terminal?) -> Void)?

    private let worker = ScriptThread()
    private var scripts: [String: NSAppleScript] = [:]   // worker thread only
    private var pollTimer: Timer?
    private var pollInFlight = false

    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Ghostty.bundleID).isEmpty }
    var isFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Ghostty.bundleID }

    static func stripGlyph(_ s: String) -> String {
        var t = Substring(s)
        while let c = t.first, !(c.isLetter || c.isNumber || c == "/" || c == "~" || c == "." || c == "(" || c == "[") {
            t = t.dropFirst()
        }
        return String(t).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Lifecycle

    /// Polls the focused tab once a second while Ghostty is frontmost; re-checks the permission
    /// every 15 s.
    func start() {
        refreshPermission()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        pollTimer?.tolerance = 0.15
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refreshPermission() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard isFrontmost else {
            if focused != nil { focused = nil; focusedAt = Date(); onFocusChange?(nil) }
            return
        }
        guard permission == .granted, !pollInFlight else { return }
        pollInFlight = true
        worker.run { [weak self] in
            let t = self?.focusedTerminalNow()
            DispatchQueue.main.async {
                guard let self else { return }
                self.pollInFlight = false
                self.focusedAt = Date()
                if t != self.focused { self.focused = t; self.onFocusChange?(t) }
            }
        }
    }

    /// The focused terminal if the snapshot is fresh enough to trust.
    func focusedTerminal(maxAge: TimeInterval = 2.5) -> Terminal? {
        guard isFrontmost, Date().timeIntervalSince(focusedAt) <= maxAge else { return nil }
        return focused
    }

    // MARK: Permission

    func refreshPermission(then: ((Permission) -> Void)? = nil) {
        worker.run {
            let p = Ghostty.checkPermission(ask: false)
            DispatchQueue.main.async { self.permission = p; then?(p) }
        }
    }

    /// Shows the system consent prompt if it has not been answered yet.
    func requestPermission(then: ((Permission) -> Void)? = nil) {
        worker.run {
            let p = Ghostty.checkPermission(ask: true)
            DispatchQueue.main.async { self.permission = p; then?(p); self.poll() }
        }
    }

    private static func checkPermission(ask: Bool) -> Permission {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return .notRunning }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .notRunning
        default: return .undetermined  // errAEEventWouldRequireUserConsent
        }
    }

    // MARK: Requests (answers arrive on the main thread)

    func allTerminals(_ done: @escaping ([Terminal]) -> Void) {
        guard permission == .granted, isRunning else { done([]); return }
        worker.run {
            let list = self.allTerminalsNow()
            DispatchQueue.main.async { done(list) }
        }
    }

    /// Brings the terminal's window to the front and selects its tab.
    func focus(terminalID: String, _ done: @escaping (Bool) -> Void) {
        guard permission == .granted, isRunning else { done(false); return }
        let safe = terminalID.filter { $0.isHexDigit || $0 == "-" }
        worker.run {
            let src = """
            with timeout of 3 seconds
              tell application id "\(Ghostty.bundleID)"
                focus (terminal id "\(safe)")
                activate
              end tell
            end timeout
            """
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            DispatchQueue.main.async { done(err == nil) }
        }
    }

    func activate() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Ghostty.bundleID).first?.activate()
    }

    // MARK: Worker-thread scripts

    private func execute(_ key: String, _ source: String) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let s = scripts[key] { script = s } else {
            guard let s = NSAppleScript(source: source) else { return nil }
            scripts[key] = s
            script = s
        }
        var err: NSDictionary?
        let r = script.executeAndReturnError(&err)
        if let err, (err[NSAppleScript.errorNumber] as? Int) == -1743 {
            DispatchQueue.main.async { self.permission = .denied }
        }
        return err == nil ? r : nil
    }

    private func focusedTerminalNow() -> Terminal? {
        let src = """
        set sep to tab
        with timeout of 2 seconds
          tell application id "\(Ghostty.bundleID)"
            if (count of windows) is 0 then return ""
            set t to focused terminal of selected tab of front window
            return (id of t) & sep & (working directory of t) & sep & (name of t)
          end tell
        end timeout
        """
        guard let s = execute("focused", src)?.stringValue else { return nil }
        let p = s.components(separatedBy: "\t")
        return p.count >= 3 ? Terminal(id: p[0], cwd: p[1], name: p[2...].joined(separator: "\t")) : nil
    }

    private func allTerminalsNow() -> [Terminal] {
        let src = """
        with timeout of 3 seconds
          tell application id "\(Ghostty.bundleID)" to get {id, working directory, name} of every terminal
        end timeout
        """
        guard let d = execute("all", src), d.numberOfItems == 3,
              let ids = d.atIndex(1), let cwds = d.atIndex(2), let names = d.atIndex(3) else { return [] }
        let n = ids.numberOfItems
        guard n > 0, cwds.numberOfItems == n, names.numberOfItems == n else { return [] }
        return (1...n).compactMap { i in
            guard let id = ids.atIndex(i)?.stringValue else { return nil }
            return Terminal(id: id, cwd: cwds.atIndex(i)?.stringValue ?? "", name: names.atIndex(i)?.stringValue ?? "")
        }
    }
}

/// A single long-lived thread that runs closures in order. NSAppleScript is not thread-safe,
/// so every script runs on this one thread, never on the main thread.
final class ScriptThread {
    private var jobs: [() -> Void] = []
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)

    init() {
        let t = Thread { [unowned self] in
            while true {
                self.ready.wait()
                self.lock.lock()
                let job = self.jobs.isEmpty ? nil : self.jobs.removeFirst()
                self.lock.unlock()
                autoreleasepool { job?() }
            }
        }
        t.name = "claws.applescript"
        t.qualityOfService = .userInitiated
        t.start()
    }

    func run(_ job: @escaping () -> Void) {
        lock.lock(); jobs.append(job); lock.unlock()
        ready.signal()
    }
}

/// How long since your last keystroke or mouse movement anywhere.
enum Presence {
    static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}

/// For sessions Ghostty cannot focus (other terminals, IDEs, unmatched tabs): bring forward the
/// app that hosts the session, found by walking up from its Claude process to a GUI app.
enum TerminalApps {
    static func activate(_ s: SessionState) {
        var pid = s.claudePid ?? 0
        for _ in 0..<15 where pid > 1 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                app.activate()
                return
            }
            guard let e = ProcInfo.info(pid) else { break }
            pid = e.ppid
        }
        if s.termProgram == nil || s.termProgram == "ghostty" { Ghostty.shared.activate() }
    }
}
