# 1.4 plan: usage in Search, and a Usage window

What each Claude Code conversation is using and costing: in Search's detail pane for one session,
and across all of them in a new Usage window. Fields were picked by the client from wireframes.

## Verified before planning (2026-11-03, Claude Code 2.1.316, 547 real transcripts)

- **A reply is written as several lines, each repeating the same `usage`.** One transcript: 2,015
  assistant lines for 845 replies (up to 5 lines each); output tokens summed per line 2.95M, per
  reply 1.09M. **Count each `message.id` once.**
- **Claude Code's `cost-state` record** (`totalCostUSD`, `modelUsage` per model with tokens and
  `costUSD`, durations, `totalLinesAdded/Removed`) is in 260 of 547 transcripts (47%); none of the
  oldest 60 have it. It includes subagents (main thread 1.10M + 6 subagents 1.44M output tokens, record
  2.24M). **It lags:** in one transcript the last record was written at 17:14 UTC while replies ran to
  00:06 (written around the session's process ending; inferred). One dip seen (75.55 → 73.60): use the
  last record, never assume it only grows.
- `modelUsage` has **no context window size**; transcripts never state it. Claude Code's own status
  line data has `context_window_size`, but under-reports on some providers (a 1M model shown as 200K).
- Context in use after a reply = that reply's `input_tokens + cache_read_input_tokens +
  cache_creation_input_tokens` (main thread, not subagents).
- Compactions: `system` / `compact_boundary` with `compactMetadata` (`trigger` auto|manual,
  `preTokens`, `postTokens`, `cumulativeDroppedTokens`, `durationMs`).
- Turn timings: `system` / `turn_duration` (`durationMs`); in 45 of the oldest 60 transcripts.
- Every assistant line has a `timestamp`.
- API errors: an `assistant` line with `isApiErrorMessage: true`, `error` (e.g. `rate_limit`), a
  timestamp, model `<synthetic>`, text "API Error: …". Found in 64 transcripts. `<synthetic>` is not
  a model: keep it out of per-model figures.
- Subagents: `<session>/subagents/*.jsonl`, same record shapes.
- Search already reads all 545 sessions in about 1.3 s plus 0.6 s to index.

## Decisions (client, 2026-11-03)

- **Cost:** Claude Code's figure when it is current (written after the session's last reply);
  otherwise an estimate from the session's own tokens (subagents included) and a built-in API price
  table, marked "est.". Always labelled "at API prices": on a plan it is not the bill.
- **Currency:** dollars, plus an opt-in second currency (default INR) at a live rate fetched at most
  once a day from a free exchange-rate service: off until turned on, the only network call besides
  recaps, and said so in the README's Privacy section.
- **Context %:** a built-in model → window table (like the client's status line); an unknown model shows
  tokens without a percentage, and "near the limit" then uses 800K.
- **Lines:** in the Usage window only (tile and column), not in the Search panel. Claude Code's
  figure when current, else counted from Edit/Write calls, marked "est.".

## Fields

**Search, the selected session's Usage section:** context now (bar, % of window), context over time
(per reply, compactions marked), compactions (when, how, before → after), cost, tokens (written by
Claude, read from cache, written to cache, fresh input), by model, cost per hour of Claude's work,
Claude worked (time across turns, tool time), turns (count, longest), tools used (counts),
subagents (count, tokens, cost), API errors (count, kinds, when).
**Search's list:** a context bar and the cost on each row; sort by cost or by context.

**Usage window:** filters (today, 7 days, 30 days, all time; project; model; find); tiles (cost,
written by Claude, Claude worked, sessions, lines changed, compactions); cost per day by project;
near the context limit (running sessions at 80% or more); all sessions (session, project, last active,
context, compactions, cost, written, Claude time, lines; sortable); by project; by model; when Claude
works (weekday × hour of Claude's working time); actions (open in Search, resume, copy ID, export
CSV). Opened from the crab menu (**Usage…**) and from a toolbar button in Search.

## Design

- **All of it runs in the search helper** (`Claws Search.app`): a second window, `Usage`, in the same
  process, so its memory is freed when its windows close and a crash never touches the Clawds.
  Resume keeps going through Claws (nonce, front window, folder pinned: the 1.3 rules).
- **`SessionUsage`**, one per transcript, is the contract between the reader and both screens:
  context now and per reply, compactions, tokens by kind and by model, cost (`claudeCode` or
  `estimate`), turn count and durations, tool counts, tool time, subagents, API errors, activity per
  weekday-hour, lines (`claudeCode` or `estimate`), last active, project folder. Phases 2 and 3 build
  against it and against demo data from day one.
- **`UsageReader`** streams a transcript once (skipping tool output, as Search's loader does), counts
  each reply once, folds in its subagents, and is pure and self-tested on synthetic transcripts.
- **`UsageCache`**: results on disk in the helper's own cache folder, keyed by each transcript's size
  and modification time, so a reopen reads only what changed.
- **`Pricing`** (dated API price table per model, cache write 5 m / 1 h and cache read included) and
  **`ContextWindows`** (model prefix → window): data in code, each with the date it was checked and
  its source.
- **`ExchangeRate`**: opt-in, daily, cached with its date; shown as "₹ at 94.12 (3 Nov)".
- Live sessions for "near the limit": read Claws' own session files (read-only).
- Charts: Apple's Swift Charts, no new dependency. Same Claws look as Search (clay, crab, contrast).

## Workstreams

| # | Work | Owner | Done when |
| --- | --- | --- | --- |
| 0 | Data check (above), decisions, this plan | PM | done |
| 1 | `SessionUsage`, `UsageReader`, `UsageCache`, `Pricing`, `ContextWindows`, demo usage data | Dev A | self-tests on synthetic transcripts; an independent script over all 547 real transcripts agrees exactly on tokens, turns, tools, compactions and errors; estimates within 3% of Claude Code's current figures; full first read ≤ 5 s, cached reopen ≤ 1 s |
| 2 | Search panel and list (fields above) | Dev B | renders every field from demo data and real data; sort works; contrast meets AA |
| 3 | Usage window, crab menu item, toolbar button, currency setting and rate | Dev C | every kept section; CSV export; demo-data screenshots for the README |
| 4 | Independent reviews, live walkthrough with the client, README, release 1.4.0 | PM | client sign-off |

Dev A goes first; B and C start against the `SessionUsage` contract and demo data, then switch to the
real reader. Shared files are merged by the PM.

## Rules for this release

The 1.3 rules hold (CLAUDE.md), plus:
- Never send anything to the installed or running Claws from a test; never script the real Ghostty.
- Real transcripts are read only; nothing personal goes into the repo (demo data for images and tests).
- Every figure that is not Claude Code's own is marked "est." in the UI.
