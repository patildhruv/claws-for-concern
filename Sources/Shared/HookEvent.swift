import Foundation

/// Pure state transitions for one hook event. The hook binary does the I/O around this;
/// the self-test drives it directly.
enum HookEvent {
    enum Outcome: Equatable { case write, delete, ignore }

    /// Background task types that will wake the session up again on their own.
    static let wakingTaskTypes: Set<String> = ["subagent", "workflow", "teammate", "cloud session"]

    /// `pid`/`pidStart`: the Claude process that ran this hook. `processCwd`: its working directory.
    /// `isAlive` is injectable for the self-test.
    static func apply(_ input: [String: Any], to state: inout SessionState?, now: Double,
                      pid: Int32? = nil, pidStart: Double? = nil, processCwd: String? = nil, termProgram: String? = nil,
                      isAlive: (Int32, Double?) -> Bool = ProcInfo.isAlive) -> Outcome {
        guard let event = input["hook_event_name"] as? String,
              let sid = input["session_id"] as? String, !sid.isEmpty else { return .ignore }
        let cwd = (input["cwd"] as? String) ?? state?.cwd ?? ""

        // A session belongs to the Claude process that started it. A `claude` run from inside a
        // session inherits CLAUDE_CODE_SESSION_ID, so its events arrive under the same session ID:
        // while the owner lives, they must not reset, finish or end the owner's session.
        var takeover = false
        if let owner = state?.claudePid, let pid, owner != pid {
            if isAlive(owner, state?.claudeStart) { return .ignore }
            takeover = true  // the old process is gone: a resume in a new process
        }

        if event == "SessionEnd" { return state == nil ? .ignore : .delete }

        let root = processCwd ?? cwd
        var s = state ?? SessionState(sessionId: sid, cwd: root)
        // Async hooks can finish out of order; never let an older event overwrite a newer one.
        if state != nil, now < s.updatedTs { return .ignore }
        if takeover { s.rootCwd = root }
        let before = s

        func set(_ status: SessionStatus) {
            if s.status != status { s.statusTs = now }
            s.status = status
            if status != .blocked { s.blockedKind = nil }
        }

        switch event {
        case "SessionStart":
            let source = input["source"] as? String ?? "startup"
            if source != "compact" {
                set(.idle)
                s.rootCwd = root
                s.detail = nil
            }
        case "UserPromptSubmit":
            set(.working)
            s.promptTs = now
            s.detail = nil
        case "PreToolUse":
            let tool = input["tool_name"] as? String ?? ""
            let toolInput = input["tool_input"] as? [String: Any] ?? [:]
            if tool == "AskUserQuestion" {
                set(.blocked); s.blockedKind = "question"; s.detail = describeQuestions(toolInput)
            } else if tool == "ExitPlanMode" {
                set(.blocked); s.blockedKind = "plan"
                s.detail = clip((toolInput["plan"] as? String) ?? "Claude has a plan ready for your approval", 4000)
            } else if s.status == .blocked {
                set(.working)
            }
        case "PermissionRequest":
            set(.blocked); s.blockedKind = "permission"
            s.detail = describeTool(input["tool_name"] as? String ?? "a tool",
                                    input["tool_input"] as? [String: Any] ?? [:])
        case "Notification":
            let type = input["notification_type"] as? String ?? ""
            let message = (input["message"] as? String) ?? (input["title"] as? String) ?? ""
            switch type {
            case "permission_prompt":
                // PermissionRequest usually got here first with a better description.
                if s.status != .blocked { set(.blocked); s.blockedKind = "permission"; s.detail = message }
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                set(.blocked); s.blockedKind = "input"; s.detail = message
            default:
                return .ignore
            }
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            // You answered (or the call went ahead some other way): Claude is working again.
            guard s.status == .blocked else { return .ignore }
            set(.working)
        case "Stop":
            let tasks = input["background_tasks"] as? [[String: Any]] ?? []
            let waking = tasks.contains { wakingTaskTypes.contains(($0["type"] as? String ?? "").lowercased()) }
            set(waking ? .background : .finished)
            s.lastMessage = clip(input["last_assistant_message"] as? String ?? "", 12000)
            s.detail = nil
        case "StopFailure":
            set(.failed)
            let err = input["error"] as? String ?? "unknown"
            let text = (input["last_assistant_message"] as? String) ?? (input["error_details"] as? String) ?? ""
            s.detail = clip(text.isEmpty ? err.replacingOccurrences(of: "_", with: " ") : text, 400)
        default:
            return .ignore
        }

        s.cwd = cwd
        if let t = input["transcript_path"] as? String, !t.isEmpty { s.transcriptPath = t }
        if let m = input["permission_mode"] as? String { s.permissionMode = m }
        if let t = input["session_title"] as? String, !t.isEmpty { s.title = t }
        if let pid, s.claudePid != pid { s.claudePid = pid; s.claudeStart = pidStart }
        if let termProgram { s.termProgram = termProgram }

        // PostToolUse fires on every tool call; only touch the file when something changed.
        if state != nil, s == before { return .ignore }
        s.updatedTs = now
        state = s
        return .write
    }

    static func describeQuestions(_ input: [String: Any]) -> String {
        let qs = input["questions"] as? [[String: Any]] ?? []
        let parts = qs.map { q -> String in
            let text = q["question"] as? String ?? ""
            let opts = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            return opts.isEmpty ? text : "\(text) [\(opts.joined(separator: " / "))]"
        }
        return clip(parts.isEmpty ? "Claude has a question for you" : parts.joined(separator: "  "), 2000)
    }

    static func describeTool(_ tool: String, _ input: [String: Any]) -> String {
        let keys = ["command", "file_path", "url", "pattern", "path", "query", "description"]
        for k in keys {
            if let v = input[k] as? String, !v.isEmpty {
                let firstLine = v.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? v
                return clip("\(tool): \(firstLine)", 400)
            }
        }
        return "\(tool)"
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }
}
