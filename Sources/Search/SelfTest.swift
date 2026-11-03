import Foundation

/// `ClawsSearch --selftest`: unit checks, then searches against the real ~/.claude/projects.
/// The search checks pick their own targets from the data, so they don't rot as transcripts change.
/// Claws for Concern's own `--selftest` runs this too, as a subprocess.
enum SelfTest {
    static func run() -> Int32 {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            let d = detail()
            print(ok ? "PASS" : "FAIL", name + (d.isEmpty ? "" : "  [\(d)]"))
            if !ok { failed += 1 }
        }

        // Tokenizer
        let t1 = Tokenizer.tokens("“Hello”—World_42 foo.bar a")
        check("tokenizer splits on punctuation, dashes, smart quotes, underscores", t1 == ["hello", "world", "42", "foo", "bar"], "\(t1)")
        let t2 = Tokenizer.tokens("नमस्ते दुनिया")
        check("tokenizer keeps Devanagari words whole", t2 == ["नमस्ते", "दुनिया"], "\(t2)")
        let t3 = Tokenizer.tokens("ÉCOLE Straße")
        check("tokenizer lowercases non-ASCII", t3 == ["école", "straße"], "\(t3)")

        // Edit distance
        func ed(_ a: String, _ b: String, _ k: Int) -> Int? {
            let a = Array(a.utf8), b = Array(b.utf8)
            return a.withUnsafeBufferPointer { pa in
                b.withUnsafeBufferPointer { pb in
                    SearchIndex.editDistance(pa.baseAddress!, pa.count, pb.baseAddress!, pb.count, max: k)
                }
            }
        }
        check("edit distance: adjacent swap costs 1", ed("sharepoint", "shaerpoint", 2) == 1)
        check("edit distance: one deletion", ed("conversation", "conversaton", 2) == 1)
        check("edit distance: kitten/sitting is 3", ed("kitten", "sitting", 3) == 3)
        check("edit distance: over the bound is nil", ed("kitten", "sitting", 2) == nil)

        // Query parsing
        let q = ParsedQuery(#"web scrape "load bearing""#)
        check("query: fuzzy terms and a phrase",
              q.terms.filter { $0.mode == .fuzzy }.map(\.text) == ["web", "scrape"] && q.phrases == ["load bearing"],
              "\(q.terms.map(\.text)) \(q.phrases)")
        let one = ParsedQuery(#""deploy""#)
        check("query: one quoted word is an exact word, not a phrase",
              one.phrases.isEmpty && one.terms.map(\.mode) == [.exact])

        // Phrase matching
        let ms = PhraseMatcher("MS  SQL")
        check("phrase: case and whitespace are flexible", ms.occurs(in: "two ms\nsql servers"))
        check("phrase: must start at a word boundary", !ms.occurs(in: "items sqlite"))
        check("phrase: last word may be unfinished", PhraseMatcher("inside base").occurs(in: "inside base64"))
        check("phrase: boundary after an em dash", PhraseMatcher("foo bar").occurs(in: "x—foo bar"))
        check("phrase: space matches punctuation between words", PhraseMatcher("user agent").occurs(in: "set the User-Agent header"))

        // Project folder names
        check("project dir: encodes like Claude Code", ProjectDirs.encode("/Users/someone/.claude/x_y z") == "-Users-someone--claude-x-y-z")
        check("project dir: resolves on disk", ProjectDirs.resolve(ProjectDirs.encode(Paths.home + "/.claude")) == Paths.home + "/.claude")
        check("privacy: Documents, Desktop, Downloads, iCloud, cloud storage, containers and volumes are never touched",
              ["Documents/x", "Desktop", "Downloads/a/b", "Library/Mobile Documents/c", "Library/CloudStorage/Box",
               "Library/Containers/com.x/Data", "Library/Group Containers/g.x"].allSatisfy { Paths.isPrivacyProtected(Paths.home + "/" + $0) }
              && Paths.isPrivacyProtected("/Volumes/Disk") && Paths.isPrivacyProtected("/System/Volumes/Data" + Paths.home + "/Documents/x")
              && !Paths.isPrivacyProtected(Paths.home + "/.claude/projects"))
        for (name, ok) in privacyLinks() { check(name, ok) }
        check("privacy: paths normalised by text", Paths.normalize("/a/./b/../c//d") == "/a/c/d" && Paths.normalize("/..") == "/")

        // Resuming through Claws for Concern
        for (name, ok) in ResumeBridgeTests.run() { check(name, ok) }
        for (name, ok) in pendingReplies() { check(name, ok) }
        for (name, ok) in MainActor.assumeIsolated({ window() }) { check(name, ok) }
        // Claws' self-test passes its own Settings.resumeCommand: read it here the way the window does.
        if let expected = ProcessInfo.processInfo.environment["CLAWS_EXPECTED_RESUME_COMMAND"] {
            check("the resume command read from the app's domain is its Settings value", ResumeCommand.template() == expected,
                  "\(ResumeCommand.template()) vs \(expected)")
        }

        // Session naming
        check("prompt: built-in command is skipped", Prompts.display("<command-name>/clear</command-name>\n<command-args></command-args>") == nil)
        check("prompt: custom command keeps its args",
              Prompts.display("<command-message>x</command-message>\n<command-name>/deploy</command-name>\n<command-args>prod now</command-args>") == "/deploy prod now")
        check("prompt: shell escape", Prompts.display("<bash-input>ls -la</bash-input>") == "! ls -la")
        check("prompt: newlines folded, long text clipped",
              Prompts.display("a\nb") == "a b" && Prompts.display(String(repeating: "x", count: 300))?.count == 201)

        // Real data
        let t0 = CFAbsoluteTimeGetCurrent()
        let store = SessionStore()
        let (sessions, _) = store.load()
        let readSeconds = CFAbsoluteTimeGetCurrent() - t0
        let index = SearchIndex(sessions: sessions)
        let messages = sessions.reduce(0) { $0 + $1.messages.count }
        print(String(format: "info %d sessions, %d messages, %d words; read %.2fs, index %.2fs",
                     sessions.count, messages, index.vocab.count, readSeconds, index.buildSeconds))
        check("transcripts found", !sessions.isEmpty)
        check("every session has a folder or a project dir", sessions.allSatisfy { $0.cwd != nil || !$0.projectDir.isEmpty })
        let filedElsewhere = sessions.filter { $0.recordedCwd != nil }
        let matched = sessions.filter { s in s.cwd.map { ProjectDirs.matches($0, s.projectDir) } ?? false }
        let unsure = sessions.filter(\.cwdUncertain)
        print("info \(matched.count) sessions resolve to their project folder, \(filedElsewhere.count) began elsewhere, \(unsure.count) unresolved: \(unsure.map { $0.projectDir })")
        check("almost every location matches its project folder", matched.count >= sessions.count * 9 / 10)

        let t4 = CFAbsoluteTimeGetCurrent()
        let (again, changed) = store.load()
        check("second load reuses unchanged files", again.count >= sessions.count - 2,
              String(format: "%.2fs, changed=%@", CFAbsoluteTimeGetCurrent() - t4, changed ? "yes" : "no"))

        let renamed = sessions.filter { $0.titleSource == .customTitle || $0.titleSource == .agentName }
        check("renamed sessions are named by /rename", renamed.allSatisfy { !$0.title.isEmpty }, "\(renamed.count) renamed")

        // Claws for Concern reads each session's folder back from its transcript and refuses any other.
        let resumable = sessions.filter(\.canResume)
        var accepted = [Bool](repeating: false, count: resumable.count)
        let t5 = CFAbsoluteTimeGetCurrent()
        accepted.withUnsafeMutableBufferPointer { buf in
            let out = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: resumable.count) { i in
                out[i] = ProjectDirs.resumeFolders(resumable[i].id, projects: store.root).contains(resumable[i].cwd!)
            }
        }
        let refused = resumable.indices.filter { !accepted[$0] }.map { resumable[$0].id }
        let why = Dictionary(grouping: sessions.compactMap(\.whyNotResumable), by: { $0 }).map { "\($0.value.count) \($0.key.lowercased())" }
        print(String(format: "info %d of %d sessions resumable (%@); folders read back in %.2fs", resumable.count, sessions.count,
                     why.sorted().joined(separator: ", "), CFAbsoluteTimeGetCurrent() - t5))
        check("the app reads back the same folder for every resumable session", refused.isEmpty, "\(refused.count) refused: \(refused.prefix(3))")
        if let s = resumable.first, let cwd = s.cwd {
            check("resume command: cd to the folder, then the app's template",
                  s.resumeCommand(template: "claude -r {id} --x") == "cd \(Shell.quote(cwd)) && claude -r \(s.id) --x")
        }
        if let stub = sessions.first(where: { !ResumeRequest.isSessionID($0.id) }) {
            check("no resume command for a stub that is not a session ID", stub.resumeCommand() == nil && !stub.canResume)
        }

        var latencies = [Double]()
        func rank(of s: Session, _ query: String, scope: Scope = .standard) -> Int? {
            let t = CFAbsoluteTimeGetCurrent()
            let out = index.search(ParsedQuery(query), scope: scope, sort: .relevance) { false }!
            latencies.append(CFAbsoluteTimeGetCurrent() - t)
            return out.hits.firstIndex { $0.session.id == s.id }     // either copy of an ID filed twice
        }
        func show(_ r: Int?) -> String { r.map { "rank \($0 + 1)" } ?? "not found" }

        let candidates = sessions
            .filter { $0.messages.contains { $0.kind == .reply && !$0.subagent } }
            .sorted { $0.id < $1.id }
        let picks = stride(from: 0, to: candidates.count, by: max(1, candidates.count / 10)).map { candidates[$0] }
        for s in picks {
            guard let word = rareWord(in: s, index) else { continue }
            let tag = "\(s.id.prefix(8)) \"\(word)\""
            check("exact word finds its session \(tag)", rank(of: s, word) != nil, show(rank(of: s, word)))
            let typo = swapped(word)
            check("typo \"\(typo)\" still finds \(tag)", rank(of: s, typo) != nil, show(rank(of: s, typo)))
            let prefix = String(word.prefix(5))
            check("prefix \"\(prefix)\" finds \(tag)", rank(of: s, prefix) != nil, show(rank(of: s, prefix)))
            check("ID prefix ranks \(s.id.prefix(8)) first", rank(of: s, String(s.id.prefix(8))) == 0, show(rank(of: s, String(s.id.prefix(8)))))
        }

        if let s = picks.first(where: { samplePhrase(in: $0) != nil }), let phrase = samplePhrase(in: s) {
            let out = index.search(ParsedQuery("\"\(phrase)\""), scope: .standard, sort: .relevance) { false }!
            check("phrase \"\(phrase)\" finds \(s.id.prefix(8))", out.hits.contains { $0.session.id == s.id }, "\(out.hits.count) hits")
            let verbatim = out.hits.allSatisfy { hit in
                hit.session.metaText.range(of: phrase, options: .caseInsensitive) != nil ||
                hit.session.messages.contains { $0.text.range(of: phrase, options: .caseInsensitive) != nil }
            }
            check("every phrase hit contains the phrase verbatim", verbatim)
            if let snip = out.hits.first.flatMap({ Snippets.row($0.session, out) }) {
                check("row snippet highlights a match", snip.runs.contains { $0.inlinePresentationIntent != nil })
            }
        }

        if let s = sessions.first(where: { $0.cwd != nil }), let leaf = s.cwd.map({ URL(fileURLWithPath: $0).lastPathComponent }),
           Tokenizer.tokens(leaf).count == 1 {
            check("folder name \"\(leaf)\" finds \(s.id.prefix(8))", rank(of: s, leaf) != nil, show(rank(of: s, leaf)))
        }

        let worst = latencies.max() ?? 0
        let mean = latencies.isEmpty ? 0 : latencies.reduce(0, +) / Double(latencies.count)
        check("queries stay interactive", worst < 0.5, String(format: "mean %.0fms, worst %.0fms over %d", mean * 1000, worst * 1000, latencies.count))

        // Usage figures: the reader on made-up transcripts, the tables, the cache, the demo's figures,
        // then your own transcripts (docs/usage.md).
        for (name, ok) in UsageTests.run() + UsageTests.real() { check(name, ok) }

        // Search's usage panel and list: wording and sorting; then the window on the demo's figures.
        for (name, ok) in UsagePanelTests.run() { check(name, ok) }
        for (name, ok) in MainActor.assumeIsolated({
            UsagePanelTests.window() + UsagePanelTests.copies() + UsagePanelTests.races() + UsagePanelTests.chart()
        }) { check(name, ok) }

        // Last: it switches the home folder for the whole process, and back.
        for (name, ok) in MainActor.assumeIsolated({ demo() }) { check(name, ok) }

        print(failed == 0 ? "ALL PASS" : "\(failed) FAILED")
        return failed == 0 ? 0 : 1
    }

    /// The reply word of 7+ ASCII letters that the fewest sessions contain.
    private static func rareWord(in s: Session, _ index: SearchIndex) -> String? {
        var best: (String, Int)?
        for m in s.messages where m.kind == .reply && !m.subagent {
            for w in Tokenizer.tokens(m.text) where w.count >= 7 && w.allSatisfy({ $0.isASCII && $0.isLetter }) {
                let df = index.documentFrequency(w)
                if df > 0 && df < (best?.1 ?? .max) { best = (w, df) }
            }
        }
        return best?.0
    }

    private static func swapped(_ w: String) -> String {
        var c = Array(w)
        let i = c[2] != c[3] ? 2 : 3
        c.swapAt(i, i + 1)
        return String(c)
    }

    private static func samplePhrase(in s: Session) -> String? {
        for m in s.messages where m.kind == .reply && !m.subagent {
            if let r = m.text.range(of: #"\b[A-Za-z]{4,} [A-Za-z]{4,} [A-Za-z]{4,}"#, options: .regularExpression) {
                return String(m.text[r])
            }
        }
        return nil
    }

    /// `--demo`, as the CLI turns it on: made-up sessions only, nothing opened outside the demo folder
    /// (so nothing under your real ~/.claude), nothing sent when you press Resume, and all gone after.
    @MainActor
    private static func demo() -> [(String, Bool)] {
        let real = Paths.realHome + "/.claude"
        let root = Demo.activate()
        // Both spellings of the temporary folder: /var/… and, from the loader's listings, /private/var/….
        // (Not resolvingSymlinksInPath, which strips /private on purpose.)
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let inside = [root.path, realpath(root.path, &buf).map { String(cString: $0) } ?? root.path].map { $0 + "/" }
        let store = SessionStore()      // the default location, as the window's
        let sessions = store.load().sessions
        let opened = store.opened
        for p in opened.sorted() where !inside.contains(where: { p.hasPrefix($0) }) { print("info demo opened outside its folder: \(p)") }
        var out: [(String, Bool)] = [
            ("demo: the loader reads the demo's own ~/.claude/projects", inside.contains { store.root.path.hasPrefix($0) }),
            ("demo: every folder and file the loader opened is in the demo folder (\(opened.count))",
             !opened.isEmpty && opened.allSatisfy { p in inside.contains { p.hasPrefix($0) } }),
            ("demo: nothing under the real ~/.claude, and no walk of the disk", !opened.contains { $0.hasPrefix(real) } && !opened.contains("/")),
            ("demo: 12 sessions in 6 projects, all from the last two weeks",
             sessions.count == 12 && Set(sessions.map(\.projectDir)).count == 6
             && sessions.allSatisfy { Date().timeIntervalSince($0.modified) < 14 * 86_400 }),
            ("demo: named by ai-title and by /rename, with a subagent and tool calls",
             Set(sessions.map(\.titleSource)).isSuperset(of: [.aiTitle, .agentName]) && sessions.contains { $0.subagentCount > 0 }
             && sessions.contains { $0.messages.contains { $0.kind == .toolCall } }),
            ("demo: shown as resumable, with the default command (never your own)",
             sessions.allSatisfy(\.canResume) && sessions.allSatisfy { $0.resumeCommand()?.contains(" && claude --resume ") == true }),
        ]
        let hits = SearchIndex(sessions: sessions).search(ParsedQuery("\"rate limit\""), scope: .standard, sort: .relevance) { false }?.hits ?? []
        out.append(("demo: \"rate limit\" has several sessions to highlight (\(hits.count))", hits.count >= 4))
        let model = AppModel(store: store)
        if let s = sessions.first { model.resume(s) }
        out.append(("demo: Resume sends nothing and says so", model.flash?.hasPrefix("Demo sessions") == true && !ResumeClient.shared.hasPending))
        Demo.deactivate()
        out.append(("demo: off again, your home back and the demo files gone",
                    Paths.home == Paths.realHome && !FileManager.default.fileExists(atPath: root.path)))
        return out
    }

    /// Links into protected folders, made in a scratch folder. Making a link never touches its target.
    private static func privacyLinks() -> [(String, Bool)] {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("claws-privacy-\(getpid())").path
        defer { try? fm.removeItem(atPath: base) }
        try? fm.createDirectory(atPath: base + "/plain", withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: base + "/docs", withDestinationPath: Paths.home + "/Documents")
        try? fm.createSymbolicLink(atPath: base + "/rel", withDestinationPath: "docs")
        try? fm.createSymbolicLink(atPath: base + "/ok", withDestinationPath: base + "/plain")
        try? fm.createSymbolicLink(atPath: base + "/loop", withDestinationPath: base + "/loop")
        return [
            ("privacy: a plain folder is fine", !Paths.isPrivacyProtected(base + "/plain/x")),
            ("privacy: a link into ~/Documents is caught without following it", Paths.isPrivacyProtected(base + "/docs/project")),
            ("privacy: so is a relative link to that link", Paths.isPrivacyProtected(base + "/rel/project")),
            ("privacy: a link to a plain folder is fine", !Paths.isPrivacyProtected(base + "/ok/x")),
            ("privacy: a link loop is left alone", Paths.isPrivacyProtected(base + "/loop/x")),
        ]
    }

    /// What the window does with each reply and timeout.
    private static func pendingReplies() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        let t0 = Date()
        var p = PendingResumes()
        p.add(token: "a", command: "cmd-a", at: t0)
        out.append(("replies: one for another request is ignored",
                    p.reply(ResumeReply(token: "other", status: .opened, message: "x")) == nil && !p.isEmpty))
        out.append(("replies: no answer in 2 s copies the command",
                    p.expire(at: t0 + 1).isEmpty
                    && p.expire(at: t0 + 2.1) == [.copy(command: "cmd-a", message: "Claws for Concern did not answer. Command copied: cmd-a")]
                    && p.isEmpty))
        p.add(token: "b", command: "cmd-b", at: t0)
        out.append(("replies: opening is shown and buys time", p.reply(ResumeReply(token: "b", status: .opening, message: "Opening…")) == .show("Opening…")
                    && p.expire(at: t0 + 10).isEmpty))
        out.append(("replies: no outcome in 30 s copies the command", p.expire(at: t0 + 30.1).count == 1 && p.isEmpty))
        p.add(token: "c", command: "cmd-c", at: t0)
        out.append(("replies: failed copies the command", p.reply(ResumeReply(token: "c", status: .failed, message: "No."))
                    == .copy(command: "cmd-c", message: "No. Command copied.") && p.isEmpty))
        p.add(token: "d", command: "cmd-d", at: t0)
        out.append(("replies: opened is shown and done", p.reply(ResumeReply(token: "d", status: .opened, message: "Done")) == .show("Done") && p.isEmpty))
        p.add(token: "e", command: "cmd-e", at: t0)
        out.append(("replies: quitting copies what is still waiting", p.expire(at: t0, all: true).count == 1 && p.isEmpty))
        return out
    }

    /// The window's model over three made-up transcripts: Return right after typing must resume the
    /// new first hit, not the old selection; a session whose folder is gone cannot be resumed.
    @MainActor
    private static func window() -> [(String, Bool)] {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("claws-window-\(getpid())")
        defer { try? fm.removeItem(at: base) }
        let ids = (1...3).map { String(format: "1f1e2d3c-4b5a-6978-8a9b-acbdcedfe0%02d", $0) }
        let folders = ["alpha", "beta", "gone"].map { base.appendingPathComponent($0).path }
        try? fm.createDirectory(atPath: folders[0], withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: folders[1], withIntermediateDirectories: true)
        for (i, (prompt, day)) in [("meet the zebra crossing", "01-10"), ("nothing to see here", "06-10"), ("lost words", "03-10")].enumerated() {
            let dir = base.appendingPathComponent("projects").appendingPathComponent(ProjectDirs.name(for: folders[i]))
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let line = #"{"type":"user","cwd":"\#(folders[i])","timestamp":"2026-\#(day)T10:00:00.000Z","message":{"content":"\#(prompt)"}}"#
            fm.createFile(atPath: dir.appendingPathComponent(ids[i] + ".jsonl").path, contents: Data((line + "\n").utf8))
        }
        let model = AppModel(store: SessionStore(root: base.appendingPathComponent("projects")))
        var resumed: [String] = []
        model.resumer = { resumed.append($0.id) }
        func wait(_ seconds: Double, until done: () -> Bool) {
            let end = Date().addingTimeInterval(seconds)
            while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        wait(10) { !model.indexing && model.selectedSession?.id == ids[1] }
        var out: [(String, Bool)] = [("window: the newest session is selected first", model.selectedSession?.id == ids[1])]
        model.query = "zebra"
        model.resumeSelected()
        out.append(("window: Return before the new results waits for them", resumed.isEmpty))
        wait(5) { !resumed.isEmpty }
        out.append(("window: then resumes the new first hit, not the old selection", resumed == [ids[0]]))
        let byID = Dictionary(uniqueKeysWithValues: model.hits.map { ($0.session.id, $0.session) })
        model.query = ""
        wait(5) { model.hits.count == 3 }
        let all = Dictionary(uniqueKeysWithValues: model.hits.map { ($0.session.id, $0.session) }).merging(byID) { a, _ in a }
        out.append(("window: a session whose folder is gone cannot be resumed",
                    all[ids[0]]?.canResume == true && all[ids[2]]?.whyNotResumable == "Its folder no longer exists"))
        return out
    }
}
