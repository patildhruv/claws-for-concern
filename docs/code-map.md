# Code map

| File | Responsibility |
| --- | --- |
| `Sources/Shared/SessionState.swift` | `Paths` (support folder layout), `SessionStatus`, `SessionState` (the per-session JSON the hook writes, atomic save), `ProcInfo` (sysctl process info, finding the Claude process, liveness) |
| `Sources/Shared/HookEvent.swift` | Pure state transitions for each hook event; describes questions, permission requests, plans and failures |
| `Sources/Hook/main.swift` | `claws-for-concern-hook`: reads the event on stdin, flocks, applies `HookEvent`, writes or deletes the session file, exits 0 |
| `Sources/App/App.swift` | `@main`, `AppDelegate` (launch, first-run alert, hooks/permission/art flows, hot key), `CLI` commands |
| `Sources/App/Tracker.swift` | The model: reads session files, decides which sessions get a Clawd, learns each session's Ghostty tab, clears Clawds you have seen, recaps, demo Clawds, reaping dead sessions |
| `Sources/App/Ghostty.swift` | AppleScript bridge on its own `ScriptThread`: permission, 1 s focused-tab snapshot, listing and focusing terminals; `TerminalApps` fallback; `Presence` (idle time) |
| `Sources/App/Summarizer.swift` | One-line recaps via `claude -p --model haiku` (clean env, timeouts), text cleanup and fallback; `AppLog` |
| `Sources/App/Overlay.swift` | `Placement`/`Placements` (per-display spot), `StripGeometry` (pure layout and snapping), `OverlayController` (the strip: follow-the-pointer, drag, animated relayout, overflow, hover/click/menus), `StripPanel`, `StripItem`, `ClawdCell` (sprite, badge, VoiceOver), `OverflowChip`, `BlockItem` |
| `Sources/App/Bubble.swift` | The thought bubble panel and view: text measuring, tail, light/dark drawing |
| `Sources/App/StatusMenu.swift` | Menu bar crab: count, the sessions, Jump, Dismiss All, Pause, Preview, Settings, Quit |
| `Sources/App/SettingsWindow.swift` | The Settings window (toolbar tabs of SwiftUI panes), live status, sprite and bubble previews, corner picker, shortcut recorder |
| `Sources/App/Notifier.swift` | Optional macOS notifications: post, withdraw on seen, click to open |
| `Sources/App/Settings.swift` | Every preference key with its default, read accessors, reset |
| `Sources/App/Sprites.swift` | `Sprite` (frames + Core Animation loop), `SpriteLibrary` (loading, finished-Clawd pool), `PixelCrab` (our own crab drawing) |
| `Sources/App/Art.swift` | Downloads the Clawd GIFs from claude.ai and converts them to pixel-exact sprite strips |
| `Sources/App/HooksInstaller.swift` | Installs, repairs and removes our hooks in ~/.claude/settings.json, with backups |
| `Sources/App/OrderedJSON.swift` | Order-preserving JSON parser/serialiser matching `JSON.stringify(v, null, 2)` |
| `Sources/App/HotKey.swift` | Carbon global hot key, modifier conversion, key names for the recorder |
| `Sources/App/SelfTest.swift` | `--selftest` |
| `Sources/App/Snapshot.swift` | `--snapshot`: renders the README images offscreen |
| `tools/make-icon.swift` | Draws `Resources/AppIcon.icns` |
| `tools/make-readme-media.sh` | Renders `docs/media/*` (hero shots, bubble close-ups, demo GIF) |
| `build.sh` | Compiles both binaries, bundles, signs, installs |
