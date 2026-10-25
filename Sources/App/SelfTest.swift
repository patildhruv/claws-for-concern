import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `--selftest`: checks the parts that can go wrong without a GUI. Prints ALL PASS or exits 1.
enum SelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print((ok ? "PASS " : "FAIL ") + name + (ok ? "" : "  — " + detail()))
        if !ok { failures += 1 }
    }

    static func run() -> Int32 {
        hookTransitions()
        orderedJSON()
        installer()
        text()
        art()
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    private static func ev(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var e: [String: Any] = ["hook_event_name": name, "session_id": "t1", "cwd": "/w", "transcript_path": "/t.jsonl"]
        e.merge(extra) { $1 }
        return e
    }

    static func hookTransitions() {
        var s: SessionState?
        var t = 1000.0
        func apply(_ e: [String: Any]) -> HookEvent.Outcome { t += 1; return HookEvent.apply(e, to: &s, now: t) }
        check("start writes idle", apply(ev("SessionStart", ["source": "startup"])) == .write && s?.status == .idle)
        check("prompt -> working", apply(ev("UserPromptSubmit", ["prompt": "hi"])) == .write && s?.status == .working && s?.promptTs == t)
        _ = apply(ev("PreToolUse", ["tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": "Which DB?",
                    "options": [["label": "Postgres"], ["label": "SQLite"]]]]]]))
        check("question -> blocked", s?.status == .blocked && s?.blockedKind == "question" && s?.detail == "Which DB? [Postgres / SQLite]",
              String(describing: s?.detail))
        check("answer -> working", apply(ev("PostToolUse", ["tool_name": "AskUserQuestion"])) == .write && s?.status == .working)
        check("other tool is a no-op", apply(ev("PostToolUse", ["tool_name": "Bash"])) == .ignore)
        _ = apply(ev("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build\necho done"]]))
        check("permission detail", s?.blockedKind == "permission" && s?.detail == "Bash: rm -rf build", String(describing: s?.detail))
        check("duplicate permission notification ignored",
              apply(ev("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission"])) == .ignore)
        check("idle_prompt ignored", apply(ev("Notification", ["notification_type": "idle_prompt"])) == .ignore)
        _ = apply(ev("Stop", ["last_assistant_message": "All done.", "background_tasks": []]))
        check("stop -> finished", s?.status == .finished && s?.lastMessage == "All done." && s?.blockedKind == nil)
        _ = apply(ev("UserPromptSubmit"))
        _ = apply(ev("Stop", ["last_assistant_message": "Waiting on agents", "background_tasks": [["type": "subagent", "status": "running"]]]))
        check("stop with subagents -> background", s?.status == .background)
        _ = apply(ev("Stop", ["last_assistant_message": "dev server up", "background_tasks": [["type": "shell", "status": "running"]]]))
        check("stop with a shell task -> finished", s?.status == .finished)
        _ = apply(ev("StopFailure", ["error": "rate_limit", "last_assistant_message": "API Error: Rate limit reached"]))
        check("failure detail", s?.status == .failed && s?.detail == "API Error: Rate limit reached")
        var stale = s
        check("older event dropped", HookEvent.apply(ev("UserPromptSubmit"), to: &stale, now: 5) == .ignore && stale?.status == .failed)
        check("compact keeps status", apply(ev("SessionStart", ["source": "compact"])) != .write || s?.status == .failed)
        check("session end deletes", apply(ev("SessionEnd", ["reason": "other"])) == .delete)
        var none: SessionState?
        check("missing session id ignored", HookEvent.apply(["hook_event_name": "Stop"], to: &none, now: 1) == .ignore && none == nil)
    }

    static func orderedJSON() {
        let samples = [
            "{}", "[]", "{\n  \"a\": 1,\n  \"b\": [\n    true,\n    null,\n    \"x\\ny\\\"z\"\n  ],\n  \"c\": {}\n}",
            "{\n  \"emoji\": \"✳ crab 🦀\",\n  \"n\": -1.5e3\n}",
        ]
        for s in samples {
            let v = try? JSONValue.parse(s)
            check("json round trip \(s.prefix(12).replacingOccurrences(of: "\n", with: " "))", v?.serialized() == s,
                  v?.serialized() ?? "parse failed")
        }
        check("json \\u escapes", (try? JSONValue.parse("\"\\u00e9\\ud83e\\udd80\""))?.stringValue == "é🦀")
        check("json rejects junk", (try? JSONValue.parse("{\"a\":1}x")) == nil)
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        if let text = try? String(contentsOf: real, encoding: .utf8) {
            let v = try? JSONValue.parse(text)
            check("~/.claude/settings.json round-trips byte for byte",
                  v.map { $0.serialized() + (text.hasSuffix("\n") ? "\n" : "") } == text)
        }
    }

    static func installer() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claws-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        let original = """
        {
          "model": "opus",
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "say done"
                  }
                ]
              }
            ]
          },
          "theme": "dark"
        }

        """
        try? original.write(to: url, atomically: true, encoding: .utf8)
        let hook = "/Applications/Claws for Concern.app/Contents/MacOS/claws-for-concern-hook"
        check("install", (try? HooksInstaller.install(settings: url, hookPath: hook)) != nil)
        check("status installed", HooksInstaller.status(settings: url, hookPath: hook) == .installed)
        let after = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check("other hooks kept", after.contains("say done") && after.contains("\"theme\": \"dark\""))
        check("key order kept", after.range(of: "\"model\"")!.lowerBound < after.range(of: "\"hooks\"")!.lowerBound
              && after.range(of: "\"hooks\"")!.lowerBound < after.range(of: "\"theme\"")!.lowerBound)
        check("reinstall is a no-op", (try? HooksInstaller.install(settings: url, hookPath: hook)) == .some(nil))
        check("moved app reads as outdated", HooksInstaller.status(settings: url, hookPath: "/tmp/x/claws-for-concern-hook") != .installed)
        _ = try? HooksInstaller.remove(settings: url)
        check("remove restores the file exactly", (try? String(contentsOf: url, encoding: .utf8)) == original)
        let empty = dir.appendingPathComponent("new.json")
        _ = try? HooksInstaller.install(settings: empty, hookPath: hook)
        _ = try? HooksInstaller.remove(settings: empty)
        check("install+remove on a missing file leaves {}", (try? String(contentsOf: empty, encoding: .utf8)) == "{}\n")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.contains("bak-claws") } ?? []
        check("backups written", !backups.isEmpty)
    }

    static func text() {
        check("clean strips quotes and period", Summarizer.clean("\"Waiting on your pick: main or release.\"\n") == "Waiting on your pick: main or release")
        check("clean strips label", Summarizer.clean("Recap: PR open, needs review") == "PR open, needs review")
        check("clean caps length", Summarizer.clean(String(repeating: "a", count: 300)).count == 140)
        check("fallback first sentence", Summarizer.fallback("## Done\n\nPushed it. Then more.") == "Done Pushed it.",
              Summarizer.fallback("## Done\n\nPushed it. Then more."))
        check("strip glyph ✳", Ghostty.stripGlyph("✳ Fix login") == "Fix login")
        check("strip spinner", Ghostty.stripGlyph("◐ Claude animated icon") == "Claude animated icon")
        check("keep path titles", Ghostty.stripGlyph("/Users/sam/code") == "/Users/sam/code")
        let claudeTab = Ghostty.Terminal(id: "1", cwd: "/w", name: "✳ Fix login test")
        let shellTab = Ghostty.Terminal(id: "2", cwd: "/w", name: "/w")
        check("tab: claude tab matches its title", TabMatch.matches(claudeTab, rootCwd: "/x", cwd: "/x", title: "Fix login test", strong: false))
        check("tab: claude tab rejects another title", !TabMatch.matches(claudeTab, rootCwd: "/w", cwd: "/w", title: "Budgets", strong: true))
        check("tab: plain shell never matches a titled session", !TabMatch.matches(shellTab, rootCwd: "/w", cwd: "/w", title: "Fix login test", strong: false))
        check("tab: plain shell matches when you typed there", TabMatch.matches(shellTab, rootCwd: "/w", cwd: "/w", title: "Fix login test", strong: true))
        check("tab: untitled session matches by folder", TabMatch.matches(claudeTab, rootCwd: "/w", cwd: "/w", title: nil, strong: false))
        check("shell quoting", "/Users/a b".shellQuoted == "'/Users/a b'" && "/Users/ab".shellQuoted == "/Users/ab")
    }

    /// Builds a two-frame GIF on a 110 x 74 canvas (2 px per art pixel) and converts it back.
    static func art() {
        let w = 110, h = 74
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil) else {
            check("gif encoder", false); return
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (i, (x, y)) in [(10, 20), (12, 22)].enumerated() {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(PixelCrab.clay.cgColor)
            // Art pixels (x..x+3, y..y+1) in top-left coordinates.
            ctx.fill(CGRect(x: x * 2, y: h - (y + 2) * 2, width: 8, height: 4))
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1 + Double(i) * 0.1]] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
        let out = Art.convert(data as Data)
        check("art: frames and delays", out?.meta.frames == 2 && out?.meta.delays == [100, 200], String(describing: out?.meta))
        check("art: union crop", out?.meta.x == 10 && out?.meta.y == 20 && out?.meta.w == 6 && out?.meta.h == 4, String(describing: out?.meta))
        check("art: placeholder sprite", SpriteLibrary(directory: URL(fileURLWithPath: "/nonexistent"))[SpriteLibrary.placeholder] != nil)
    }
}
