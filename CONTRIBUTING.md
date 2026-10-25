# Contributing

Thanks for helping. The most useful contribution is **support for your terminal**: see
[docs/adapters.md](docs/adapters.md). It is one Swift file, and the page walks you (or your Claude)
through it.

## Set up

macOS 14 or later and Xcode's command line tools (`xcode-select --install`). No Xcode project, no
dependencies.

```sh
git clone https://github.com/patildhruv/claws-for-concern.git
cd claws-for-concern
./build.sh --no-install                     # build/Claws for Concern.app
B="build/Claws for Concern.app/Contents/MacOS/ClawsForConcern"
"$B" --selftest                             # must print ALL PASS
"$B" --help                                 # the diagnostic commands
./build.sh                                  # build and install to /Applications
```

Rebuilding resets macOS's Automation permission for ad-hoc builds. If you have an Apple Development
certificate, `SIGN_IDENTITY="Apple Development: …" ./build.sh` keeps it across builds.

## Working with Claude Code on this repo

[`CLAUDE.md`](CLAUDE.md) holds the rules and the traps found so far, and
[`docs/code-map.md`](docs/code-map.md) says which file does what. Point your Claude at both before it
starts; for a new terminal, also at [`docs/adapters.md`](docs/adapters.md).

## The rules

- **No Anthropic artwork in the repository or in builds.** The app downloads the Clawd animations at
  first launch. Our own drawings (the icon, the menu bar crab) are fine.
- **Never slow Claude Code down.** Hooks are asynchronous, print nothing and always exit 0.
- **Never block the main thread**, and bound every call to another app or tool.
- **`~/.claude/settings.json` is edited byte for byte.** Installing and removing the hooks must leave
  every other character as it was (`--selftest` checks this against your real file).
- **No personal paths, names or aliases in the code.** Personal choices are settings.
- **No secrets on disk or in logs.**
- **Match the code around you**: naming, comment density, idiom. Comments explain why, not what.

## Pull requests

- One change per pull request, with a sentence on why.
- `--selftest` prints ALL PASS, with tests for what you added.
- Tried in the real app (`./build.sh`), not only in the self-test.
- User-visible change? Update the README; new file? Update `docs/code-map.md`.
