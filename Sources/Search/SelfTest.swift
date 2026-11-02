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
        check("privacy: Documents, Desktop, Downloads, iCloud and volumes are never touched",
              ["Documents/x", "Desktop", "Downloads/a/b", "Library/Mobile Documents/c"].allSatisfy { Paths.isPrivacyProtected(Paths.home + "/" + $0) }
              && Paths.isPrivacyProtected("/Volumes/Disk") && !Paths.isPrivacyProtected(Paths.home + "/.claude/projects"))

        // Resuming through Claws for Concern
        for (name, ok) in ResumeBridgeTests.run() { check(name, ok) }

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

        // Claws for Concern only opens a tab for a session filed under the folder the request names.
        let resumable = sessions.filter(\.canResume)
        let refused = resumable.filter { !$0.cwdUncertain && !ProjectDirs.holds($0.id, folder: $0.cwd!, projects: store.root) }
        print("info \(resumable.count) of \(sessions.count) sessions resumable")
        check("the app's folder check accepts every located session", refused.isEmpty, "\(refused.count) refused: \(refused.prefix(3).map(\.id))")
        if let s = resumable.first, let cwd = s.cwd {
            check("resume command: cd to the folder, then the app's template",
                  s.resumeCommand(template: "claude -r {id} --x") == "cd \(Shell.quote(cwd)) && claude -r \(s.id) --x")
        }

        var latencies = [Double]()
        func rank(of s: Session, _ query: String, scope: Scope = .standard) -> Int? {
            let t = CFAbsoluteTimeGetCurrent()
            let out = index.search(ParsedQuery(query), scope: scope, sort: .relevance) { false }!
            latencies.append(CFAbsoluteTimeGetCurrent() - t)
            return out.hits.firstIndex { $0.id == s.id }
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
            check("phrase \"\(phrase)\" finds \(s.id.prefix(8))", out.hits.contains { $0.id == s.id }, "\(out.hits.count) hits")
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
}
