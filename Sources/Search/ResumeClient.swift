import AppKit

/// The helper's resume requests still waiting on Claws for Concern, by token: what each reply and
/// each timeout means for the user. Pure, for the self-test.
struct PendingResumes {
    struct Entry { let command: String; let sent: Date; var answered: Bool }
    enum Outcome: Equatable {
        case show(String)
        /// Put the command on the clipboard and say why.
        case copy(command: String, message: String)
    }
    /// Claws answers at once; silence this long means it never got the request.
    static let firstAnswer = 2.0
    /// A new tab can wait on the terminal's launch or a permission prompt; Claws gives up at 30 s too.
    static let finalAnswer = ResumeRequest.maxAge

    private(set) var entries: [String: Entry] = [:]
    var isEmpty: Bool { entries.isEmpty }

    mutating func add(token: String, command: String, at now: Date) {
        entries[token] = Entry(command: command, sent: now, answered: false)
    }

    /// nil for a reply to a request that is not ours (or no longer waiting).
    mutating func reply(_ r: ResumeReply) -> Outcome? {
        guard let e = entries[r.token] else { return nil }
        switch r.status {
        case .opening:
            entries[r.token]?.answered = true
            return .show(r.message)
        case .focused, .opened:
            entries[r.token] = nil
            return .show(r.message)
        case .failed:
            entries[r.token] = nil
            return .copy(command: e.command, message: "\(r.message) Command copied.")
        }
    }

    /// Gives up on requests that waited too long (`all`: every one, when quitting).
    mutating func expire(at now: Date, all: Bool = false) -> [Outcome] {
        var out: [Outcome] = []
        for (token, e) in entries.sorted(by: { $0.value.sent < $1.value.sent }) {
            let waited = now.timeIntervalSince(e.sent)
            guard all || (!e.answered && waited >= Self.firstAnswer) || waited >= Self.finalAnswer else { continue }
            entries[token] = nil
            let why = e.answered ? "No word from Claws for Concern on the new tab." : "Claws for Concern did not answer."
            out.append(.copy(command: e.command, message: "\(why) Command copied: \(e.command)"))
        }
        return out
    }
}

/// Sends resume requests to Claws for Concern and acts on its answers. One per process, so quitting
/// can wait for an answer still due (`settle`).
@MainActor
final class ResumeClient {
    static let shared = ResumeClient()
    /// Shows a line in the window's status bar.
    var show: (String) -> Void = { _ in }
    private var pending = PendingResumes()
    private var observer: NSObjectProtocol?
    private var timer: Timer?

    var hasPending: Bool { !pending.isEmpty }

    /// Claws switches to the session's tab if it is still running, else opens a terminal tab in its
    /// folder and types the resume command. When it cannot, the command goes on the clipboard.
    func resume(_ s: Session) {
        guard s.canResume, let cwd = s.cwd, let command = s.resumeCommand() else { return }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: ResumeRequest.appID).isEmpty else {
            copy(command, "Claws for Concern is not running. Command copied: \(command)")
            return
        }
        guard let nonce = ResumeRequest.launchNonce() else {
            copy(command, "Open Search from the Claws for Concern menu to resume from here. Command copied: \(command)")
            return
        }
        listen()
        let request = ResumeRequest(sessionId: s.id, folder: cwd, nonce: nonce)
        pending.add(token: request.token, command: command, at: Date())
        DistributedNotificationCenter.default().postNotificationName(ResumeRequest.note, object: nil,
                                                                     userInfo: request.userInfo, deliverImmediately: true)
        tick()
    }

    /// Quitting: waits up to `seconds` for answers still due, puts the rest on the clipboard, then `done`.
    func settle(within seconds: Double, then done: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(seconds)
        let t = Timer(timeInterval: 0.1, repeats: true) { t in
            MainActor.assumeIsolated {
                let client = ResumeClient.shared
                guard client.pending.isEmpty || Date() >= deadline else { return }
                client.apply(client.pending.expire(at: Date(), all: true))
                t.invalidate()
                done()
            }
        }
        // A .terminateLater runs the loop in the modal panel mode, which the default mode is not.
        RunLoop.main.add(t, forMode: .common)
    }

    private func listen() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: ResumeReply.note, object: nil, queue: .main) { note in
            guard let reply = ResumeReply(userInfo: note.userInfo) else { return }
            MainActor.assumeIsolated {
                let client = ResumeClient.shared
                if let outcome = client.pending.reply(reply) { client.apply([outcome]) }
            }
        }
    }

    /// Checks the timeouts four times a second while anything waits.
    private func tick() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { t in
            MainActor.assumeIsolated {
                let client = ResumeClient.shared
                client.apply(client.pending.expire(at: Date()))
                if client.pending.isEmpty { t.invalidate(); client.timer = nil }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func apply(_ outcomes: [PendingResumes.Outcome]) {
        for o in outcomes {
            switch o {
            case .show(let message): show(message)
            case .copy(let command, let message): copy(command, message)
            }
        }
    }

    private func copy(_ text: String, _ message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(message)
    }
}
