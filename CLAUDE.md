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
$B --selftest               # must print ALL PASS (includes a byte-exact round trip of ~/.claude/settings.json)
$B --recap "text"           # the app's recap code path, prints the line or the error
$B --fetch-art              # download + convert the Clawd GIFs now, print sprite sizes
$B --install-hooks | --remove-hooks | --hooks-status
$B --terminals              # each live session: its terminal adapter, pane, "looking at it"; adapter health
$B --open-session <id>      # the click path for one session (an ID prefix is enough)
$B --displays               # each display's UUID and saved spot
$B --open-settings [TAB]    # opens the running app's Settings on a tab (distributed notification)
$B --snapshot DIR           # README renders; tools/make-readme-media.sh wraps it (needs ffmpeg)
$B --snapshot-settings DIR  # every Settings pane, offscreen (switches render "off" there: use the real window)
```

Plain `swiftc`, Swift 5 language mode, macOS 14+. Two binaries: the app (`-parse-as-library`,
`Sources/Shared` + `Sources/App/**`) and the hook (`Sources/Shared` + `Sources/Hook`, Foundation only).

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
live session, `.lock` for flock), `app-state.json` (tab mapping, what was seen, recap cache),
`art/` (sprites.json + PNG strips), `extra-art.txt`, `summarizer/` (empty cwd), `claws.log`.
Session ownership: the hook records the Claude process that started a session (`claude_pid`) and
ignores events from any other live Claude process under the same ID: a `claude` run inside a session
inherits `CLAUDE_CODE_SESSION_ID`, and its events once reset this session's state.
UserDefaults domain `io.github.patildhruv.claws-for-concern`.
