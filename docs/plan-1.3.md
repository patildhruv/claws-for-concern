# 1.3 plan: one app for Clawds, search and restore

Claws for Concern grows from "Clawds for sessions that need you" into the one place for your Claude
Code sessions:

1. **Clawds** (today): a Clawd for each session that needs you.
2. **Search**: find any past conversation by what was said in it, and resume it.
3. **Restore**: when your terminal relaunches and brings its tabs back, the conversations that were
   running in them come back too.

Ghostty first. Restore and exact tab matching go through the terminal adapters, so anyone can add
their terminal (docs/adapters.md).

## Verified before planning (2026-11-02: Ghostty 1.4.0, Claude Code 2.1.316, macOS 27.0.1)

Tested with a throwaway copy of Ghostty under its own bundle ID, its own config and saved state
(`window-save-state = always`), so the real Ghostty and its sessions were never touched.

- **Ghostty keeps terminal IDs across a relaunch.** Three tabs, three quit-and-relaunch cycles: every
  `id of terminal` came back identical, with its working directory. Titles do not come back.
- **Ghostty 1.4 exposes `tty` and `pid` per terminal.** `tty` equals the tty the hook records from the
  Claude process, so a session maps to its tab exactly; `pid` is the terminal's foreground process
  (the `claude` process while it runs, the shell when idle). Ghostty 1.3 has neither.
- **SessionEnd says why a session ended.** Quitting Ghostty: `reason: "other"`. Typing `/exit`:
  `reason: "prompt_input_exit"`. The hook still runs when the terminal is quit.
- **Typing into a restored tab works.** `input text` + `send key "enter"` into a restored terminal
  ran `claude --resume <id>` in that tab's folder; SessionStart reported `source: "resume"`.
- **`window-save-state`** defaults to `default` (follow macOS "close windows when quitting"). Restore
  needs Ghostty to bring its tabs back: Settings must say so when it is not `always`.
- **Trap: launching an app from inside a Claude session passes `CLAUDECODE` / `CLAUDE_CODE_*` on.**
  A test terminal launched that way ran its `claude` as a nested session that saved no transcript.
  Launch test apps with `env -i HOME="$HOME" USER="$USER" open …`.
- **Trap: running the app from a `build/` folder.** macOS 27 tracked the `build/` binary in its
  "Allow in the Menu Bar" list and the crab ended up disallowed. Live-test from /Applications.

## Design

### A. Exact Ghostty tabs (tty)

On Ghostty 1.4+, map a session to its terminal by tty: `{id, tty} of every terminal` in the same
worker query the adapter already makes. Learning by prompt, folder and title stays as the fallback
for Ghostty 1.3. Sessions started before Claws, and tabs in the background, then map at once.

### B. Restore

- **Remember**: keep each live session's adapter, pane ID, folder and title (the tracker knows them).
- **Notice the kill**: the SessionEnd hook keeps an `ended` record with the `reason` instead of
  deleting state when the reason is not a deliberate exit (`other`). Sessions whose process vanished
  without SessionEnd (crash, reboot) count as killed too. Deliberate exits (`prompt_input_exit`,
  `clear`, `logout`) are forgotten.
- **Restore ledger**: `restore.json` in the support folder. Entries expire after 7 days, and are
  dropped once resumed or dismissed. Not pruned when the session file goes.
- **Notice the relaunch**: when Ghostty launches (or Claws starts with Ghostty already running), wait
  until its terminal list is stable, then match ledger entries to terminals by pane ID.
- **Safety**: type only into a terminal that exists with that ID, whose foreground process is a shell
  (not anything running), and whose working directory is the session's folder. Otherwise skip it.
- **Ask once**: "Ghostty reopened N tabs that were running Claude Code. Resume them?" with Resume /
  Not Now and "Always resume without asking". Then type the `resumeCommand` (Settings, `{id}`) into
  each tab and press Enter.
- **Adapter API** (optional, documented in docs/adapters.md): restorable panes and "type a command
  into a pane". Ghostty implements it; other adapters can later.

### C. Search

- Session Search's code moves into Claws as a **helper app inside the bundle**
  (`Contents/Helpers/Claws Search.app`, its own process). The crab menu's "Search Sessions…" opens
  it; it quits when its window closes. Its index (about 250 MB while building) never lives in the
  always-running app, and a crash there never takes the Clawds down.
- It drops its own Ghostty code. To resume, it asks Claws (a distributed notification); Claws focuses
  the session's tab if it is still open, else opens a tab in its folder through the adapter and
  types the `resumeCommand`.
- Ported generic: no personal aliases, paths or bundle IDs. Resume uses the Claws `resumeCommand`.
- Keeps its own self-test, wired into `build.sh` and run by `--selftest`.

## Workstreams

| # | Work | Owner | Done when |
| --- | --- | --- | --- |
| 0 | Branch `next`, fixed menu bar item name, this plan, Session Search backed up | PM | done |
| 1 | A + B: tty matching, restore ledger, hook `reason`, relaunch detection, prompt, adapter API, Settings, docs | Dev 1 | self-test ALL PASS with new tests; full restore round trip on the Ghostty test copy; adapters.md updated |
| 2 | C: Search helper app, build and signing, crab menu item, resume through Claws | Dev 2 | helper builds and signs inside the bundle; its self-test passes; search and resume work from the menu |
| 3 | Integration, review, live test from /Applications, README, release notes | PM + reviewer | independent review clean; live checks pass on the real machine |
| 4 | Retire the old Session Search folder and app | PM, with the user's OK | search verified inside Claws |

Dev 1 and Dev 2 work in separate git worktrees. Shared files (`build.sh`, `App.swift`,
`StatusMenu.swift`, `SettingsWindow.swift`, docs) are merged by the PM.

## Rules for this release

Everything in CLAUDE.md's non-negotiables, plus:

- Never quit, relaunch or script the real Ghostty's tabs in tests. Use the test copy.
- Never edit `~/.claude/settings.json` by hand; test-only hooks go in a `--settings` file.
- No push, release or deletion without the user's explicit go.
- Live-test the app from /Applications (signed), one build at a time.
