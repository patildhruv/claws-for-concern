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
  one entry per session ID; `usage(forTranscript:)` / `byTranscript` give each transcript its own
  when one ID is filed under two project folders (8 of 549 here; the ID map keeps the newer copy).
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
  across sessions (a reply ID already in an earlier-started transcript is a copy). Decision open.
- **One session ID filed under two project folders** (8 IDs, 1,350 shared replies): two copies of one
  conversation. The ID map keeps one; a sum over `byTranscript` counts both.
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
  transcripts: 6,804 records against 8,550 prompts. Without any, a turn is estimated from a prompt
  to the last main-thread reply before the next one. Subagents write `turn_duration` too (ignored).
- **API errors:** `assistant` lines with `isApiErrorMessage`, model `<synthetic>`, `error`
  (`server_error` 74, `rate_limit` 47, `invalid_request` 21, `unknown` 17, `authentication_failed`
  10, `oauth_org_not_allowed` 2, `billing_error` 2), `apiErrorStatus` in 68, text "API Error: …";
  counted once per `message.id`. `system`/`api_error` (156) are retry notices, not counted.
- **Lines:** Claude Code's own diff is in the tool result: `toolUseResult.structuredPatch` hunks
  (lines starting `+`/`-`), or `type: "create"` with the file's `content`, counted as
  `split("\n")` (a final newline starts one more line). That reproduces `totalLinesAdded/Removed`
  exactly in 235 of 262 records; the rest are per-process records. An Edit or Write with no such
  result falls back to its input (shared head and tail lines set aside).
- **Usage fields seen:** `speed` only `standard`, `inference_geo` `global`, `not_available` or
  empty, `server_tool_use` never non-zero, `cache_creation` split into `ephemeral_5m/1h` on every
  reply (1-hour writes are most of the main thread's). `usage.iterations` had two entries once.
- **Tool results are half of all bytes** (1.36 GB of 2.85 GB in main transcripts' user lines).

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

`~/Library/Caches/<helper bundle ID>/usage.json`, never under ~/.claude. One entry per transcript
path with the size and mtime of the transcript and each subagent file; the file's key holds
`UsageCache.version`, `Pricing.checked` and the time zone (days and hours are local, Gregorian), so
any of them changing rebuilds it. `CLAWS_SEARCH_CACHE=<dir>` moves it, for timing a first read.

## Measured (2026-11-03, Apple silicon, 10 cores, macOS 27.0.1, 542 sessions, 2.9 GB)

| Run | Time | Peak footprint |
| --- | --- | --- |
| First read (empty cache), `--usage-dump` | 2.0–3.4 s load, 4.1 s with the dump | 108–115 MB |
| Reopen (cache), `--usage-dump` | 0.15–0.17 s load, 0.3 s in all | 72 MB |

A live session's transcript changes between loads and is read again (about 0.2 s for a 98 MB one).

## Cross-check

`tools/usage-crosscheck.py [--helper PATH | --dump FILE] [--cached]` runs `--usage-dump` (fresh
cache by default) and reads every transcript itself in Python: `json.loads` on every line, no
pieces, its own price table. It prints exact agreement per field, the mismatches (ID prefixes), the
estimates against Claude Code's current figures, the price-table check, and unpriced models. It
writes nothing; its output is about your sessions: never commit it. On 2026-11-03: 533 sessions
compared (1 written during the check and 8 filed twice left out), **exact on all 13 fields** (replies,
tokens, tokens by model, subagents and their tokens, turns and their seconds, tools, compactions,
API errors, context now, cost source, estimate). Estimates against Claude Code: within 3% for 191
of the 212 sessions whose record covers the transcript (90%; median −0.07%), and for 200 of all
256 current records (78%). The 21 covering misses are all underestimates (−3% to −29%) where Claude
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
  a parameter, so the test can pass another one.
- **One ID in two project folders**: which copy the ID map keeps must not depend on dictionary order
  (newest, then most replies, then folder name).

## Commands

```
H=".../Contents/Helpers/Claws Search.app/Contents/MacOS/ClawsSearch"
$H --usage <session id prefix>     # one session's figures, readably (title from Search's loader)
$H --usage-dump                    # every session's SessionUsage as JSON, ISO 8601 dates
$H --demo --usage …                # the made-up sessions' figures; nothing of yours is read
tools/usage-crosscheck.py          # the independent check above (needs ./build.sh --no-install)
```
