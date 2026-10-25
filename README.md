<p align="center">
  <img src="docs/media/icon.png" width="128" height="128" alt="Claws for Concern icon: a pixel crab with a worried thought bubble">
</p>

<h1 align="center">Claws for Concern</h1>

<p align="center">
  <b>Tiny Clawds in the corner of your screen whenever a Claude Code session needs you.</b><br>
  A native macOS menu bar app. No Electron, no API key, nothing to configure.
</p>

<p align="center">
  <a href="https://github.com/patildhruv/claws-for-concern/releases/latest"><img src="https://img.shields.io/github/v/release/patildhruv/claws-for-concern?style=flat-square&color=D97757&label=download" alt="Download"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-1f1e1d?style=flat-square" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-native-F05138?style=flat-square" alt="Native Swift">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-6b6a66?style=flat-square" alt="MIT license"></a>
</p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/media/hero-dark.jpg">
  <img src="docs/media/hero-light.jpg" alt="A macOS desktop with a Ghostty window running Claude Code. In the bottom-left corner, five small pixel crabs; a thought bubble over the first says: Fix flaky login test, has a question, 2m. Login fix verified with 20 green runs; PR to main or release-2.4?">
</picture>

You have six Claude Code sessions going. One is waiting on a permission prompt, one finished ten minutes
ago, one died on a rate limit, and you are busy in a seventh tab.

Claws for Concern puts a small animated Clawd in the corner of your screen for each session that
needs you. **Hover** for a one-line recap of where it stopped. **Click** to jump straight to its tab.
**Look at the tab** and the Clawd quietly leaves.

## What you see

<p align="center">
  <img src="docs/media/demo.gif" width="560" alt="Animated: five Clawds waving, dancing and racing, with a thought bubble over the first">
</p>

| Clawd | Means |
| --- | --- |
| Waving, red **?** | Claude asked you a question |
| Waving, red **!** | Claude needs a permission or some input |
| Waving, red **✓** | Claude has a plan waiting for your approval |
| Grey **×** | The turn stopped on an API error: rate limit, overload, auth |
| Dancing, jumping, racing, floating | Finished while you were looking elsewhere |

Each finished session keeps its own Clawd, so a row of them stays easy to tell apart.

- **Hover**: a thought bubble with the session's title, its state and age, and a one-line recap
  written by Claude Haiku.
- **Click**: Ghostty focuses the exact tab (and split). With other terminals, the app that hosts the
  session comes to the front.
- **Right-click**: Open, Dismiss, Copy Recap, Copy Resume Command, Dismiss All.
- **⌃⌥⌘C**: jump to the most urgent session, from anywhere.
- **Menu bar crab**: how many sessions need you, and every setting.

A Clawd never appears for a session you are already looking at. It goes away when you have actually
seen the session (its Ghostty tab in front, and you active for a second), when you click it, or when
you send that session your next prompt.

## Install

**Download.** Grab `Claws-for-Concern.zip` from the [latest release](https://github.com/patildhruv/claws-for-concern/releases/latest),
unzip, and move the app to `/Applications`. The app is not notarized, so the first time, right-click it
and choose **Open** (or run `xattr -dr com.apple.quarantine "/Applications/Claws for Concern.app"`).

**Or build it** (Xcode Command Line Tools, macOS 14+):

```sh
git clone https://github.com/patildhruv/claws-for-concern.git
cd claws-for-concern
./build.sh            # builds and installs to /Applications
```

**First launch** takes three clicks:

1. **Install Hooks.** Adds a few entries to `~/.claude/settings.json`; a backup is saved next to it,
   and nothing else in the file changes. Running sessions pick them up on their own.
2. **Allow Ghostty access** (optional). Lets the app see which tab is in front and switch tabs.
3. **Open at login** (optional, ticked by default).

The app then downloads the Clawd animations from claude.ai (about 1.3 MB, once) and converts them
into tiny pixel-exact sprite sheets.

## How it works

```mermaid
flowchart LR
    CC["Claude Code sessions"] -- "hook events (async)" --> H["claws-for-concern-hook<br/>(~8 ms, never blocks Claude)"]
    H -- "one JSON file per session" --> S[("~/Library/Application Support/<br/>Claws for Concern/sessions")]
    S -- "file watcher" --> A["Claws for Concern.app"]
    A <-- "AppleScript: focused tab, focus tab" --> G["Ghostty"]
    A -- "claude -p --model haiku<br/>(your Claude Code login)" --> R["one-line recap"]
```

- **Hooks**: `SessionStart`, `UserPromptSubmit`, `PreToolUse` (for `AskUserQuestion` and `ExitPlanMode`),
  `PermissionRequest`, `Notification` (permission and input prompts), `PostToolUse`, `PostToolUseFailure`,
  `Stop`, `StopFailure` and `SessionEnd`. All but `SessionEnd` run asynchronously, so Claude never waits.
- **Which tab is which**: the app remembers the tab you were typing in when you sent each prompt. For
  sessions it has not seen you type into yet, it matches the folder and the session title Claude Code
  shows in the tab.
- **Recaps**: `claude -p --model haiku` through the Claude Code install and login already on your Mac,
  so there is no API key. About 650 input and 25 output tokens per recap, three seconds, no tools, no MCP
  servers, nothing saved to your session history, and your own settings and hooks are not loaded.
- **Sessions that vanish** (a closed tab, a crash) are noticed when their Claude process exits.

## Privacy

Everything stays on your Mac except the recap request: Claude's final message of a turn (up to
12,000 characters) goes to Anthropic through your own Claude Code login, the same way every Claude
Code request does. Turn recaps off in the menu and the bubble shows the first sentence instead.

The app reads only what the hooks record, plus the title records in each session's transcript. It never
reads your code or your terminal. Its files live in `~/Library/Application Support/Claws for Concern/`.

## Settings

Everything is in the menu bar crab:

- **Show**: sessions that need you, finished ones, errors; forget unseen finished sessions after 1–24 hours.
- **Size and Position**: Small, Medium or Large (always whole device pixels, so the art stays crisp);
  any corner; the main display or the one with your pointer.
- **One-Line Recaps by Claude Haiku**, **Preview the Clawds**, and under **Setup**: hooks, Ghostty
  access, the keyboard shortcut, Open at Login.

Two extras for the command line:

```sh
# What "Copy Resume Command" copies ({id} is the session ID):
defaults write io.github.patildhruv.claws-for-concern resumeCommand -string "claude --resume {id}"

# More official Clawd GIFs for finished sessions, one claude.ai URL per line:
open -e ~/Library/Application\ Support/Claws\ for\ Concern/extra-art.txt
```

## Requirements

- macOS 14 Sonoma or later
- [Claude Code](https://docs.claude.com/en/docs/claude-code) (the native installer or Homebrew)
- [Ghostty](https://ghostty.org) 1.3 or later for the tab-aware parts. With any other terminal the Clawds
  still appear; clicking brings that terminal forward, and a Clawd clears when you dismiss it or prompt
  that session again.

## Uninstall

Menu bar crab → Setup → **Remove Hooks…**, then quit and delete the app. To remove every trace:

```sh
rm -rf ~/Library/Application\ Support/Claws\ for\ Concern
defaults delete io.github.patildhruv.claws-for-concern
```

## Troubleshooting

- **No Clawds at all.** Menu → Setup should say *Claude Code hooks: installed*. Then send any session a
  prompt and switch to another app before it finishes. **Preview the Clawds** shows what to expect.
- **A Clawd will not go away when I look at its tab.** Allow Ghostty access (Menu → Setup). If Setup says
  some Clawds are *not yet matched to a tab*, send that session one prompt and the app will learn its tab.
- **Recaps never arrive.** Run
  `"/Applications/Claws for Concern.app/Contents/MacOS/ClawsForConcern" --recap "test"`: it uses the same
  code path and prints the error. Recent errors also appear in Menu → Setup.
- **⌃⌥⌘C does nothing.** Another app has that shortcut; the log (Menu → Setup → Show Log) says so.

## Development

```sh
./build.sh --no-install                 # build into build/
B="build/Claws for Concern.app/Contents/MacOS/ClawsForConcern"
"$B" --selftest                         # unit checks; prints ALL PASS
"$B" --help                             # the other commands
tools/make-readme-media.sh              # re-render the images in this README
```

Plain `swiftc`, no Xcode project and no dependencies. [`docs/code-map.md`](docs/code-map.md) says which file
does what, and [`CLAUDE.md`](CLAUDE.md) lists the traps found while building it.

## Credits

An unofficial fan project, not affiliated with or endorsed by Anthropic. **Clawd is Anthropic's
character**: this repository and its release builds contain none of Anthropic's artwork. The app
downloads the Clawd animations from claude.ai on your own Mac at first launch (the screenshots above
show them). The app icon and the menu bar crab are original drawings.

Why the name? Because six unattended agents are, frankly, claws for concern.

Code released under the [MIT license](LICENSE).
