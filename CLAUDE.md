# Claws for Concern

Native macOS menu bar app (AppKit, no dependencies) that shows a small animated Clawd in a screen
corner for each Claude Code session that needs you: blocked on a question, permission, plan or MCP
input, stopped on an API error, or finished while you were in another tab. Hover for a one-line
Claude Haiku recap, click to jump to the Ghostty tab, look at the tab and it leaves.

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
$B --snapshot DIR           # README renders; tools/make-readme-media.sh wraps it (needs ffmpeg)
```

Plain `swiftc`, Swift 5 language mode, macOS 14+. Two binaries: the app (`-parse-as-library`,
`Sources/Shared` + `Sources/App`) and the hook (`Sources/Shared` + `Sources/Hook`, Foundation only).

## Non-negotiables

- **No Anthropic artwork in git or in builds.** Sprites are made at runtime by `Art` from GIFs on
  claude.ai. The public list (`Art.builtIn`) is only GIFs claude.ai itself references; anything else
  goes in the user's local `extra-art.txt`. The icon and menu bar crab are our own drawings (`PixelCrab`).
- **Never block Claude Code.** Every hook but SessionEnd is `async: true`; the hook never prints and
  always exits 0. SessionEnd is sync because async hooks can be torn down while the session exits.
- **Never block the main thread on Apple Events.** All Ghostty traffic goes through `ScriptThread`.
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
  callbacks never ran. Hence `ScriptThread` and the 1 s focus snapshot (`Ghostty.focusedTerminal()`).
- **TCC keys the Automation grant to the code signature.** Ad-hoc builds ask for Ghostty access again
  after every rebuild; build with `SIGN_IDENTITY` locally. Quitting the app from a script with an
  AppleScript `quit` needs Automation for the caller, so build.sh uses `pkill -x`.
- **NSTextField `.byTruncatingTail` disables wrapping.** The recap label uses word wrap plus
  `truncatesLastVisibleLine`, and BubbleView measures text with TextKit, not the field's own sizing.
- **Two settings.json edits in one second** collided on the backup name and aborted the second edit;
  backups now get a counter.
- **Pixel art must land on whole device pixels.** `OverlayController.artPoints` snaps the size to the
  screen's backing scale; layers use nearest-neighbour filtering. There is no "tiny" size for this reason.
- Gatekeeper: releases are ad-hoc signed, not notarized; README tells users to right-click → Open.

## Data

`~/Library/Application Support/Claws for Concern/`: `sessions/<id>.json` (hook-written state, one per
live session, `.lock` for flock), `app-state.json` (tab mapping, what was seen, recap cache),
`art/` (sprites.json + PNG strips), `extra-art.txt`, `summarizer/` (empty cwd), `claws.log`.
UserDefaults domain `io.github.patildhruv.claws-for-concern`.
