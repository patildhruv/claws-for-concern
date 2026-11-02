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
  (Resume)      sessionId, folder,     ├─ our nonce, Search in front, < 30 s old?  else refused
                nonce, token, sent     ├─ session still running?   ──▶ Tracker.open: its tab, as a Clawd click
                                       ├─ already opening, or opened < 15 s ago?  else refused
                                       ├─ the folder its transcript names?  ──▶ Terminals.newPane (Ghostty):
                                       │                                       a new tab there, typing the command
                                       └─ otherwise                ──▶ refused
             ◀── ResumeReply ──────────┘   focused | opening → opened | failed, plus one line of text
```

- Both notification names start with `io.github.patildhruv.claws-for-concern.` (`resumeSession`,
  `resumeSessionReply`). `Sources/Search/ResumeRequest.swift` defines them, the payload, its
  validation, Claude Code's folder names and its tests, and is **compiled into both binaries**.
- **The command** is Claws' Settings → General → Resume command (`resumeCommand`, `{id}` = the
  session ID; default `ResumeCommand.defaultTemplate`, `claude --resume {id}`). The helper reads it
  from Claws' UserDefaults domain for Copy Resume Command and the command it shows; Claws types
  `Settings.resumeCommand`. Claws' self-test hands its value to the helper's, which reads the domain
  its own way and compares.
- **Running** means the session's Claude process is alive. A session file with no process on record
  counts only if Claws knows its pane or the file changed in the last 5 minutes (such a file can
  otherwise linger 48 h and would turn Resume into "switch to a tab that is gone").
- **The folder is read back, not believed.** Claws finds `<id>.jsonl` in `~/.claude/projects` and takes
  the helper's own rule from it (`ProjectDirs.folder`): the last `relocated` record's folder, else the
  first recorded `cwd`, whichever encodes to that project folder, hash included. The request's folder
  must equal it exactly. Folders the helper found only by walking the disk are not resumable this way
  (20 of 545 on 2026-11-02; Copy Command still works).
- **Project folder names** for paths over 200 encoded characters end in `-` plus Claude Code's hash:
  `(h << 5) - h + unit` over the path's UTF-16 units, 32-bit, `Math.abs(h).toString(36)`. Read from
  the 2.1.316 bundle (two functions, `Zhe` and the encoder); the self-test checks three paths against
  values those functions produced in node. No such folder existed on this Mac to check against.
- **Duplicates**: one new tab per session at a time, and none for 15 s after one opened (by then the
  resumed session usually reports itself running, and a second Resume switches to it).
- **Stale requests**: Claws refuses one more than 30 s old (or 30 s ahead), and `Terminals.newPane`
  checks the same deadline again after a launch or a permission prompt, right before the script. A
  terminal Claws may already script and that runs skips the prompt thread entirely, so another app's
  unanswered prompt cannot hold it up.
- **A new tab** is opened only through an adapter's optional `newPane(in:typing:)` (docs/adapters.md).
  Ghostty: `new tab in front window with configuration {initial working directory:…, initial input:…
  & linefeed}`, or `new window` when it has none, in the adapter's own Ghostty (`--bundle-id` copies
  included). The command is typed into the login shell, so aliases resolve and the tab stays open
  afterwards. It never types into an existing terminal. A session that is no longer running has no
  terminal on record, so this is Ghostty.
- **When it cannot**: Claws not running, no answer within 2 s (an older Claws, or a hung one), no
  outcome within 30 s, or a `failed` reply: the helper puts `cd <folder> && <command>` on the
  clipboard and says so. Closing the window (or ⌘Q) with a request still waiting holds the quit up to
  3 s (`.terminateLater`) for the answer, then copies. It does not launch Claws: the request would race
  Claws' startup, and a launch can raise first-run prompts.
- **Return** right after typing waits for the results of what is in the field and resumes their first
  hit; until they arrive the selection still belongs to the old results. Typing again cancels it.
- Resume is greyed out, with the reason as its tooltip, for title-only stubs named
  `<uuid>.orphaned-<ms>-<hash>.jsonl` (3 of 545 on 2026-11-02; not session IDs, so no Copy Command
  either), for folders not recorded in the transcript, and for folders that no longer exist.

### Who can ask

A distributed notification can come from any process, so a resume request is checked by Claws:

- **A nonce.** Each helper Claws launches gets a random one as `--nonce`; Claws remembers it with that
  helper's process and forgets it when the helper quits. Requests without one Claws issued are
  refused. A helper already open when Claws restarts keeps an old nonce: it must be closed and opened
  again from the menu.
- **The Search window in front.** The frontmost app must be the helper inside this bundle (its bundle
  path) and the process that got the nonce. So a resume is something you just clicked in Search, not
  something that happens out of sight.
- **Under 30 s old**, and only for **the folder the session's transcript names**, with a **UUID**
  session ID; the command always comes from Claws' own settings.

What this does not stop, honestly: a process running as you, outside any sandbox, can read the
helper's command line (`ps`, which shows the nonce), `open` the helper itself, or rewrite
`resumeCommand` with `defaults write` so that the next resume runs something else. Such a process can
already run anything as you, so Search adds no new power for it; what changed is that a resume is now
visible and started by you, not silent. A sandboxed app is expected to fail the nonce and
front-window checks, since the App Sandbox normally keeps it from other processes' arguments and other
apps' preferences; that was not tested here.

## How it reads Claude Code's files

Verified by the original Session Search against the Claude Code 2.1.289 binary (2026-10-05). On
2026-11-02 (2.1.316) the self-test still resolves 543 of 545 sessions to their project folder.

- Transcripts: `~/.claude/projects/<encoded folder>/<session id>.jsonl`; subagents in
  `<session id>/subagents/*.jsonl`. Folder encoding: `path.replace(/[^a-zA-Z0-9]/g, "-")`, cut at
  200 characters plus `-` and a hash (`ProjectDirs.name`, see "Project folder names" above).
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

- **Never stat or list inside ~/Documents, ~/Desktop, ~/Downloads, iCloud (Mobile Documents and
  CloudStorage), other apps' Containers and Group Containers, or /Volumes** for a session's folder:
  even a stat makes macOS ask for permission on the helper's behalf. `Paths.isPrivacyProtected` guards
  the folder-exists check and `ProjectDirs.resolve`. A link along the path counts: each prefix is read
  with `lstat` and `destinationOfSymbolicLink` (which never follow a link), and only once the text
  says the whole path is outside every protected folder. Claws' folder check reads only inside
  `~/.claude/projects`. Reading `~/.claude` is fine.
- **`standardizingPath` looks on disk**: it turns an existing `/private/tmp/…` into `/tmp/…`, so the
  request's folder is checked for `.`, `..`, `//` and a trailing `/` by its components instead (two
  real projects here live under `/private`).
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
| `--selftest` (132 checks) | 5.0 s | 387 MB | 205 MB |
| Window (`--snapshot`: the real model and views, offscreen) | 7.3 s | 417 MB | 291 MB |

With the index built and the window drawn: about 195 MB footprint, 197 MB RSS (sampled 2 s after
indexing finished). Reading takes about 3 s, building the index about 0.5 s, a query a few ms.

## Commands

```
H="build/Claws for Concern.app/Contents/Helpers/Claws Search.app/Contents/MacOS/ClawsSearch"
$H --selftest                # unit checks + searches picked from your own transcripts (ALL PASS)
$H --search "words" [--limit N] [--recent] [--scope prompts,replies,tools,subagents]
$H --resume <id prefix>      # a resume request from the terminal: Claws must refuse it (see below)
$H --snapshot out.png [--query q]
```

`ClawsForConcern --selftest` runs the helper's self-test as a subprocess and reports it. `--resume`
sends the Resume button's request with a nonce Claws never issued, from a terminal rather than the
Search window, and prints the answers: a correct Claws replies `failed` ("not opened by this Claws
for Concern"); an older one (no handler) does not answer. Real resumes need the window Claws opened.
