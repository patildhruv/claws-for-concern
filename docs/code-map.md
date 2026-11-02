# Code map

| File | Responsibility |
| --- | --- |
| `Sources/Shared/SessionState.swift` | `Paths` (support folder layout), `SessionStatus`, `SessionState` (the per-session JSON the hook writes, atomic save), `ProcInfo` (sysctl process info incl. uid and process groups, finding the Claude process and the terminal it runs under, liveness) |
| `Sources/Shared/HookEvent.swift` | Pure state transitions for each hook event (SessionEnd: deliberate exits delete, others mark the session ended); describes questions, permission requests, plans and failures |
| `Sources/Hook/main.swift` | `claws-for-concern-hook`: reads the event on stdin, flocks, applies `HookEvent`, writes or deletes the session file, exits 0 |
| `Sources/App/App.swift` | `@main`, `AppDelegate` (launch, first-run alert, hooks/permission/art flows, hot key, starts `Restorer`), `CLI` commands |
| `Sources/App/Tracker.swift` | The model: reads session files, decides which sessions get a Clawd, asks the terminal adapters where each session is and what you are looking at, clears Clawds you have seen, recaps, demo Clawds; hands ended and vanished sessions to the restore ledger; `headless` mode for `--watch` |
| `Sources/App/Restore.swift` | Restore: `RestoreEntry`/`RestoreLedger` (restore.json under restore.lock), `RestorePlan` (the rules by terminal process and the typing safety, pure), `RestoreWait` (tabs settled), `Restorer` (launch observer, ask, type the resume command), `RestorePrompt` (the panel), `RestoreCLI` (`--restore-status`, `--restore-run`, `--watch`) |
| `Sources/Shared/TerminalContext.swift` | The allow-list of terminal environment variables the hook records; tty and process-list helpers |
| `Sources/App/Terminals/Terminals.swift` | The `TerminalAdapter` protocol (and `PaneInfo`, `RestorePane` with its login-shell rule), the `Terminals` coordinator (registry, worker thread, polling, snapshots, open, `newPane`: launch + permission, then the adapter's new pane), `Automation` permissions, `Script`, `Command`, `HostApp`, `ScriptThread`, `Presence` |
| `Sources/App/Terminals/GhosttyAdapter.swift` | Ghostty (tabs by tty on 1.4+ via `TTYMap`, learns panes on 1.3; restore: panes, typing, `window-save-state`; new tabs for Search) and `HostAppAdapter` (the fallback: bring the hosting app forward) |
| `Sources/App/Terminals/MultiplexerAdapters.swift` | tmux and herdr |
| `Sources/App/Terminals/CmuxAdapter.swift` | cmux (CLI, socket modes) |
| `Sources/App/Terminals/AppleScriptTerminals.swift` | iTerm2 and Terminal (matched by tty) |
| `Sources/App/Terminals/Diagnostics.swift` | `--terminals` (lists Ghostty once, so tabs show by tty), `--open-session` |
| `Sources/App/Summarizer.swift` | One-line recaps via `claude -p --model haiku` (clean env, timeouts), text cleanup and fallback; `AppLog` |
| `Sources/App/Overlay.swift` | `Placement`/`Placements` (per-display spot), `StripGeometry` (pure layout and snapping), `OverlayController` (the strip: follow-the-pointer, drag, animated relayout, overflow, hover/click/menus), `StripPanel`, `StripItem`, `ClawdCell` (sprite, badge, VoiceOver), `OverflowChip`, `BlockItem` |
| `Sources/App/Bubble.swift` | The thought bubble panel and view: text measuring, tail, drawing (fill and stroke from `Brand`) |
| `Sources/App/StatusMenu.swift` | Menu bar crab: count, the sessions, Jump, Dismiss All, Search Sessions, Pause, Preview, Settings, Quit |
| `Sources/App/SearchHelper.swift` | Opens the search helper with a nonce; answers its resume requests (who may ask, stale requests, switch to a running session, else a new Ghostty tab in the folder its transcript names) and replies; `ResumeGate` (one tab per session, 15 s cooldown); `Quarantine` (the helper's download mark, cleared at launch) and the alert when the helper will not open |
| `Sources/App/SettingsWindow.swift` | The Settings window (toolbar tabs of SwiftUI panes), live status, sprite and bubble previews, corner picker, shortcut recorder |
| `Sources/App/Notifier.swift` | Optional macOS notifications: post, withdraw on seen, click to open |
| `Sources/App/Settings.swift` | Every preference key with its default, read accessors, reset |
| `Sources/App/Sprites.swift` | `Sprite` (frames + Core Animation loop), `SpriteLibrary` (loading, finished-Clawd pool) |
| `Sources/App/Art.swift` | Downloads the Clawd GIFs from claude.ai and converts them to pixel-exact sprite strips |
| `Sources/App/HooksInstaller.swift` | Installs, repairs and removes our hooks in ~/.claude/settings.json, with backups |
| `Sources/App/OrderedJSON.swift` | Order-preserving JSON parser/serialiser matching `JSON.stringify(v, null, 2)` |
| `Sources/App/HotKey.swift` | Carbon global hot key, modifier conversion, key names for the recorder |
| `Sources/App/SelfTest.swift` | `--selftest` (runs the search helper's self-test too) |
| `Sources/App/Snapshot.swift` | `--snapshot`: renders the README images offscreen |
| `Sources/Search/ResumeRequest.swift` | Compiled into the app and the helper: `ResumeRequest`/`ResumeReply` (the distributed notifications, nonce, validation), `ResumeCommand` (the app's template), `ProjectDirs` (Claude Code's folder names with its hash, the folder read back from a transcript), their shared tests |
| `Sources/Search/Brand.swift` | Compiled into the app and the helper: `PixelCrab` (our own crab: menu bar, stand-in sprite, Search's empty states), `Brand` (clay and ink, text and fill shades that meet WCAG AA, the thought-bubble fill and stroke) |
| `Sources/Search/Demo.swift` | `--demo`: 12 made-up sessions written to a temporary home that `Paths.home` points at; nothing of yours is read, nothing is resumed |
| `Sources/Search/ResumeClient.swift` | The helper's side of a resume: `PendingResumes` (replies and timeouts, pure), `ResumeClient` (sends with the launch nonce, clipboard fallback, `settle` before quitting) |
| `Sources/Search/App.swift` | The helper's `@main`: the window ("Search Sessions") and its menus, About box, quit on close; CLI `--search`, `--resume`, `--demo`; `--snapshot` (offscreen, as the key window) |
| `Sources/Search/Model.swift` | `Scope`, `Message`, `Session` (name, folder, resume command, `canResume`/`whyNotResumable`), `ProjectDirs.resolve` (disk decode), `Paths` (privacy-protected folders, symlinks read with lstat), `Shell.quote` |
| `Sources/Search/Loader.swift` | `SessionStore`: finds transcripts, re-parses only changed files, in parallel; lenient `Record`/`Content`/`Block` decoding, `FlatStrings` for tool inputs, `SessionBuilder` (name and folder rules), `Prompts` (first-prompt naming) |
| `Sources/Search/Tokenizer.swift` | UTF-8 word tokenizer for the index and highlighting |
| `Sources/Search/SearchIndex.swift` | `ParsedQuery`, `PhraseMatcher`, the inverted index, fuzzy word matching (bounded edit distance), ranking |
| `Sources/Search/Snippets.swift` | Row previews and the detail pane's matching messages, highlighted; ANSI output for the CLI |
| `Sources/Search/AppModel.swift` | The window's state: refresh, debounced background search, previews, selection; Return waits for fresh results; resume (through `ResumeClient`) and copy actions |
| `Sources/Search/Views.swift` | Split view, results list (clay `SelectionBackground`), detail pane, `CrabThought` (empty states), `NSSearchField` wrapper (arrows move the selection, Return resumes, Esc clears) |
| `Sources/Search/SelfTest.swift` | The helper's `--selftest`: unit checks plus searches picked from the real transcripts |
| `Sources/Search/Info.plist` | The helper's bundle (build.sh adds the app's version) |
| `tools/make-icon.swift` | Draws `Resources/AppIcon.icns`, and `SearchIcon.icns` for the helper with `search` |
| `tools/make-readme-media.sh` | Renders `docs/media/*` (hero shots, bubble close-ups, demo GIF, Search on demo data) |
| `build.sh` | Compiles the app, the hook and the search helper, bundles, signs inside out, installs |
