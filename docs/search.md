# Search

Find any past Claude Code conversation by what was said in it, and resume it. Search is a separate
app inside the bundle, `Claws for Concern.app/Contents/Helpers/Claws Search.app` (SwiftUI, sources in
`Sources/Search/`), opened from the crab menu's **Search Sessions…**.

- **Its own process.** The index lives only while the window is open: the helper quits when its
  window closes (and quits by itself if no window came up within 3 s of launch). A crash there never
  takes the Clawds down.
- **A regular app while open**: Dock icon, ⌘W, ⌘Q, Edit menu. The menu bar app stays `LSUIElement`.
- **Bundle ID** `io.github.patildhruv.claws-for-concern.search`; build.sh copies the app's version into
  its Info.plist and signs it before the app (inside out). Its own preferences (Search In, Sort) live
  in that domain; it writes nothing else, and only reads Claws' `resumeCommand`.

## Resuming a session

The helper never scripts a terminal. It asks Claws for Concern, which already knows where every
running session is:

```
Claws Search ── ResumeRequest ──▶ Claws for Concern (SearchHelper)
  (Resume)      sessionId, folder,     │
                token                  ├─ session still running?  ──▶ Tracker.open: its tab, as a Clawd click
                                       ├─ filed under that folder? ──▶ Terminals.newPane (Ghostty): a new tab
                                       │                               in the folder, typing the resume command
                                       └─ otherwise                ──▶ refused
             ◀── ResumeReply ──────────┘   focused | opening → opened | failed, plus one line of text
```

- Both notification names start with `io.github.patildhruv.claws-for-concern.` (`resumeSession`,
  `resumeSessionReply`). `Sources/Search/ResumeRequest.swift` defines them, the payload, its
  validation and its tests, and is **compiled into both binaries** so the two sides cannot drift.
- **The command** is Claws' Settings → General → Resume command (`resumeCommand`, `{id}` = the
  session ID; default `claude --resume {id}`). The helper reads it from Claws' UserDefaults domain
  for Copy Resume Command and the command it shows; Claws uses `Settings.resumeCommand` to type it.
  The self-test checks both read the same value.
- **Any process on the Mac can post a distributed notification**, and the session ID gets typed into
  a shell. So Claws accepts only a UUID session ID and an absolute folder without control characters,
  and opens a tab only when `~/.claude/projects/<encoded folder>/<id>.jsonl` exists: the folder must be
  where Claude Code filed that session, which is also the only place `claude --resume` finds it. The
  command template comes from Claws' own settings, never from the notification.
- **Running sessions** (a session file whose Claude process is alive) are switched to, never resumed a
  second time.
- **A new tab** is opened only through an adapter's optional `newPane(in:typing:)` (docs/adapters.md).
  Ghostty: `new tab in front window with configuration {initial working directory:…, initial input:…
  & linefeed}`, or `new window` when it has none. The command is typed into the login shell, so
  aliases resolve and the tab stays open afterwards. It never types into an existing terminal.
  `Terminals.newPane` first launches the terminal if it is not running (without bringing it forward)
  and asks for the Automation permission if needed, both on the prompt thread; only the script runs on
  the worker. A session that is no longer running has no terminal on record, so this is Ghostty.
- **When it cannot**: Claws not running, no answer within 2 s (an older Claws, or a hung one), or a
  `failed` reply: the helper puts `cd <folder> && <command>` on the clipboard and says so. It does not
  launch Claws: the request would race Claws' startup, and a launch can raise first-run prompts.
- Resume is greyed out for title-only stubs named `<uuid>.orphaned-<ms>-<hash>.jsonl` (two records,
  `ai-title` and `agent-name`; 3 of 545 transcripts on 2026-11-02). They are listed, as before, but
  are not session IDs.

## How it reads Claude Code's files

Verified by the original Session Search against the Claude Code 2.1.289 binary (2026-10-05). On
2026-11-02 (2.1.316) the self-test still resolves 543 of 545 sessions to their project folder.

- Transcripts: `~/.claude/projects/<encoded folder>/<session id>.jsonl`; subagents in
  `<session id>/subagents/*.jsonl`. Folder encoding: `path.replace(/[^a-zA-Z0-9]/g, "-")`, cut at
  200 characters plus a hash suffix (`ProjectDirs`).
- **Name** precedence (the `/resume` list): `agentName || customTitle || aiTitle || summary || first
  prompt`. Each metadata record type is last-wins. `/rename` writes both `custom-title` and
  `agent-name`.
- **Folder**: Claude Code uses the last `relocated` record's `relocatedCwd`, else the first `cwd`.
  Branched and hand-moved sessions carry other folders' cwds, so the helper picks the recorded cwd
  that encodes to the project folder name, else walks the disk to decode it (`ProjectDirs.resolve`).
  `claude --resume <id>` only finds a session from that folder.
- First-prompt naming is approximated (`Prompts.display`): the built-in command list is copied by
  hand, not extracted. It only matters for sessions with no title records (about 10%).
- Only changed files are re-read (size and mtime), in parallel, biggest first.

## Search semantics

- Words are runs of letters, digits and marks; punctuation, `_` and em dashes split them (`Tokenizer`).
- Bare words: all must match (AND). Each matches indexed words exactly (1.0), as a prefix (0.6-0.9),
  with one typo from 4 letters (0.7), as a substring from 3 letters (0.5), or with two typos from 8
  letters (0.45). Adjacent swaps count as one typo.
- `"quoted words"`: in order, starting at a word boundary, case-insensitive; a space matches any run of
  spaces or punctuation, and the last word may be unfinished. `"one"` is that exact word, no fuzz.
- Names, folders, IDs and branches are always searched and weigh 1.6x.
- Search In (toolbar) narrows to prompts, replies, tool calls (commands, paths, edits) and subagents.

## Traps

- **Never stat or list inside ~/Documents, ~/Desktop, ~/Downloads, iCloud or /Volumes** for a session's
  folder: even a stat makes macOS ask for permission on the helper's behalf. `Paths.isPrivacyProtected`
  guards the folder-exists badge and `ProjectDirs.resolve`; Claws' folder check reads only inside
  `~/.claude/projects`. Reading `~/.claude` is fine.
- **Tool output is not indexed** (most of the bytes). Only prompts, replies, tool-call inputs and
  subagent transcripts. `SessionStore.wanted` skips lines without a user/assistant/title type before
  JSON decoding; `Block` never materialises `tool_result` text.
- **RSS overstates the index.** Transcripts are memory-mapped (`.alwaysMapped`), so clean file pages
  count in RSS while they are read; the footprint is the better measure (see below). Inferred from the
  gap between the two, not traced.
- `NSTableView … reentrant operation` once at launch comes from SwiftUI's own List diffing
  (`OutlineListCoordinator.diffRows`, confirmed by backtrace in the original), not from our code.
- **`--snapshot` renders offscreen**, so it never shows a window or takes focus. The selected row and
  the selected segment of the Sort control draw as solid black there; the real window is unaffected.

## Measured (2026-11-02, Apple silicon, macOS 27.0.1, 545 sessions, 2.7 GB of transcripts)

| Run | Wall time | Peak RSS | Peak footprint |
| --- | --- | --- | --- |
| `--search` (read, index, one query) | 3.3 s | 437 MB | 195 MB |
| `--selftest` | 4.5 s | 402 MB | 198 MB |
| Window (`--snapshot`: the real model and views, offscreen) | 7.3 s | 417 MB | 291 MB |

With the index built and the window drawn: about 195 MB footprint, 197 MB RSS (sampled 2 s after
indexing finished). Reading takes about 3 s, building the index about 0.5 s, a query a few ms.

## Commands

```
H="build/Claws for Concern.app/Contents/Helpers/Claws Search.app/Contents/MacOS/ClawsSearch"
$H --selftest                # unit checks + searches picked from your own transcripts (ALL PASS)
$H --search "words" [--limit N] [--recent] [--scope prompts,replies,tools,subagents]
$H --resume <id prefix>      # the Resume button's request to the running Claws; prints its answers
$H --snapshot out.png [--query q]
```

`ClawsForConcern --selftest` runs the helper's self-test as a subprocess and reports it. `--resume`
acts for real when the running Claws has the handler: it switches tabs or opens a Ghostty tab.
