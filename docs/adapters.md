# Adding a terminal

Every terminal gets Clawds and recaps already: they come from Claude Code's hooks, which run
wherever Claude Code runs. A **terminal adapter** adds the three things that need to know about your
terminal:

1. **Which pane** a session lives in.
2. **Are you looking at it?** so its Clawd clears once you have seen it.
3. **Take me there**, when you click a Clawd.

Built in: Ghostty, cmux, herdr, tmux, iTerm2 and Terminal. Adding another is one Swift file plus a
couple of lines elsewhere. You, or your own Claude, can do it with this page.

## How it fits together

```
Claude Code ── hook ──▶ sessions/<id>.json        records TERM_PROGRAM, your terminal's IDs, the tty
                              │
                              ▼
              Terminals.adapter(for: session)      the first adapter whose claims() says yes
                              │
       ┌──────────────────────┼─────────────────────────┐
  paneID(for:)          lookedAt(front:)           focus(paneID:session:)
  which pane            what you're looking at     take me there
  (main thread)         (worker, ~1/s, only while   (worker, on click)
                         a session works or a
                         Clawd is up)
```

All adapters live in `Sources/App/Terminals/`. Read `Terminals.swift` (the protocol and the shared
helpers) and the adapter closest to yours:

| Your terminal has… | Copy |
| --- | --- |
| a CLI with pane IDs in the shell's environment | `MultiplexerAdapters.swift` (tmux, herdr), `CmuxAdapter.swift` |
| AppleScript with a `tty` per tab | `AppleScriptTerminals.swift` (iTerm2, Terminal) |
| AppleScript, no IDs in the environment, a `tty` per tab only in newer versions | `GhosttyAdapter.swift` (maps by tty on 1.4+ from a snapshot of its listings, learns panes on 1.3) |

## Step by step

### 1. Find what identifies a pane

Open your terminal, and in a shell run:

```sh
env | sort        # look for a pane, window or session ID, and a socket path
tty               # the device the shell is on
```

You are looking for something **in the environment** that names the pane (like `TMUX_PANE=%3`,
`HERDR_PANE_ID=w1:p2`, `CMUX_SURFACE_ID=…`, `WEZTERM_PANE=4`), or a scripting interface that
reports each tab's `tty`.

### 2. Let the hook record it

Add the variable names to `TerminalContext.keys` in `Sources/Shared/TerminalContext.swift`.
Exact names only, never prefixes, and **never anything secret**: cmux, for example, puts a socket
capability token in every shell. The hook writes these values to disk.

### 3. Write the adapter

Create `Sources/App/Terminals/<Name>Adapter.swift`:

```swift
import AppKit

/// <Terminal>: how it finds panes, what "looking" means, and anything it needs from the user.
final class WezTermAdapter: TerminalAdapter {
    let id = "wezterm"            // stable forever: it is stored with sessions
    let name = "WezTerm"          // shown in Settings and menus

    // Main thread: decide from what the hook recorded, nothing else.
    func claims(_ s: SessionState) -> Bool { s.env("WEZTERM_PANE") != nil }

    // Main thread: a stable ID for the pane. Prefix it with the server/socket when IDs are only
    // unique per server ("<socket>|<pane>"), as tmux and herdr do.
    func paneID(for s: SessionState) -> String? { s.env("WEZTERM_PANE") }

    // Worker: the panes you are looking at right now. Return [] unless the terminal is in front
    // (front.bundleID) — the user has to actually be looking.
    func lookedAt(front: FrontApp) -> Set<String> {
        guard front.bundleID == "com.github.wez.wezterm", let cli = Command.find("wezterm"),
              let list = Command.json(Command.run(cli, ["cli", "list", "--format", "json"])) as? [[String: Any]]
        else { return [] }
        return Set(list.filter { ($0["is_active"] as? Bool) == true }.compactMap { ($0["pane_id"] as? Int).map(String.init) })
    }

    // Worker: bring the pane forward, and the app with it. False if it did not work (the app then
    // falls back to just activating whatever hosts the session).
    func focus(paneID: String, session: SessionState) -> Bool {
        guard let cli = Command.find("wezterm"),
              let r = Command.run(cli, ["cli", "activate-pane", "--pane-id", paneID]), r.status == 0 else { return false }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.github.wez.wezterm").first {
            DispatchQueue.main.async { app.activate() }
        }
        return true
    }

    // Worker: one sentence on what works, for Settings → Integrations. Offer a fix when something
    // is missing (see AdapterHealth.Fix).
    func health() -> AdapterHealth {
        Command.find("wezterm") == nil ? AdapterHealth(level: .unavailable, detail: "WezTerm is not installed.")
            : AdapterHealth(level: .ready, detail: "Finds each session's pane, clears its Clawd when you look, and jumps there on click.")
    }
}
```

(The WezTerm calls above are illustrative; check your terminal's own docs and test them.)

Optional members, with defaults:

| Member | Default | Override when |
| --- | --- | --- |
| `scriptedBundleID` | nil | you drive the app over AppleScript (the app asks for the Automation permission for it) |
| `tracksSeenItself` | false | the terminal knows what you have seen (herdr's `done` vs `idle`): then no keyboard/mouse activity is required |
| `learnsPanes`, `focusedPane(front:)`, `panes()` | false, nil, [] | nothing in the environment names the pane: the tracker learns it from the tab you type a prompt into, then by folder and title (Ghostty) |
| `newPane(in:typing:)` | false | your terminal can open a new tab or pane in a folder and type into its shell: Search uses it to resume a session that is no longer running (see below) |
| `restoresPanes`, `restorablePanes()`, `type(_:into:)` | false, nil, false | your terminal reopens its panes **under the same IDs** after it quits and relaunches: Restore resumes the sessions they were running (see below) |
| `appBundleID` | `scriptedBundleID` | Restore: the app whose launch starts a restore, if it is not the one you script |
| `restoreProblem()` | nil | Restore: a setting the user must change before your terminal reopens its panes (shown in Settings → General → Restore) |

#### `newPane(in:typing:)`

Search's Resume calls it through `Terminals.newPane`. When your app runs and may already be scripted,
that goes straight to the worker; otherwise it first launches your app (without bringing it forward)
and gets its Automation permission on the prompt thread. Either way it is dropped once the request is
30 s old. Your method runs on the worker: open a **new** tab, pane or window in `dir`, type `command`
into its shell followed by Return (typed, not run as the pane's command, so the user's aliases work and
the shell stays open), bring it forward, and return whether that worked. Never type into an existing
pane. `dir` is an absolute path Claws read from the session's transcript and `command` is the user's
own resume command with a validated session ID, but quote both for your script or CLI all the same.
Address the app your adapter was made for (its bundle ID), not a hard-coded one, so tests can drive a
copy. Ghostty's version, for reference:

```applescript
tell application id "<the adapter's Ghostty>"
  set cfg to {initial working directory:"<dir>", initial input:"<command>" & linefeed}
  if (count of windows) > 0 then
    new tab in front window with configuration cfg
  else
    new window with configuration cfg
  end if
  activate
end tell
```

Put the script in a static function and compile it in `--selftest` (`NSAppleScript.compileAndReturnError`
reads the app's dictionary without sending it anything), as `GhosttyAdapter.newPaneScript` is. Try it
live in a throwaway terminal window, never one with sessions you care about.

#### Restore: `restoresPanes`, `restorablePanes()`, `type(_:into:)`

When your terminal quits (or crashes, or the Mac restarts), the Claude Code sessions in its panes end
with it. If it reopens those panes on its next launch, Restore types the user's resume command into
each one. All the bookkeeping is shared (`Sources/App/Restore.swift`):

- The hook marks a session ended when SessionEnd's `reason` is not a deliberate exit; the tracker moves
  it, with the pane ID your `paneID(for:)` (or learning) gave it, into the restore ledger.
- An entry is dropped if the terminal process that hosted the session is still running 12 s after
  the end (a tab closed, or claude ended in a pane that stayed open): Restore is for a terminal that
  went away. It is also dropped after the relaunch that did not bring its pane back, after a week, and
  once its pane hosts another session.
- When `appBundleID` launches (or runs when Claws starts), Restore polls `restorablePanes()` once a
  second until the list settles, then types into a pane only if it **exists under the entry's pane
  ID**, has **a shell in front** (`atShell`), **started after the session ended** (`started`: so it
  was reopened, not left open), and is **in the session's folder** (symlinks resolved).

What you implement, all on the worker:

- `restoresPanes`: true. Your pane IDs must survive a relaunch: check that before anything else.
- `restorablePanes()`: every pane with its folder and foreground process, or nil if the terminal
  cannot say. If your terminal reports each pane's foreground PID, `RestorePane.from(id:cwd:foregroundPid:)`
  fills in the rest (shell or not, start time). Return nil, not a guess, when you cannot tell.
- `type(_:into:)`: type the command into that existing pane and press Return. Restore calls it only
  after the checks above, and checks again right before (the user may have used the tab meanwhile).
- `restoreProblem()`, optional: why the terminal will not reopen its panes (Ghostty: its
  `window-save-state` is not `always`). Bound any tool you run with `Command.run`.

Test it against a **copy** of your terminal under another bundle ID, never the one with your sessions:
`--restore-status` shows the ledger and what Restore would do with each entry, `--watch` runs the
tracker and Restore without the menu bar app (printing each step), and `--restore-run [--yes]` runs a
restore now. For Ghostty, `--bundle-id <copy's ID>` points the adapter at the copy.

### 4. Register it

Add an instance to `Terminals.adapters` in `Terminals.swift`. **Order matters**: the first adapter
that claims a session wins, so multiplexers (tmux, herdr, zellij…) go before the terminal apps they
run inside, and anything that pretends to be another terminal goes first (cmux sets
`TERM_PROGRAM=ghostty`, so cmux precedes Ghostty).

### 5. Test it

Self-test: add a few lines to `SelfTest.terminals()` (claims, pane ID, and that no secret is captured),
then:

```sh
./build.sh --no-install
B="build/Claws for Concern.app/Contents/MacOS/ClawsForConcern"
"$B" --selftest
```

Live, with a real session (Haiku keeps it cheap):

```sh
claude --model haiku          # in your terminal; ask it anything, let it finish
"$B" --terminals              # which adapter claimed each session, its pane, "looking at it"
"$B" --open-session <id>      # the click path, from the first characters of a session ID
```

Switch tabs or windows between runs and check "looking at it" follows you.

### 6. Tell people

Add a row to the terminal table in the README, and mention anything the user must enable (a socket
mode, a permission) in `health()`'s text.

## Rules

These keep Claws for Concern fast and trustworthy for everyone. Pull requests that break them are
sent back.

- **Never block the main thread.** `claims` and `paneID` must be instant and read only the recorded
  session. Everything else runs on `Terminals.worker`.
- **Bound every external call.** Use `Command.run` (1.5 s timeout) and `with timeout of 2 seconds` in
  AppleScript. A wedged terminal must not stall the others.
- **Poll cheaply.** `lookedAt` runs about once a second, but only while a session works or a Clawd is
  up. One call per poll, and return early when your app is not in front.
- **No new permissions.** Automation for your own terminal app is fine. Accessibility, Input Monitoring
  or Screen Recording are not.
- **No secrets, anywhere.** Not in `TerminalContext.keys`, not in logs, not in `health()` text.
- **IDs are forever.** `id` and the shape of `paneID` are stored in users' state; do not change them
  after release.
- **Say what the user gets.** `health()` is the only place a user learns what works and what they
  must do. One plain sentence, and a `Fix` when there is one.
- **One file.** Shared helpers go in `Terminals.swift` only if a second adapter needs them.

## Before you open a pull request

- [ ] `--selftest` prints ALL PASS, with new lines for your adapter
- [ ] A real Claude Code session in your terminal: `--terminals` shows your adapter, the right pane,
      and "looking at it" exactly when you look; `--open-session` takes you there
- [ ] Your terminal not installed: Settings → Integrations says so, nothing else changes
- [ ] README terminal table updated
