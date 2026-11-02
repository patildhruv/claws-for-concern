# Claws for Concern

Native macOS menu bar app (AppKit, no dependencies) that shows a small animated Clawd in a screen
corner for each Claude Code session that needs you: blocked on a question, permission, plan or MCP
input, stopped on an API error, or finished while you were in another tab. Hover for a one-line
Claude Haiku recap, click to jump to its tab or pane (Ghostty, cmux, herdr, tmux, iTerm2, Terminal),
look at it and it leaves.

Public repo: github.com/patildhruv/claws-for-concern (MIT). See `docs/code-map.md` for files.

## Commands

```
./build.sh                  # build + install to /Applications (kills a running copy first)
./build.sh --no-install     # build only: build/Claws for Concern.app
UNIVERSAL=1 ./build.sh      # arm64 + x86_64, for releases
SIGN_IDENTITY="Apple Development: …" ./build.sh   # stable signature (see TCC below)
B="build/Claws for Concern.app/Contents/MacOS/ClawsForConcern"
$B --selftest               # must print ALL PASS (includes a byte-exact round trip of ~/.claude/settings.json
                            #   and the search helper's own self-test)
$B --recap "text"           # the app's recap code path, prints the line or the error
$B --fetch-art              # download + convert the Clawd GIFs now, print sprite sizes
$B --install-hooks | --remove-hooks | --hooks-status
$B --terminals              # each live session: its terminal adapter, pane, "looking at it"; adapter health
$B --open-session <id>      # the click path for one session (an ID prefix is enough)
$B --restore-status         # the restore ledger, the terminal's panes, and the verdict for each entry
$B --restore-run [--yes] [--command T]   # the app's restore, now (--yes: type without asking; else read-only)
$B --watch [--yes] [--seconds N] [--command T]   # tracker + restore without the UI; needs its own CLAWS_HOME
                            # (--bundle-id ID drives a Ghostty copy; --restore-on: as if Restore were on,
                            #  this process only; --assume-active S: you count as typing for S seconds;
                            #  --fail-typing: every typing script errors after its keys, to test it is
                            #  never retried; --no-ghostty-scripting: no Apple Events to Ghostty at all)
$B --displays               # each display's UUID and saved spot
$B --open-settings [TAB]    # opens the running app's Settings on a tab (distributed notification)
$B --clear-quarantine       # take com.apple.quarantine off the bundled search helper, as launch does
$B --snapshot DIR           # README renders; tools/make-readme-media.sh wraps it (needs ffmpeg)
$B --snapshot-settings DIR  # every Settings pane, offscreen (switches render "off" there: use the real window)
```

Plain `swiftc`, Swift 5 language mode, macOS 14+. Three binaries: the app (`-parse-as-library`,
`Sources/Shared` + `Sources/App/**` + `Sources/Search/{ResumeRequest,Brand}.swift`), the hook (`Sources/Shared` +
`Sources/Hook`, Foundation only) and the search helper (`-parse-as-library`, `Sources/Search/*.swift`).

## Non-negotiables

- **No Anthropic artwork in git or in builds.** Sprites are made at runtime by `Art` from GIFs on
  claude.ai. The public list (`Art.builtIn`) is only GIFs claude.ai itself references; anything else
  goes in the user's local `extra-art.txt`. The icon and menu bar crab are our own drawings (`PixelCrab`).
- **Never block Claude Code.** Every hook but SessionEnd is `async: true`; the hook never prints and
  always exits 0. SessionEnd is sync because async hooks can be torn down while the session exits.
- **Never block the main thread on Apple Events.** All terminal traffic (AppleScript and CLIs) goes
  through `ScriptThread` (`Terminals.worker`).
- **settings.json edits are byte-exact.** `OrderedJSON` keeps key order and number text and writes the
  same `JSON.stringify(v, null, 2)` format; install then remove must restore the file exactly.
- **No personal paths or aliases in Sources.** Personal preferences live in UserDefaults
  (`resumeCommand`) or the user's support folder.

## Verified facts (Claude Code 2.1.310, Ghostty 1.3.1, macOS 26.6, 2026-10-25)

- Stop input carries `last_assistant_message` (the docs say use it, not the transcript, which may lag)
  and `background_tasks`; subagent/workflow/teammate/cloud tasks wake the session again, so such a
  Stop is shown as `background`, not finished. StopFailure carries `error` and the rendered API error.
- Notification types that mean "needs you": `permission_prompt`, `elicitation_dialog`,
  `elicitation_url_dialog`, `agent_needs_input`. `idle_prompt` duplicates Stop.
- `UserPromptSubmit` also fires for turns Claude starts on its own, so tab capture checks folder/title.
- Direct edits to hooks in settings.json are picked up by running sessions (docs: file watcher).
- The native install runs as `~/.local/share/claude/versions/<version>`: the kernel process name is
  the version ("2.1.310"), not `claude`. `ProcInfo.claudeAncestor` matches the executable path.
- Ghostty's AppleScript: `every terminal` has `id`, `name` (the tab title, which Claude Code sets to
  "<status glyph> <session title>"), `working directory`; `focus (terminal id "…")` selects the tab.
  `tab` is a Ghostty class, so a tab *character* must be bound outside the `tell` block.
- Transcript title records: `{"type":"ai-title","aiTitle":…}`, `custom-title`/`customTitle`,
  `agent-name`/`agentName`; precedence agent > custom > ai, each last-wins.
- Every official Clawd GIF is a 55 x 37 art-pixel canvas (2750 x 1850 at 50 px, 1189 x 800 at ~21.6 px).
  ImageIO composites GIF frames: the Swift converter matched an ffmpeg pipeline in frame count, crop and timing for all 12 GIFs (pixels not diffed).

## Verified facts for Restore (Claude Code 2.1.316, Ghostty 1.4.0, macOS 27.0.1, 2026-11-02)

- Ghostty 1.4 `terminal` adds `tty` ("/dev/ttys014") and `pid` (the foreground process: claude while it
  runs, the login shell when idle), plus `input text … to`, `send key … to`, `close`, `new tab … with
  configuration {initial working directory:, initial input:}`. 1.3 has no `tty`/`pid`.
- Ghostty's `tty` equals the tty the hook records from the Claude process: all 14 live sessions mapped
  to the same terminal IDs as Ghostty's own `{id, tty}` listing.
- With `window-save-state = always`, terminal IDs survive quit + relaunch (titles do not). The default
  `default` follows macOS "Close windows when quitting", so Settings warns unless it is `always`
  (`ghostty +show-config --no-pager` prints only changed keys; absent means `default`).
- SessionEnd `reason` values in the 2.1.316 schema: `clear`, `resume`, `logout`, `prompt_input_exit`,
  `other`. Observed: Cmd-Q of Ghostty, Cmd-W (`close` of the terminal) and SIGTERM to claude all give
  `other`; Ctrl-C twice at an empty prompt gives `prompt_input_exit`; `/exit` gives
  `prompt_input_exit`. Ctrl-D at an empty prompt (three presses) did not end the session at all.
  `kill -9` sends nothing (the tracker reaps it as `vanished`). The SessionEnd hook runs on quit.
- `input text` + `send key "enter"` into a reopened terminal ran `claude --resume <id>` in its folder:
  the same session ID came back from a new process. `send key` with `modifiers "control"` needs a
  `press` and a `release` once Claude Code runs (a lone press did nothing). Ctrl-E then Ctrl-U (press +
  release) cleared text on both sides of the cursor in a reopened bash tab (`echo LEFT RIGHT`, cursor
  moved back 5 with Ctrl-B) before the command was typed. `send key` knows no "left" or "arrow_left".
- Ghostty's own default shell comes from passwd, not `SHELL` in its environment; `command = /bin/bash`
  still runs it under `login`. With that bash, reopened tabs started in the home folder, not the
  session's (they were refused); `working-directory` in the config fixed it. `window-save-state =
  never` still reopened the tabs saved by an earlier `always` run.
- Ghostty's `pid` is the terminal's foreground process group (its leader): the login shell when idle
  (parent `login`, which runs as root under Ghostty); a script waiting on `read` (a zsh whose parent is
  the login shell); for `sleep 300 | cat`, `sleep`, not `cat`.
- Ghostty's restored windows reopen with the tab that was selected at quit selected again.
- **Cmd-Q of Ghostty 1.4 with claude running** (8 sessions, 3 MCP servers each, 3 windows): every tab
  counts as a window, so it asks "You have 8 windows with running processes…" (Review Windows… is the
  default, then Terminate Processes, Cancel); Review asks "Quit Ghostty?" on each tab in turn. Nothing
  under Ghostty dies before the Ghostty process exits; all of it is gone 0.62–0.73 s after. No run left
  it windowless. With Clawds up and Ghostty in front, Claws keeps asking for the focused tab (one
  query, 6 Apple Events) every second through the whole quit: exit times matched runs without Claws
  and with `--no-ghostty-scripting` (9.7–9.9 s, set by the confirmations; 0.24 s with no
  confirmation). Measured with real key events posted to the copy's pid, no Apple Events.
- `CGEventSource.secondsSinceLastEventType(.combinedSessionState, .keyDown)` tracks real keystrokes
  without the Input Monitoring permission (8.1 s for keystrokes against 2.8 s for any input, no
  prompt). Zero-distance pointer events posted to the HID tap reset only "any input": a focused tab
  was typed into while the pointer had moved 0.1 s earlier.

## Traps (each cost real time)

- **`claude -p` for recaps**: `--bare` skips hooks but refuses OAuth (API key only), so use
  `--setting-sources project` from an empty folder instead (no user hooks, plugins or CLAUDE.md).
  Without `MAX_THINKING_TOKENS=0` Haiku thinks for ~30 s and 4k tokens; with it ~3 s and ~25 tokens.
  Frame the text in `<stopped>` tags or Haiku answers the message instead of recapping it.
- **`open` from a terminal passes that shell's environment to the app.** Launched from inside a Claude
  Code session, the recap child inherited `CLAUDECODE`, `CLAUDE_CODE_*` (messaging socket, child
  session) and hung for minutes ignoring SIGTERM. `Summarizer` strips those, pins `PWD`, reads stderr
  concurrently and escalates to SIGKILL. Test launches: `env -i HOME=$HOME USER=$USER open …`.
- **AEDeterminePermissionToAutomateTarget blocks while the consent prompt is up, even with
  askUserIfNeeded false.** On the main thread it froze the app: recaps finished but their main-queue
  callbacks never ran. Hence `ScriptThread` and the focus snapshots in `Terminals` (`lookedAt`,
  `focusedPane`).
- **TCC keys the Automation grant to the code signature.** Ad-hoc builds ask for terminal access again
  after every rebuild; build with `SIGN_IDENTITY` locally. Quitting the app from a script with an
  AppleScript `quit` needs Automation for the caller, so build.sh uses `pkill -x`.
- **NSTextField `.byTruncatingTail` disables wrapping.** The recap label uses word wrap plus
  `truncatesLastVisibleLine`, and BubbleView measures text with TextKit, not the field's own sizing.
- **Two settings.json edits in one second** collided on the backup name and aborted the second edit;
  backups now get a counter.
- **Pixel art must land on whole device pixels.** `OverlayController.artPoints` snaps the size to the
  screen's backing scale; layers use nearest-neighbour filtering. There is no "tiny" size for this reason.
- **A drag across displays could leave the strip's window undrawn on one display for good** (macOS
  27.0.1, laptop 2x + external 1x): listed on screen, full opacity, layers intact, nothing composited.
  Reproduced every time by dragging from the external's bottom-left corner to the laptop, then
  following the pointer back. Re-ordering the window did not help; a new window did, so
  `OverlayController.freshPanel()` runs on every follow move and after any drag that touched another
  display. Bare test panels never broke, so the cause inside macOS is unknown.
- Gatekeeper: releases are ad-hoc signed, not notarized; README tells users to right-click → Open.
  The nested search helper keeps its own quarantine mark: Claws removes it at launch
  (`SearchHelper.clearQuarantine`), and a helper that still will not open gets an alert with the
  `xattr -dr` command, never silence. The mark does not affect `codesign --verify --deep --strict`.
  This Mac has Gatekeeper's assessment off (`spctl`: `override=security disabled`): the refusal itself
  can only be tested on another Mac.
- **A tty is reused once its terminal closes.** `TTYMap` trusts a tty → terminal sighting only if it
  was made after the session's Claude process started; a full listing replaces the map.
- **Test restore against a copy of Ghostty, never the real one** (it runs the user's sessions): a
  `ditto` copy with its own `CFBundleIdentifier`, ad-hoc signed, launched with `env -i` and its own
  `XDG_CONFIG_HOME`, driven with `--bundle-id`. Test sessions: `claude --setting-sources project,local
  --settings <scratch file with our hooks>` with `CLAWS_HOME` set, so the real hooks and the real Claws
  never see them. A fresh copy raises the Automation prompt again. Its reopened windows come back
  under that bundle ID from an earlier run: not stored in `~/Library/Preferences` or `var/folders`
  (location not found; `~/Library/Saved Application State` does not exist on macOS 27).
- **A test build shares the installed app's UserDefaults** (same bundle ID): its `restore` switch,
  resume command and the rest. Never write them from a test; `--restore-on` turns Restore on in the
  test process only. Never send anything to the installed or running Claws from a test.
- **`print` from the CLI to a file is block-buffered**: `--watch` looked silent. `RestoreCLI` line-buffers stdout.
- **Telling an app that is not running anything launches it** (`tell application id …`). Every
  restore query and typing call checks `isFinishedLaunching` first, and every Ghostty script body is
  wrapped in `if application id … is running` (that check off the main thread can lag a quit).

## Terminal adapters (`Sources/App/Terminals/`, guide: docs/adapters.md)

- One file per terminal behind `TerminalAdapter`. `Terminals.adapters` order decides who claims a
  session: multiplexers first, and cmux before Ghostty (cmux shells say `TERM_PROGRAM=ghostty`).
- The hook records an **allow-list** of environment variables (`TerminalContext.keys`) plus the Claude
  process's tty. Never prefixes: cmux puts `CMUX_SOCKET_CAPABILITY` (a token) in every shell.
- All adapter I/O runs on `Terminals.worker`. Polling happens only for adapters with Clawds up or a
  session at work; a prompt triggers one immediate poll so Ghostty can learn the tab you typed in.
- **Permission prompts run on `Terminals.prompter`, never the worker.** An unanswered prompt blocks its
  thread for as long as you are away; on the worker (1.2.0) it stalled every terminal's polling and
  clicks. A click on a terminal we may not script asks there and only activates the app this time.
- Verified 2026-10-25, tmux 3.8, herdr 0.9.5, cmux 0.65.2:
  - **tmux**: pane from `TMUX_PANE`, server socket = first field of `TMUX`. `list-clients -F
    '#{pane_id}'` gives each client's active pane; "looking" = that client's host app is in front.
    Jump = `switch-client -c <tty> -t <pane>` + `select-window` + `select-pane`.
  - **herdr**: `HERDR_PANE_ID` + `HERDR_SOCKET_PATH`. `agent list` states: `done` only while the pane
    is not visible in any attached client, `idle` once seen; with no client attached a finished agent
    goes straight to `idle`, so "seen" is only trusted while a client (a `herdr` process with a tty)
    runs. `agent focus <pane>` focuses and marks seen.
  - **cmux** (`com.cmuxterm.app`): `CMUX_WORKSPACE_ID` + `CMUX_SURFACE_ID` (UUIDs, the same ones
    `identify --json --id-format uuids` and `focus-panel --panel X --workspace Y` use). Default socket
    mode `cmuxOnly` refuses any process not started inside cmux, even `cmux settings`; the adapter
    then degrades to "bring cmux forward" and Settings explains the Automation mode switch. Our hooks
    still fire under cmux's own Claude wrapper.
  - **iTerm2 / Terminal**: matched by the session's `tty` (iTerm2 `tty of session`, Terminal `tty of
    tab`). Both need Automation; the app asks the first time one of their sessions gets a Clawd.
    Scripts compile against the dictionaries in `--selftest`; not exercised live (needs consent).
- **Ghostty 1.4+** (verified 2026-11-02): the listing and the focused-tab query ask for `tty` too; the
  adapter keeps a `TTYMap` that `paneID(for:)` reads on the main thread, and the tracker stores the
  result like a learned pane so it survives an app restart. The tracker lists Ghostty once for each
  new session without a pane (restore needs every session's tab, not only those with a Clawd). If the
  query with `tty` fails where the old one answers (1.3), that Ghostty process gets the old learning path.

## Restore (`Sources/App/Restore.swift`, guide: docs/adapters.md "Restore")

- The hook keeps a session marked ended (`end_reason`, `ended_ts`) unless SessionEnd's reason is
  deliberate (`HookEvent.deliberateEnds`); after that only a SessionStart (or a new process) revives
  it. It also records the terminal process the session runs under (`host_pid`, `host_start`: the
  Claude process's ancestor directly under launchd). The tracker moves ended sessions, and sessions
  whose process vanished (`reason: vanished`, ended = last update), into `restore.json` with their
  tty-confirmed pane (`Meta.exact`, never a learned one), then deletes the file under the hook's lock
  (non-blocking; skipped if the hook rewrote it). Nothing is recorded while Restore is off.
- **The rule, by process** (`RestorePlan.verdict`, checked when planning and again before typing):
  (a) the session's terminal process is dead, (b) the running Ghostty launched after the session
  ended, (c) Claws saw that launch or started ≤ 2 min after it, (d) the tab's shell started ≤ 60 s
  after it; then the tab exists under the entry's pane ID, its foreground is the tab's own login
  shell (`RestorePane.problem`: shell, our uid, its parent a root `login` started by this Ghostty or
  Ghostty itself, pgid = tty's foreground group, on the pane's tty), and that shell's kernel cwd
  equals the session's folder (no stat or realpath on project folders). A `read` inside the login
  shell's own startup files cannot be told apart from its prompt: the shell itself is what waits.
- **Each entry gets exactly one launch.** A launch that settles decides: resumed, refused, or not
  reopened, everything that ended before it goes. A launch that never settles (gave up at 30 s,
  e.g. no Automation grant) or reopens none of the remembered tabs decides nothing, but stamps those
  entries with it (`launch`), so the next launch drops them. A launch Claws missed drops them at once.
  Also gone: entries whose session runs again, whose pane hosts another session, whose terminal still
  runs 12 s after the end (also checked at start), after Not Now or a resume, and after 7 days.
- On Ghostty's launch (`isFinishedLaunching`; a quit cancels the wait through a generation number)
  `Restorer` polls once a second: the fast path (same list twice, every remembered tab at its shell)
  needs a remembered tab present; else unchanged 5 s (10 s with none present); gives up at 30 s. It
  asks in a non-activating floating panel (titles and folders, 5 then "and N more") that closes itself
  after 2 minutes, unless `restoreWithoutAsking`.
- **Typing, one tab at a time, decided right before** (`RestorePlan.step`): list again from this
  launch's Ghostty process (`Launch.pid`; another process, or no answer: wait). Then one script does
  the rest, so nothing changes between its checks and its keys: "moved" unless `pid of t` is still
  the checked shell; if you pressed a key in the last 3 s (read just before it; moving the pointer or
  clicking Resume does not count), "busy" while Ghostty is frontmost with that tab focused; else
  Ctrl-E, Ctrl-U (each press + release; bash and fish kill only left of the cursor), the command,
  Return, "ok". "moved"/"busy" sent nothing and retry every 2 s for up to 2 minutes; an error or a
  timeout may have sent keys, so that tab is forgotten, never retried (`TypeResult`).
- **Known limits.** A vi keymap ignores Ctrl-E/Ctrl-U, so text already on the line can mangle the
  typed one (nothing of ours runs but the resume command). `if application id … is running` is
  checked once per script: a quit between that check and the next event is not covered. Two `--yes`
  test runs on one scratch home share its ledger and may both act on it.
- An entry `remember`ed while its terminal already runs again (a late SessionEnd, a reap after that
  launch's restore looked) is stamped with that launch at once. Switching Restore off empties the
  ledger (Claws stops watching launches). The hook records the host only with a new Claude process.
- **Sessions already running at the upgrade to 1.3 have no host in their files** (the 1.2 hook never
  wrote one, and an idle session sends no events), so the first real Cmd-Q remembered 2 of 15. The
  tracker backfills: for a live session with no host it walks up from its live Claude process (as
  the hook does) once per process, into `Meta.hostPid` (app state, never the hook's file), and uses
  `effective(s)` (`s.hostPid ?? meta`) everywhere, the tty-map check and `retire` included; `raw`
  keeps the files as written, for removing them safely. What the app works out (host, tty-confirmed
  pane) counts only for the Claude process it was found for (`hostLookedUp`, `paneFor`): a resume
  is a new process, possibly elsewhere. A session with only a learned pane (1.2 app state has
  those) still gets a listing (`Backfill.needsListing`): only that confirms its tab by tty.
  **Never silent**: `retire` and `remember` log every session not remembered, with why (not
  restorable there, terminal unknown, tab never matched by tty, Restore off). Upgrade simulated on a
  test copy (3 windows, 6 sessions, 1.2 files and 1.2 app state): 6 remembered, 6 resumed.
- Every Ghostty script body sits inside `if application id … is running`: NSRunningApplication read
  off the main thread can lag a quit, and telling a quit app anything relaunches it.
- Ghostty's tty map stores the Ghostty pid with each sighting and answers only for the session's own
  `host_pid` (a relaunched Ghostty reuses ttys); retiring prefers the stored `Meta.exact` pane.
- `restore.json` changes only under `restore.lock` (flock, re-read inside); IDs must be UUIDs
  (`ResumeRequest.isSessionID`) on remember, load and typing. `--restore-run` without `--yes` writes
  nothing, not even to claws.log; with `--yes` it refuses while Claws runs unless `CLAWS_HOME` is set.
  `--watch` refuses without its own `CLAWS_HOME` (same device and inode counts as the same folder).

## Search (`Sources/Search/`, guide: docs/search.md)

- A separate app inside the bundle, `Contents/Helpers/Claws Search.app`, opened by the crab menu's
  "Search Sessions…" (`SearchHelper.open`). It quits when its window closes, so its index (peak about
  420 MB RSS / 290 MB footprint for 545 sessions) never lives in the always-running app.
- Resume never scripts a terminal from the helper: it posts `…claws-for-concern.resumeSession`;
  `SearchHelper` switches to a running session through `Tracker.open`, else opens a Ghostty tab in the
  session's folder with `Terminals.newPane` and types `Settings.resumeCommand`, then answers with
  `…resumeSessionReply`. No answer within 2 s, no outcome within 30 s, or a failure: the helper
  copies the command instead (also when its window closes with a request still waiting, up to 3 s).
- `Sources/Search/ResumeRequest.swift` is compiled into both binaries: the payload, its validation,
  Claude Code's folder names (hash included) and its tests. **Any process can post that
  notification**, so Claws needs the nonce it gave the Search window it launched (`--nonce`), that
  window in front, a request under 30 s old, a UUID, and exactly the folder it reads back from the
  session's own transcript; at most one new tab per session per 15 s. What that does not stop (a
  process running as you can still `open` the helper or rewrite `resumeCommand`): docs/search.md.
- **The helper must never stat or list inside ~/Documents, ~/Desktop, ~/Downloads, iCloud, cloud
  storage, other apps' containers or /Volumes**, through a symlink either (privacy prompt):
  `Paths.isPrivacyProtected` reads links with `lstat`, never following them. Reading `~/.claude` is fine.
- **Looks like Claws** (docs/search.md "Look"): "Claws Search", window "Search Sessions"; clay only for
  the selection, Resume, "You" and matches, in shades that meet WCAG AA (AAA with Increase Contrast);
  empty states are our crab in the Clawds' bubble. `Sources/Search/Brand.swift` (both binaries) holds
  `PixelCrab`, the colours and the bubble style. A split view, not a sidebar: a translucent sidebar's
  vibrant text has no contrast we can promise, and renders wrong offscreen.
- **`--demo` never reads your ~/.claude**: made-up sessions in a temporary home (`Paths.home`), the
  default resume command, nothing resumed; the self-test asserts on every path the loader opens. The
  README images (`docs/media/search-*.png`) are `--demo --snapshot`, via tools/make-readme-media.sh.
- Commands (`H=".../Contents/Helpers/Claws Search.app/Contents/MacOS/ClawsSearch"`): `$H --selftest`,
  `$H --search "words" [--limit N] [--recent] [--scope …]`, `$H --resume <id prefix>` (a request from
  the terminal, which Claws must refuse), `$H --snapshot out.png [--query q] [--appearance light|dark]`
  (offscreen, takes no focus), and `--demo` with any of them.

## Settings, placement, the Dock

- Every preference is a UserDefaults key in `Settings.Key`; the Settings window binds the same keys with
  `@AppStorage`, so defaults in `Settings` and in the panes must match. AppDelegate coalesces
  `UserDefaults.didChangeNotification` into one `.settingsChanged`. That notification only fires for
  changes made in this process: `defaults write` from a shell is picked up on the next relayout.
- The Clawds may use the whole display (`NSScreen.clawdArea`): the full frame minus the menu bar, so
  corners and the Dock's strip are allowed; `visibleFrame` stopped them above the Dock. The
  `avoidDock` setting brings `visibleFrame` back.
- The strip's spot is stored per display (`Placements`, keyed by the display UUID from
  `CGDisplayCreateUUIDFromDisplayID`). A spot is a corner or a fraction of the visible frame for the
  leading Clawd. `StripGeometry` (pure, self-tested) lays out cells from it and flips the growth
  direction when the right side would run off-screen.
- Animated relayouts set the panel to the union of the old and new strip rects first, so cells never
  clip mid-flight, then shrink it back (`settle`). A generation counter drops stale completions.
- **NSHostingController in an NSTabViewController needs `sizingOptions = .preferredContentSize`**, or the
  window ignores the pane size and clips it. 680 pt fits all eight toolbar tabs without an overflow menu.
- The app is `LSUIElement`; opening Settings switches to `.regular` (Dock icon, menu bar with Edit so
  copy/paste work in text fields) and closing it switches back to `.accessory`.
- 1.0 stored `screen = mouse`; launch migrates it to `follow`, or the display picker shows nothing.

## Data

`~/Library/Application Support/Claws for Concern/`: `sessions/<id>.json` (hook-written state, one per
live session, `.lock` for flock; an ended one waits there for the app), `app-state.json` (tab mapping,
what was seen, recap cache), `restore.json` (the restore ledger, app-only, not pruned with
app-state), `art/` (sprites.json + PNG strips), `extra-art.txt`, `summarizer/` (empty cwd), `claws.log`
(restore steps are logged as `restore: …`).
Session ownership: the hook records the Claude process that started a session (`claude_pid`) and
ignores events from any other live Claude process under the same ID: a `claude` run inside a session
inherits `CLAUDE_CODE_SESSION_ID`, and its events once reset this session's state.
UserDefaults domain `io.github.patildhruv.claws-for-concern`.
