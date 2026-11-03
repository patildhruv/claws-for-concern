import Foundation

/// `--demo`: made-up sessions in a made-up home folder, for the README's pictures and for trying the
/// window without your own transcripts. While it is on, `Paths.home` points into a temporary folder,
/// and every path the loader, the folder checks and `~` use derives from it: nothing reads your real
/// ~/.claude, and nothing is resumed (the self-test checks the paths the loader opens).
enum Demo {
    private(set) static var active = false
    private static var root: URL?

    /// Writes the sessions under a new temporary folder and points `Paths.home` at its home. Returns
    /// the root, which also holds the demo's project folders.
    @discardableResult
    static func activate() -> URL {
        let fm = FileManager.default
        let prefix = "claws-search-demo-"
        // A demo killed before it could tidy up (a closed pipe, Ctrl-C) leaves its folder: remove those.
        for name in (try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? [] where name.hasPrefix(prefix) {
            if let pid = Int32(name.dropFirst(prefix.count)), kill(pid, 0) != 0, errno == ESRCH {
                try? fm.removeItem(at: fm.temporaryDirectory.appendingPathComponent(name))
            }
        }
        let dir = fm.temporaryDirectory.appendingPathComponent(prefix + "\(getpid())", isDirectory: true)
        try? fm.removeItem(at: dir)
        let home = dir.appendingPathComponent("home", isDirectory: true)
        let now = Date()
        write(home: home, now: now)
        loadUsage(home: home, now: now)
        Paths.home = home.path
        root = dir
        active = true
        return dir
    }

    /// Back to your own home folder; the demo files go.
    static func deactivate() {
        guard active else { return }
        Paths.home = Paths.realHome
        dropUsage()
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        active = false
    }

    struct Session {
        enum Name { case ai(String), renamed(String) }
        enum Turn { case you(String), claude(String), tool(String, [String: String]), agent(String, [Turn]) }
        let id: String
        let folder: String      // under the demo home
        let name: Name
        let branch: String
        let hoursAgo: Double
        let turns: [Turn]
    }

    /// Writes `.claude/projects` the way Claude Code lays it out, and creates each project folder.
    static func write(home: URL, now: Date) {
        let fm = FileManager.default
        let projects = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ o: [String: Any]) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
        }
        for s in sessions {
            let folder = home.appendingPathComponent(s.folder).path
            try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let dir = projects.appendingPathComponent(ProjectDirs.name(for: folder), isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // The lines spread over the hours its usage figures say it ran (DemoUsage.swift), ending
            // `hoursAgo` before now.
            func count(_ turns: [Session.Turn]) -> Int {
                turns.reduce(0) { n, t in if case .agent(_, let inner) = t { return n + 2 + count(inner) }; return n + 1 }
            }
            let total = count(s.turns)
            let step = (usageSpecs[s.id]?.hours ?? 0.1) * 3600 / Double(total)
            var clock = now.addingTimeInterval(-s.hoursAgo * 3600 - Double(total) * step)
            func records(_ turns: [Session.Turn], subagent: Bool) -> [String] {
                var out: [String] = []
                for t in turns {
                    clock = clock.addingTimeInterval(step)
                    var base: [String: Any] = ["sessionId": s.id, "cwd": folder, "gitBranch": s.branch, "entrypoint": "cli",
                                               "version": "2.1.316", "timestamp": iso.string(from: clock), "isSidechain": subagent]
                    switch t {
                    case .you(let text):
                        base["type"] = "user"
                        base["message"] = ["role": "user", "content": text]
                    case .claude(let text):
                        base["type"] = "assistant"
                        base["message"] = ["role": "assistant", "content": [["type": "text", "text": text]]]
                    case .tool(let name, let input):
                        base["type"] = "assistant"
                        base["message"] = ["role": "assistant", "content": [["type": "tool_use", "id": "toolu_demo", "name": name, "input": input]]]
                    case .agent(let prompt, let inner):
                        base["type"] = "assistant"
                        base["message"] = ["role": "assistant", "content": [["type": "tool_use", "id": "toolu_demo", "name": "Agent",
                                                                             "input": ["description": "Explore", "prompt": prompt]]]]
                        let subagents = dir.appendingPathComponent(s.id).appendingPathComponent("subagents", isDirectory: true)
                        try? fm.createDirectory(at: subagents, withIntermediateDirectories: true)
                        let lines = records([Session.Turn.you(prompt)] + inner, subagent: true)
                        fm.createFile(atPath: subagents.appendingPathComponent("agent-a1b2c3.jsonl").path,
                                      contents: Data((lines.joined(separator: "\n") + "\n").utf8))
                    }
                    out.append(line(base))
                }
                return out
            }
            var lines = records(s.turns, subagent: false)
            switch s.name {
            case .ai(let t): lines.append(line(["type": "ai-title", "aiTitle": t, "sessionId": s.id]))
            case .renamed(let t):
                // /rename writes both.
                lines.append(line(["type": "custom-title", "customTitle": t, "sessionId": s.id]))
                lines.append(line(["type": "agent-name", "agentName": t, "sessionId": s.id]))
            }
            fm.createFile(atPath: dir.appendingPathComponent(s.id + ".jsonl").path, contents: Data((lines.joined(separator: "\n") + "\n").utf8))
        }
    }

    // Twelve sessions in six made-up projects over the last two weeks. Several mention rate limits, so
    // the README's query, "rate limit", has something to highlight.
    static let sessions: [Session] = [
        Session(id: "7c1e4b2a-93d5-4f0e-8a6b-2d9f1c3e5a71", folder: "code/payments-api",
                name: .ai("Retry webhook deliveries on rate limit errors"), branch: "fix/webhook-retries", hoursAgo: 26, turns: [
            .you("Our webhook sender gives up as soon as the partner API returns 429. Can we retry with backoff instead of dropping the event?"),
            .claude("Yes. Right now `deliver()` treats any non-2xx response as final. I'll add a retry loop that honours the `Retry-After` header when the partner sends one and otherwise backs off exponentially (1 s, 2 s, 4 s, up to 60 s). After five attempts the event goes to the dead-letter table, so nothing is lost."),
            .tool("Read", ["file_path": "src/webhooks/deliver.ts"]),
            .tool("Edit", ["file_path": "src/webhooks/deliver.ts", "old_string": "if (!res.ok) throw new DeliveryError(res.status)",
                           "new_string": "if (res.status === 429) return retryAfter(res, attempt)"]),
            .tool("Bash", ["command": "npm test -- webhooks", "description": "Run the webhook tests"]),
            .claude("All 18 webhook tests pass, including two new ones: a 429 with `Retry-After: 3` waits three seconds, and a burst of 429s ends in the dead-letter table after five tries. The rate limit counter is exported as `webhook_rate_limited_total`."),
            .you("Nice. Can the rate limit retries use jitter so a whole batch doesn't retry at the same moment?"),
            .claude("Added full jitter: each wait is a random value between zero and the backoff ceiling. The tests use a seeded random source, so they stay deterministic."),
        ]),
        Session(id: "2b8f6d14-0a7e-4c39-b5d2-91e3f07a6c48", folder: "code/payments-api",
                name: .renamed("Idempotency keys for refunds"), branch: "feat/refund-idempotency", hoursAgo: 75, turns: [
            .you("Refunds can be submitted twice if the client retries after a timeout. Add idempotency keys."),
            .claude("I'll store the `Idempotency-Key` header with the response for 24 hours in a `refund_requests` table. A repeat request with the same key gets the stored response instead of a second refund; the same key with a different body is rejected with 422."),
            .tool("Write", ["file_path": "migrations/0042_refund_requests.sql",
                            "content": "create table refund_requests (\n  key text primary key,\n  body_hash text not null,\n  response jsonb not null,\n  created_at timestamptz default now()\n);"]),
            .tool("Bash", ["command": "make migrate && go test ./refunds/...", "description": "Apply the migration and run the refund tests"]),
            .claude("Migration applied and the refund tests pass. I documented the header in `docs/api/refunds.md`."),
        ]),
        Session(id: "e5a03c97-6f21-48bd-9e0c-3d7b2a8f1e65", folder: "code/ios-app",
                name: .ai("Fix crash when opening a push notification"), branch: "main", hoursAgo: 50, turns: [
            .you("The app crashes if you tap a push notification while it is cold-starting: \"Unexpectedly found nil while unwrapping an Optional value\" in `NotificationRouter.route(_:)`."),
            .claude("On a cold start the router reads the scene's window before the scene has connected. I'll queue the notification and route it once the first scene becomes active."),
            .tool("Edit", ["file_path": "App/Notifications/NotificationRouter.swift", "old_string": "guard let window = scene.window!",
                           "new_string": "guard let window = scene?.window else { pending.append(payload); return }"]),
            .tool("Bash", ["command": "xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 16'", "description": "Run the unit tests"]),
            .claude("Fixed, and covered by a new test that launches the app with a notification payload. All 214 tests pass."),
        ]),
        Session(id: "91d4f2b6-3c8a-4e07-a1f5-6b2e9d0c7a34", folder: "code/ios-app",
                name: .ai("Dark mode colours for the settings screen"), branch: "design/settings-dark", hoursAgo: 220, turns: [
            .you("Settings looks washed out in dark mode. Use the semantic colours from the asset catalogue."),
            .tool("Grep", ["pattern": "Color\\(white:", "path": "App/Settings"]),
            .claude("Found 11 hard-coded greys in 4 files. I replaced them with `Color(.secondarySystemBackground)` and the catalogue's `AccentSoft`, so the toggles follow the accent colour in both modes."),
        ]),
        Session(id: "4f6a8e20-b7c3-4d91-8e5f-0c2d7b9a1e83", folder: "code/web-dashboard",
                name: .ai("Chart of daily active users on the overview page"), branch: "feat/dau-chart", hoursAgo: 146, turns: [
            .you("Add a chart of daily active users to the overview page, last 30 days."),
            .claude("First I'll have an Explore agent find how the other charts on that page get their data."),
            .agent("Find where the overview page's charts fetch their data, and which chart library they use.", [
                .tool("Grep", ["pattern": "useMetrics", "path": "src"]),
                .claude("The charts use Recharts. Data comes from `useMetrics(range)` in `src/hooks/useMetrics.ts`, which calls `/api/metrics?range=30d`. That endpoint is rate limited to 60 requests a minute per user, so the hook caches responses for five minutes."),
            ]),
            .claude("Added `DailyActiveUsersChart` on the same `useMetrics` hook, so it shares the five-minute cache and stays well under the rate limit."),
            .tool("Bash", ["command": "npm run test -- overview", "description": "Run the overview tests"]),
        ]),
        Session(id: "c38b1e7d-5a24-49f6-b0d3-8e1f6a2c9b57", folder: "code/web-dashboard",
                name: .renamed("API client: honour rate limit headers"), branch: "fix/api-throttling", hoursAgo: 98, turns: [
            .you("The dashboard hammers the API when someone opens ten tabs. Make the client respect the rate limit headers."),
            .claude("The API already sends `X-RateLimit-Remaining` and `X-RateLimit-Reset`. I'll make the fetch wrapper hold new requests when Remaining reaches zero, resume at Reset, and show a small \"Slowing down\" banner instead of failing."),
            .tool("Edit", ["file_path": "src/api/client.ts", "old_string": "return fetch(url, init)",
                           "new_string": "await limiter.wait()\n  return fetch(url, init).then(limiter.observe)"]),
            .claude("Done. With ten tabs open the client stays under the limit: in a five-minute test the banner showed twice and no request failed."),
        ]),
        Session(id: "a7e25f93-1d6c-4b80-9f3a-5c0e8d2b7f16", folder: "notes/blog",
                name: .ai("Draft: what we learned rate limiting our public API"), branch: "main", hoursAgo: 122, turns: [
            .you("Help me outline a blog post about the rate limits we introduced on our public API last quarter. Audience: developers who call the API."),
            .claude("Outline:\n1. Why we added a rate limit: one customer's sync job was 40% of all traffic.\n2. A token bucket per API key: 600 requests a minute, bursts of 100.\n3. The headers we send and how to read them.\n4. What broke, and how we gave heavy users more headroom.\n5. Advice: back off on 429, honour Retry-After, batch where you can."),
            .you("Good. Expand section 3 with an example response."),
            .claude("Added an example 429 response with `Retry-After: 12` and the three `X-RateLimit-*` headers, plus a short client snippet that waits before retrying."),
            .tool("Write", ["file_path": "drafts/rate-limits.md", "content": "# What we learned rate limiting our public API\n\n..."]),
        ]),
        Session(id: "5d9c7a31-e2f8-4a6b-83d0-b4f1c6e9a205", folder: "notes/blog",
                name: .ai("Outline for a post on SQLite in production"), branch: "main", hoursAgo: 290, turns: [
            .you("Outline a post on running SQLite in production for a small SaaS."),
            .claude("1. When SQLite is enough, and when it isn't. 2. WAL mode and busy timeouts. 3. Continuous backups to object storage. 4. The signs that it's time to move to Postgres."),
        ]),
        Session(id: "f0b6d8e4-7a39-4c25-ae1b-2d8c5f7e9031", folder: "infra/terraform",
                name: .ai("Move staging to a smaller database instance"), branch: "chore/staging-db", hoursAgo: 196, turns: [
            .you("Staging's database costs more than production's. Move it to a smaller instance class without breaking the nightly tests."),
            .claude("Plan: change the instance class in `staging/db.tf` and apply in the quiet window between 02:00 and 04:00. Storage stays as it is."),
            .tool("Bash", ["command": "terraform plan -target=module.staging_db", "description": "Preview the database change"]),
            .claude("The plan changes only the instance class. Applying takes about eight minutes with one brief failover."),
        ]),
        Session(id: "3e8a2c6f-9b14-4d7e-b2a5-7f0c1e9d4b68", folder: "infra/terraform",
                name: .renamed("Queue backlog alerts"), branch: "feat/queue-alerts", hoursAgo: 245, turns: [
            .you("Alert us when the jobs queue backs up for more than ten minutes."),
            .tool("Edit", ["file_path": "monitoring/queues.tf", "old_string": "# alarms", "new_string": "resource \"aws_cloudwatch_metric_alarm\" \"jobs_backlog\" {"]),
            .claude("Added an alarm on the age of the oldest message above 600 s for two periods, sent to the on-call channel."),
        ]),
        Session(id: "b1f7e3a9-4c62-4e8d-95b0-6a3d8c2f1e74", folder: "code/data-pipeline",
                name: .ai("Nightly export: resume after rate limit errors"), branch: "main", hoursAgo: 3, turns: [
            .you("Last night's export to the warehouse stopped halfway with \"API Error: rate limit reached\". Make it resume where it stopped."),
            .claude("The exporter writes pages in order but keeps no cursor, so any failure starts again from page one. I'll store the last completed page in `export_state` and, on a 429, sleep for the `Retry-After` interval before continuing."),
            .tool("Edit", ["file_path": "pipeline/export.py", "old_string": "for page in pages():", "new_string": "for page in pages(start=state.last_page + 1):"]),
            .tool("Bash", ["command": "pytest tests/test_export.py -q", "description": "Run the export tests"]),
            .claude("Tests pass, including a simulated rate limit on page 37: the export waits, then carries on from page 37 instead of page 1."),
        ]),
        Session(id: "68c0d5b2-af47-4193-8e6c-c9b2f4a70d1e", folder: "code/data-pipeline",
                name: .ai("Dedupe events by idempotency key"), branch: "fix/duplicate-events", hoursAgo: 315, turns: [
            .you("We see duplicate events in the warehouse after retries. Dedupe them."),
            .claude("I added a `MERGE` on `event_id` to the load step, so a retried batch updates rows instead of inserting them again."),
            .tool("Bash", ["command": "dbt run --select events_dedup", "description": "Rebuild the deduplicated events model"]),
        ]),
    ]
}
