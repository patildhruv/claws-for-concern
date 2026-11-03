# The Usage window

Every Claude Code session's usage and cost in one place (1.4; plan in `docs/plan-1.4.md`). It is the
search helper's second window (scene id `usage`, title "Usage"), in the same process as Search, so the
figures (`UsageModel`, docs/usage.md) are read once for both. Sources in `Sources/Search/`:

```
UsageWindow.swift        the window: toolbar filters, layout, status line; HelperWindow, WindowRequest,
                         CurrencyMenu, UsageBreakdown
UsageSections.swift      tiles, cost per day (Swift Charts), near the context limit, all sessions (Table),
                         by project, by model, when Claude works; UsageStyle (colours)
UsageWindowModel.swift   filters, the report, sort and selection, live sessions, row actions, CSV export;
                         UsagePick (the Session menu's focus)
UsageReport.swift        pure: ranges, rows, totals, chart series, by project / model, heatmap; UsageCSV
Currency.swift           the second currency: formats, Frankfurter, RateRule, SecondCurrencySetting
LiveSessions.swift       Claws' session files, read only: which sessions are running
AppModel+Usage.swift     what the window needs from Search's model
UsageSnapshot.swift      --snapshot-usage
UsageWindowTests.swift   the window's self-test (in SelfTest)
```

## Opening it

- **From the crab menu**, **Usage…** (under Search Sessions…) calls `SearchHelper.openUsage()`. A helper
  that is not running is launched as `open()` does, nonce included, with `--window usage`. SwiftUI opens
  the first scene at launch and macOS 14 cannot hold one back (`defaultLaunchBehavior` is macOS 15), so
  the helper declares the asked-for window first (`HelperWindow.order`): only Usage comes up.
- A helper **already running** ignores arguments (macOS only brings it forward), so Claws posts
  `io.github.patildhruv.claws-for-concern.search.openWindow` with `{window, pid}`; both windows listen
  (`opensRequestedWindows`) and open the one asked for. Another copy of the helper ignores another PID.
  Anyone can post it; all it does is open a window. Search Sessions… goes the same way, so it works
  while only Usage is open (otherwise it only brought the helper forward).
- **From Search**, the toolbar's chart button (`openWindow(id: "usage")`).
- The helper's rules hold: it quits when its last window closes (Usage counts), and quits if no window
  came up within 3 s.
- Not exercised live (no dev-build window may open on screen): only the ordering and the request are
  self-tested. To check by hand: helper closed, crab → Usage…: only Usage; only Search open → Usage… adds
  Usage; only Usage open → Search Sessions… adds Search.

## What it shows

Filters sit in the toolbar: range (Today, 7 Days, 30 Days, All Time), project, model, find (name,
folder, project or session ID prefix), the second currency, refresh. Below, top to bottom:

| Section | What |
| --- | --- |
| Tiles | Cost at API prices; written by Claude (output tokens); Claude worked (on N days); sessions (in N projects); lines changed; compactions (automatic, by /compact). A help line says what API prices and est. mean; another names models with no price |
| Cost per day, by project | Bars stacked by project (Swift Charts), the five costliest projects in the range in colour, the rest as "Other projects"; hover shows a day's parts |
| Near the context limit | Running sessions at 80% of their window or more (`isNearContextLimit`), whatever the range |
| All sessions | Sortable table: session (and folder), project, last active, context, compactions, cost, written, Claude time, lines; Open in Search, Resume, Copy ID, Export CSV |
| By project | Cost per project, bars in the chart's colours; a click filters to it |
| By model | Cost by model (one split bar and a list: the six costliest, "+N more", and models with no price always); a click filters to it |
| When Claude works | Claude's working time by weekday × hour (`SessionUsage.activity`), rows from the locale's first weekday |

**One row per session ID** (`UsageModel.bySession`), for the table and every total, tile and chart: a
transcript filed under two project folders counts once. The row names and opens the copy whose
`projectDir` matches its figures.

### Ranges

A range is local calendar days (`Calendar.usage`), today and the days before it. A session is in the
range when it has a reply, working time or a compaction on one of those days. Per session:

| Figure | All time | A range |
| --- | --- | --- |
| Cost | `cost.usd` | sum of `cost(of: day)`: each day's estimate, scaled to Claude Code's figure when that is the session's cost |
| Written, Claude time | `tokens.output`, `turns.seconds` | the days' output and working seconds |
| Compactions | all | those whose own time falls in the range |
| Lines | `lines` | a session wholly inside the range keeps its own count; one the range cuts sums `lines(of: day)` and is est. |
| Context | now | now (not a range figure) |

### Est., API prices, unknown

- Cost is Claude Code's figure when `cost.source == .claudeCode`, else an estimate, marked **est.**
  Totals that include any estimate say est. Always "at API prices"; the help line says that on a Pro
  or Max plan it is not the bill.
- `cost.usd == nil` is **unknown**, shown "unknown", never $0, and left out of totals with a note. With
  `cost.unpriced` non-empty the cost is at least what was priced: "≥ $3.10 est." and a footnote.
- By model splits each session's cost in the range by its models' share of its estimate (the days do
  not say which model replied when): every model figure is est.
- Lines: Claude Code's count when its source is `claudeCode`, else counted from Edit and Write (est.).
  A zero side is left out ("+120"); zero lines are not marked est.

### Running sessions

Claws for Concern's hook writes `<session id>.json` per live session in
`~/Library/Application Support/Claws for Concern/sessions/` (`CLAWS_HOME/sessions` when that is set).
`LiveSessions` reads those files only (the helper does not compile `Sources/Shared`, so it decodes the
five fields it needs) and applies Claws' own rule (`SearchHelper.isRunning`): not ended, and its Claude
process alive with the same start time; a file with no process on record counts only if it changed in
the last 5 minutes. Read every 15 s while the window is open, and when the app becomes active. Under
`--demo` the same layout sits inside the demo's own home, with three made-up files (two running as the
demo process itself, one ended).

### Colours

Clay only where Search uses it (Resume, the selection outside the table); figures in system ink.
Computed for WCAG 2.x (backgrounds: window white / `#1E1E1E`, cards `#F5F5F5` / `#262626`):

| Use | Light | Dark | Ratio (light / dark) |
| --- | --- | --- | --- |
| Secondary text | `#666666` | `#A8A8A8` | 5.27 / 6.36 on cards (AA); Increase Contrast `#474747` / `#C8C8C8`, 8.2 / 8.4 |
| Project colours (clay, blue, green, violet, magenta) | `#C45A35 #2A78D6 #16875F #6250D6 #C4457C` | `#D9734F #3987E5 #199E70 #9085E9 #D55181` | each ≥ 3:1 on the card; adjacent pairs ≥ 15 ΔE under protan and deutan simulation (dataviz validator) |
| Other projects | `#808080` | `#8C8C8C` | 3.62 / 4.50 |
| Context bar at 80% or more | `#8F3A1C` | `#F09A7A` | 6.90 / 6.92 on the card, 5.7 / 5.1 on the track |
| Heatmap | `#F4D8CC` → `#983A1A` | `#4D3027` → `#F4AE93` | the busiest cell 6.5 / 8.2; quiet cells recede by design, so each row has a VoiceOver value, each cell a tooltip, and a "Busiest" line |

The system's secondary label colour is black at 50% on macOS 27 (3.9:1 on white, under AA), so the
window uses its own grey; in a selected table row (the accent colour) cells switch to the system's
secondary style (`QuietText`). Stacked segments and the by-model bar have a 2 pt gap in the card's colour.

### Keyboard and VoiceOver

The table is a native one: arrows move the selection, Return (or a double-click) opens the session in
Search (`contextMenu(forSelectionType:primaryAction:)`; Return and keypad Enter checked offscreen with
synthetic key events). While the Usage window is in front the Session menu acts on its row
(`UsagePick`, a focused scene value): Resume ⌘O, Copy Session ID ⌥⌘C, Show Transcript ⇧⌘R. Charts carry
a label and a summary value; each bar has its own label and value; heatmap rows read as "Tuesday, 6h 30m
in all, busiest 10:00 to 11:00".

## Actions

- **Open in Search**: `openWindow(id: "main")`, then Search's `AppModel.show(sessionID:projectDir:)` with
  the figures' project folder (Search picks that copy, clears the field if needed, selects and scrolls).
- **Resume**: through `AppModel.resume`, the 1.3 path (Claws checks the nonce, the helper in front, the
  folder from the transcript). Search's answer shows in the window's status line.
- **Copy ID**: the session ID.
- **Export CSV…**: the rows the filters show, in the table's order. UTF-8 with a byte order mark (Excel
  reads ₹), CRLF, a header row; figures as plain numbers (dot decimals, no symbols); text a spreadsheet
  would run as a formula (`=`, `+`, `-`, `@` first) gets a leading apostrophe. Columns: session,
  project, folder, session ID, last active (ISO 8601), context tokens and %, compactions, cost (USD at
  API prices) and its source (Claude Code, estimate, part unpriced, unknown), the second currency when
  on (its rate and day in the header), output tokens, Claude's hours, lines added and removed and their
  source. File name "Claude Code usage, last 30 days, 2026-11-03.csv".

## The second currency

Dollars always; a second currency only once you turn it on (toolbar **$** menu: Show a Second Currency
turns on Indian rupees, or whichever you last picked; Currency lists 16). `UsageModel.money(_:)` adds it
to every cost ("$12.40 (₹1.12K)"), so Search's panel and list change with the setting; the window's
table puts it on a line of its own under the dollars (`secondMoney`).

- **Formats**: INR in the Indian short scale, three significant digits from a thousand up (₹91.2K,
  ₹8.26L, ₹1.2Cr; under ₹100 with paise, ₹100–999 whole); the others like the dollars ("€11.42", "¥1,903",
  "CA$1,284", "CHF 12.40"). The rate reads "₹ at 94.94 (2 Nov)": the day is the service's, not ours.
- **The service**: Frankfurter's v2 API, `https://api.frankfurter.dev/v2/rates?base=USD&quotes=<the 16 codes>`.
  Free for any use, no key, HTTPS, no quotas, caching encouraged; its documentation (frankfurter.dev,
  read 2026-11-03) says it does not collect or log personal data, IP addresses or request URLs, and it
  runs behind Cloudflare; open source. Rates are blended central-bank mid rates, each row with its own
  date (INR 94.94 dated 2 Nov on 3 Nov; ECB alone gave 94.91). ExchangeRate-API's open endpoint was
  the alternative; it requires an attribution link and forbids redistribution.
- **The request**: one GET for every offered currency, so it does not say which you picked, and a
  switch needs no new one. Headers fixed (`Frankfurter.headers`): `User-Agent: ClawsSearch`,
  `Accept: application/json`, `Accept-Language: en`; URLSession adds Host, Accept-Encoding and
  Connection. Without the pinned ones it sent your languages and a user agent naming your macOS version
  (checked against a local listener). Ephemeral session: no cookies, no cache on disk.
- **When** (`RateRule`): a day that got an answer gets no other request; a failed one waits an hour.
  Asked when the setting turns on, at the window's launch, when the Usage window appears and when the
  app becomes active. Off: no request, ever (self-tested with a counting fetcher).
- **Offline**: the last rates fetched, with their day ("…, the last rate fetched (offline)"), or
  dollars only with the reason in the menu.
- **Stored** in the helper's own defaults (`io.github.patildhruv.claws-for-concern.search`):
  `secondCurrency` (absent = off), `secondCurrencyLast`, `exchangeRates` (JSON with the fetch time and
  each rate's day), `exchangeRatesAttempt`. The window's range is `usageRange`.
- **`--demo`**: fixed made-up rates (₹90 a dollar) dated today, nothing stored, never fetched; the
  setting starts off (`--currency INR` turns it on for a snapshot).
- Snapshots never fetch: without `--demo` they show your setting and its cached rate.

## Commands

```
H=build/obj/search-check     # or the helper in the bundle
$H --demo --snapshot-usage out.png [--range today|7d|30d|all] [--appearance light|dark] [--currency INR]
                             [--select first] [--size WxH] [--part breakdown]
$H --currency-status         # the setting and the cached rates; no network
$H --fetch-rates             # one request to Frankfurter, printed, nothing stored
$H --selftest                # includes the window's checks (ranges, totals, CSV, the rate rule, live files…)
```

`--snapshot-usage` renders offscreen like `--snapshot`: no window on screen, no focus. Without `--demo` it
renders your own sessions: keep those images out of the repo. The README's `usage-*.png` and
`usage-more-*.png` come from `tools/make-readme-media.sh` (1280×800 with the first row selected, and the
last row at 1280 wide). The demo's sessions end at a fixed working-hours clock time on their day
(`Demo.end(of:now:)`), so the pictures look alike whenever they are made.

## Traps

- **The system secondary label fails AA on white on macOS 27** (black at 50%, 3.9:1): `UsageStyle.secondaryText`.
- **A menu-style Picker in the toolbar is as wide as its longest item**: real project names pushed the
  other controls into the overflow menu. Fixed widths.
- **`.offset(yEnd:)` does nothing to automatically stacked BarMarks.** The report stacks them itself
  (`DayCost.start`) and a card-coloured `RuleMark` makes the gap.
- **Project colours ranked over all time left a 30-day chart on real data mostly grey.** They go to the
  range's five costliest projects; project, model and find never repaint them.
- **Sessions run in your home folder were named after your account**: they are "~".
- **Offscreen, a scrolled page draws under the transparent toolbar** (no window-server material):
  the second README picture renders the last row alone (`--part breakdown`), not a scrolled window.
- **`Content` is a type of the loader's** (`Loader.swift`), so `ViewModifier`'s `Content` does not resolve
  in this module: small views instead of modifiers.
- `./build.sh` empties `build/`, `build/obj/search-check` included.
