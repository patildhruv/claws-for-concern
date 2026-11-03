# Usage figures

What each Claude Code conversation used and cost, read from its transcript: Search's detail pane and
list, and the Usage window (1.4, plan in `docs/plan-1.4.md`). All of it runs in the search helper.
Sources in `Sources/Search/`:

```
UsageStore.load()                       Usage.swift: every session's SessionUsage, by session ID
  ├─ UsageCache                         UsageCache.swift: unchanged transcripts come from disk
  └─ changed sessions, in batches of ~384 MB of transcript
       ├─ every 4 MB piece of every file at once      UsageReader.events(in:piece:…)  → [Event]
       └─ each session's events, file by file          UsageReader.fold → UsageBuilder → SessionUsage
Pricing, ContextWindows                 Pricing.swift: dated tables
Demo.usage                              DemoUsage.swift: --demo's figures, played through UsageBuilder
```

- **`SessionUsage` is the contract** with both screens: change it only by adding fields (and bump
  `UsageCache.version`, since synthesized decoding fails on a missing key). The main thread is the
  conversation itself; subagents are its Agent calls and workflow agents. Tokens, cost, tool counts,
  API errors and lines include subagents; context, compactions, turns and tool time are the main
  thread's. Every figure not taken from Claude Code is marked by `Source.estimate` and shown "est.".
- `UsageStore.load()` is safe off the main thread but not reentrant (callers serialise). It returns
  one entry per session ID, built from every real transcript filed under that ID (copies that may
  have diverged, oldest first: each shared line and reply counted once); `usage(forTranscript:)` /
  `byTranscript` give each transcript file its own. A transcript that is a link is read through its
  target (stamped by the target), and not again when the target is listed too.
- `Day` carries tokens, an estimated cost, Claude's working seconds per local hour and lines changed,
  so date filters and the weekday × hour grid work for sessions that span days. `cost(of:)` and
  `lines(of:)` scale a day's share to Claude Code's total when that is the session's figure.

## Verified on real transcripts (Claude Code 2.1.316, 548 transcripts, 2026-11-03)

Corrections to the plan's "Verified before planning" list are marked **(corrects the plan)**.

- **A reply's lines do not all carry the same usage (corrects the plan).** Claude Code writes one
  line per content block, each with `usage` as it stood then: `output_tokens` grows, the last line
  has the final count; input and cache fields repeat. 18,073 of 89,889 replies (20%) differ. Output
  summed from first lines: 78.3M; from last lines: 106.4M (+36%). **Count each `message.id` once
  (else `requestId`), with its last line's usage.**
- **A reply belongs to the file it first appears in.** 354 subagent replies repeat a main-thread
  `message.id`: a forked subagent starts with copies of the parent's context, unmarked.
- **Lines marked `forkedFrom` were copied from another session** (7 sessions, 4,018 assistant lines,
  2,469 user, 520 system): skipped, so a fork's history is counted once, in its parent.
- **Older forks are not marked.** Under Claude Code 2.1.139–2.1.219, 9 transcripts start with an
  unmarked verbatim copy of another session's replies in the same project folder (692 replies, the
  same first timestamp): each session's figures include that copied history, so totals across
  sessions count it twice (1.4% of all output and cache reads here). Not corrected: it needs a pass
  across sessions (a reply ID already in an earlier-started transcript is a copy). PM decision
  (2026-11-03): accepted for 1.4.0, about 1.4% of output and cache reads across sessions counted twice;
  fix in a later 1.4.x.
- **One session ID filed under two project folders** (8 IDs). One is a link to the other file (read
  once, through its target). Seven are real copies, and four of them diverged: one has 14
  replies only in one copy and 284 only in the other. The ID map now reads all copies as one
  conversation (a shared line by its `uuid`, a reply by its `message.id`, the context curve in time
  order, a cost-state current only against its own copy's replies); a sum over `byTranscript`
  counts each copy whole.
- **Workflow agents live a level deeper (corrects the plan):** `<session>/subagents/workflows/<run>/
  agent-*.jsonl` (1,674 files, 42K assistant lines) besides `<session>/subagents/agent-*.jsonl`
  (339). `<run>/journal.jsonl` is the workflow's own log (started/result records), not an agent.
  **A run folder can be a link** to the run of the session a resumed one came from (1 seen): never
  followed, so those agents count once, where they ran.
- **`cost-state` is per process, not per session (corrects the plan).** 261 of 548 transcripts
  have one; the last is current (no main-thread reply after it) in 259. 168 match the transcript's
  tokens model by model, apart from Claude Code's own Haiku side requests (`claude-haiku-4-5` in 208
  records, absent from every transcript). Of 256 current records cross-checked, 44 cover less than
  the transcript: a resumed process starts its counter at zero (a record of $0 beside 294K output
  tokens). Others cover more than any transcript holds: calls Claude Code bills but never writes
  (fresh input up to 960x, cache reads up to 1.65x, output within a few %; which calls was not
  traced). Models are keyed by setting name (`claude-opus-5[1m]`). "It lags" holds only while the
  process runs.
  **Rule (PM, 2026-11-03): Claude Code's figure only when the record is current and counts at least
  99% of the transcript's output tokens and cache reads** (`UsageBuilder.covers`; the same for its
  line counts); else the estimate, with Claude Code's figure kept in `cost.claudeCodeUSD`.
- **Value types:** in all 500 records every number is a number and `modelUsage` a dictionary. The
  reader still takes numbers as strings and `modelUsage` as a JSON or Python-style string.
- **Claude Code's price table is ours:** for 190 model entries whose token counts match the
  transcript's exactly, our estimate equals its `costUSD` (worst difference 0.0000%).
- **Context after a reply** = `input + cache_read + cache_creation` of that reply, main thread.
  Transcripts never state the window; main transcripts here carry no `isSidechain` lines.
- **Compactions:** `system`/`compact_boundary` with `compactMetadata` (`trigger`, `preTokens`,
  `postTokens`, `cumulativeDroppedTokens`, `durationMs`); 47 here. One subagent compacted too
  (not counted: compactions are the main thread's).
- **Turns:** `system`/`turn_duration` (`durationMs`, written at the turn's end) in 479 of 549
  transcripts: 6,804 records against 8,550 prompts, and some sessions have records only for later
  turns (one: 5 min recorded, 170 min before its first record). Subagents write
  `turn_duration` too (ignored).
- **`turn_duration` leaves out the time you take to answer.** Of 80 question or plan waits over 10
  minutes, 67 are longer than the turn that holds them (one turn: 1 minute around a 138-minute wait);
  13 are covered. So it measures Claude's own time, and a turn's record sits in the last `durationMs`
  before its end, not spread over the wait.
- **API errors:** `assistant` lines with `isApiErrorMessage`, model `<synthetic>`, `error`
  (`server_error` 74, `rate_limit` 47, `invalid_request` 21, `unknown` 17, `authentication_failed`
  10, `oauth_org_not_allowed` 2, `billing_error` 2), `apiErrorStatus` in 68, text "API Error: …";
  counted once per `message.id`. `system`/`api_error` (156) are retry notices, not counted.
- **Lines:** Claude Code's own diff is in the tool result: `toolUseResult.structuredPatch` hunks
  (lines whose first byte is `+`/`-`; an empty list for a file written unchanged), or `type:
  "create"` with the file's `content`, counted as `split("\n")` (a final newline starts one more
  line). **Only a successful call counts:** 303 Edit and Write calls failed or were rejected
  (`is_error`, or a `toolUseResult` that is only text such as "User rejected tool use"), and 8 had
  no result. Subagent transcripts write no `toolUseResult` at all (576 successful calls): there the
  call's input counts (shared head and tail lines set aside). **Each call once:** a forked subagent
  repeats the parent's tool results (148 calls, 3,918 lines in one session). With these rules the
  count equals Claude Code's `totalLinesAdded/Removed` in all 213 records that cover their transcript.
- A diff line can start with `-` and then a combining mark (a Kannada nukta, seen once): one Swift
  `Character`, but a removed line to Claude Code; the first byte decides.
- **Usage fields seen:** `speed` only `standard`, `inference_geo` `global`, `not_available` or
  empty, `server_tool_use` never non-zero, `cache_creation` split into `ephemeral_5m/1h` on every
  reply (1-hour writes are most of the main thread's). `usage.iterations` had two entries once.
- **Tool results are half of all bytes** (1.36 GB of 2.85 GB in main transcripts' user lines).

## Rules after the review (2026-11-03)

An independent review reproduced seven bugs; each is a self-test now (`UsageTests.review`), and the
cross-check compares lines, tool time and turn seconds too.

- **Tool time never includes waiting for you and never exceeds Claude worked.** It is the main
  thread's calls, from `tool_use` to `tool_result`, overlaps once, minus two kinds:
  `AskUserQuestion` and `ExitPlanMode` (`UsageBuilder.waitingTools`: their whole interval is your
  answer) are left out; every other call is clipped to the turns' working time, which catches a
  permission prompt inside a call (its wait lies outside the turn's `durationMs`). Working time is
  each turn's interval: `[end − durationMs, end]` for a recorded turn, prompt to last reply for an
  estimated one. Before: AskUserQuestion was 55% of all tool time, one call 21 h, and 31 sessions had
  more tool time than working time (one: 948 min against 47). After: none.
- **Turns one by one.** A prompt starts a turn (so does a reply after a recorded turn with no prompt
  in between). A turn with Claude Code's `turn_duration` takes it; one without is estimated from its
  prompt to its last reply, minus any time a recorded turn already covers (a prompt you queue
  inside a turn splits it, and the record covers both halves). `Turns.source` is `.estimate` if any
  turn was estimated (145 sessions that were `.claudeCode` before).
- **Lines** as above: successful calls only, each call once, Claude Code's diff else the input.
- **No input traps.** A number that is not finite, is negative or is over 1e12 (a turn or a
  compaction over 48 h) counts as missing; strings such as "inf" or "1e400" too. Token sums
  saturate at `Int.max`. A date outside 2020–2100 counts as missing, so no interval spans centuries;
  an estimated turn over 48 h is left out, and spreading over hours stops at 48 h.
- **Low:** a compaction with no `postTokens` after the last reply leaves `context.now` nil
  (unknown). An API error with no timestamp keeps `at == .distantPast` and moves neither end of the
  session. When Claude Code's line total is used but no day counted any lines, `lines(of:)` splits it
  as Claude's working time fell over the days (else by replies, else evenly). A time zone change
  while Search runs drops the figures in memory and the cache's (its key holds the zone).

## Prices and windows

`Pricing` and `ContextWindows` are data in code, each with the date checked and its sources in the
comment: platform.claude.com's pricing page (read in a browser 2026-11-03), the claude-api skill of
Claude Code 2.1.316 (table cached 2026-10-06), and per-model pages for 4.5 models' windows. The page
and the skill differ once: Sonnet 5.5's cache read, $0.10 on the page and $0.20 in the skill; the
page wins. Cache writes are 1.25x (5 m) and 2x (1 h) input for every model; reads are 0.1x, except
0.025x (Fable 5.1, Mythos 5.1) and 0.05x (Opus 5.5, Sonnet 5.5). Haiku 5.5 bills a call whose prompt
(input + cache read + cache write) is over 100K on a higher card; Sonnet 4.5 and 4 calls over 200K
are left unpriced (the page states no premium for them). Fast mode, `inference_geo: "us"` (1.1x,
4.6 and later) and web searches ($10 per 1,000) are priced but were never seen. A model not in the
table is not estimated: `cost.unpriced` names it and the screens say so (none in the real data).
Window unknown (retired models): no percentage, "near the limit" from 800K tokens.

## The cache

`~/Library/Caches/<helper bundle ID>/usage.json`, never under ~/.claude. One entry per real
transcript path (and one `merged <id>` per ID filed twice) with the size and mtime of every file it
read; the file's key holds `UsageCache.version` (2 since the review), `Pricing.checked` and the
time zone (days and hours are local, Gregorian), so any of them changing rebuilds it.
`CLAWS_SEARCH_CACHE=<dir>` moves it, for timing a first read (`UsageCache.defaultFolder` ignores it).

## Measured (2026-11-03, Apple silicon, 10 cores, macOS 27.0.1, 542 sessions, 2.9 GB)

| Run | Time | Peak footprint |
| --- | --- | --- |
| First read (empty cache), `--usage-dump` | 2.0–3.4 s load (3.1 s after the review) | 108–115 MB (142 MB after: line markers for copies) |
| Reopen (cache), `--usage-dump` | 0.15–0.21 s load, 0.35 s in all | 72–75 MB |

A live session's transcript changes between loads and is read again (about 0.2 s for a 98 MB one).

## Cross-check

`tools/usage-crosscheck.py [--helper PATH | --dump FILE] [--cached]` runs `--usage-dump` (fresh
cache by default) and reads every transcript itself in Python: `json.loads` on every line, no
pieces, its own price table. It prints exact agreement per field, the mismatches (ID prefixes), the
estimates against Claude Code's current figures, the price-table check, and unpriced models. It
writes nothing; its output is about your sessions: never commit it. After the review (2026-11-03):
541 sessions compared (1 written during the check left out; the 7 IDs filed as several copies and
the linked transcript included, read the same way), **exact on all 15 fields**: replies, tokens,
tokens by model, subagents and their tokens, turns (count and source) and their seconds, tool
seconds, tools, compactions, API errors, context now, cost source, estimate, lines (added, removed,
source). No session has more tool time than working time, and the lines counted equal Claude Code's
own in all 212 records that cover their transcript. Estimates against Claude Code: within 3% for 191
of those 212 (90%; median −0.07%), and for 200 of all 257 current records (77%). The 21 covering misses are all underestimates (−3% to −29%) where Claude
Code counted more of every token kind than any transcript holds (fresh input 4–960x, cache writes
1.0–2.0x, cache reads 1.0–1.65x): calls it bills but never writes, which the transcripts cannot price
(inferred from the counts; which calls was not traced). The 44 current records that do not cover
their transcript differ by up to +783% (the estimate counts what the resumed process's counter
missed). No model in the real data lacks a price.

## Traps

- **A byte needle can match a nested object**: an Agent call's tool result embeds messages with
  `"type":"assistant"`. The needles only decide whether to decode; the decoded top-level `type`
  decides what a line is.
- **One session per job serialised everything**: a session can hold hundreds of workflow agents.
  Pieces of whole lines across all files fixed it (5.2 s to 2–3 s); holding every piece's events at
  once cost 347 MB, so changed sessions go in batches.
- **A hand-written scanner for tool-result lines was slower than `JSONDecoder`** (16.3 s against 15.1 s
  of CPU): this macOS's decoder only materialises the keys asked for. Removed.
- **Timestamps by hand**: Claude Code's `2026-11-02T10:00:00.000Z` is parsed without a formatter
  (`Timestamp`); anything else falls back to `ISO8601DateFormatter`.
- **`Calendar.current` may not be Gregorian**: days use `Calendar.usage` (Gregorian, your zone).
- **`NSTimeZone.default` did not change `TimeZone.current`** in-process: the cache takes its zone as
  a parameter, so the test can pass another one. A real zone change is not tested (it needs the
  system's), only the cache key.
- **`Int(someDouble)` traps** on anything out of range: one `1e19` in a transcript killed Search at
  every launch (the read starts when the model is created). Every number goes through
  `lenientNumber`/`lenientCount`; `Int(saturating:)` and `addingSaturating` elsewhere.
- **A listing spells the temporary folder `/private/var/…`, a link may say `/var/…`:** real files
  are compared by `realpath`, called only once the link's text is known to stay outside protected
  folders.

## Commands

```
H=".../Contents/Helpers/Claws Search.app/Contents/MacOS/ClawsSearch"
$H --usage <session id prefix>     # one session's figures, readably (title from Search's loader)
$H --usage-dump                    # every session's SessionUsage as JSON, ISO 8601 dates
$H --demo --usage …                # the made-up sessions' figures; nothing of yours is read
tools/usage-crosscheck.py          # the independent check above (needs ./build.sh --no-install)
```
