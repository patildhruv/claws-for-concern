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
| AppleScript, but no IDs in the environment and no `tty` | `GhosttyAdapter.swift` (learns panes) |

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
