import Foundation

/// Adds and removes Claws for Concern's hooks in ~/.claude/settings.json. Every entry it owns runs
/// the bundled `claws-for-concern-hook`, which is how it recognises its own entries; everything else
/// in the file is left byte-for-byte as it was.
enum HooksInstaller {
    static let marker = "claws-for-concern-hook"

    /// (event, matcher, async). SessionEnd stays synchronous: Claude Code may tear down async
    /// hooks while the session exits, and the hook takes ~10 ms anyway.
    static let events: [(event: String, matcher: String?, async: Bool)] = [
        ("SessionStart", nil, true),
        ("UserPromptSubmit", nil, true),
        ("PreToolUse", "AskUserQuestion|ExitPlanMode", true),
        ("PermissionRequest", nil, true),
        ("Notification", "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input", true),
        ("PostToolUse", nil, true),
        ("PostToolUseFailure", nil, true),
        ("Stop", nil, true),
        ("StopFailure", nil, true),
        ("SessionEnd", nil, false),
    ]

    static var settingsURL: URL {
        if let o = ProcessInfo.processInfo.environment["CLAWS_SETTINGS"], !o.isEmpty {
            return URL(fileURLWithPath: o)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// The hook binary inside whichever copy of the app is running.
    static var hookPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(marker)").path
    }

    static func command(for path: String) -> String {
        // Hook commands run through a shell; the app path contains a space.
        "\"\(path.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    enum Status: Equatable { case installed, outdated(String), absent }

    static func status(settings url: URL = settingsURL, hookPath: String = hookPath) -> Status {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let root = try? JSONValue.parse(text) else { return .absent }
        let hooks = root["hooks"]
        var found = 0, stale = 0
        for spec in events {
            let groups = hooks?[spec.event]?.arrayValue ?? []
            let ours = groups.flatMap { ($0["hooks"]?.arrayValue ?? []) }
                .compactMap { $0["command"]?.stringValue }.filter { $0.contains(marker) }
            if ours.isEmpty { continue }
            found += 1
            if !ours.contains(command(for: hookPath)) { stale += 1 }
        }
        if found == 0 { return .absent }
        if found < events.count { return .outdated("\(events.count - found) of \(events.count) hooks missing") }
        if stale > 0 { return .outdated("hooks point at another copy of the app") }
        return .installed
    }

    /// Returns the backup path when the file changed.
    @discardableResult
    static func install(settings url: URL = settingsURL, hookPath: String = hookPath) throws -> URL? {
        try rewrite(url) { root in
            var hooks = stripped(root["hooks"] ?? .object([]))
            for spec in events {
                var handler: [(String, JSONValue)] = [("type", .string("command")),
                                                      ("command", .string(command(for: hookPath)))]
                if spec.async { handler.append(("async", .bool(true))) } else { handler.append(("timeout", .number("5"))) }
                var group: [(String, JSONValue)] = []
                if let m = spec.matcher { group.append(("matcher", .string(m))) }
                group.append(("hooks", .array([.object(handler)])))
                var list = hooks[spec.event]?.arrayValue ?? []
                list.append(.object(group))
                hooks[spec.event] = .array(list)
            }
            root["hooks"] = hooks
        }
    }

    @discardableResult
    static func remove(settings url: URL = settingsURL) throws -> URL? {
        try rewrite(url) { root in
            guard let h = root["hooks"] else { return }
            let hooks = stripped(h)
            if case let .object(pairs) = hooks, pairs.isEmpty { root["hooks"] = nil } else { root["hooks"] = hooks }
        }
    }

    /// Drop every handler that runs our binary, then any group or event left empty.
    static func stripped(_ hooks: JSONValue) -> JSONValue {
        guard case let .object(events) = hooks else { return hooks }
        var out: [(String, JSONValue)] = []
        for (event, value) in events {
            guard case let .array(groups) = value else { out.append((event, value)); continue }
            var kept: [JSONValue] = []
            for g in groups {
                guard case let .array(handlers) = g["hooks"] ?? .null else { kept.append(g); continue }
                let left = handlers.filter { !($0["command"]?.stringValue ?? "").contains(marker) }
                if left.count == handlers.count { kept.append(g); continue }
                if left.isEmpty { continue }
                var g2 = g
                g2["hooks"] = .array(left)
                kept.append(g2)
            }
            if !kept.isEmpty { out.append((event, .array(kept))) }
        }
        return .object(out)
    }

    private static func rewrite(_ url: URL, _ edit: (inout JSONValue) -> Void) throws -> URL? {
        let fm = FileManager.default
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var root = original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? JSONValue.object([]) : try JSONValue.parse(original)
        guard case .object = root else { throw JSONValue.ParseError(offset: 0, reason: "settings.json is not an object") }
        edit(&root)
        let trailingNewline = original.isEmpty || original.hasSuffix("\n")
        let text = root.serialized() + (trailingNewline ? "\n" : "")
        guard text != original else { return nil }
        _ = try JSONValue.parse(text)  // never write something we cannot read back

        var backup: URL?
        if fm.fileExists(atPath: url.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let base = "\(url.lastPathComponent).bak-claws-for-concern-\(stamp)"
            var b = url.deletingLastPathComponent().appendingPathComponent(base)
            var n = 2
            while fm.fileExists(atPath: b.path) {  // two edits in the same second
                b = url.deletingLastPathComponent().appendingPathComponent("\(base)-\(n)")
                n += 1
            }
            try fm.copyItem(at: url, to: b)
            backup = b
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return backup
    }
}
