# Agent handoff — Pulse

macOS menu-bar status lamp for coding agents: `idle` / `running` / `needs you`.

A sentence with a version number belongs in CHANGELOG, not here. This file
says what is true now; CHANGELOG says when and why it became true.

## Orientation

| Doc | Read it when |
| --- | --- |
| [`CHANGELOG.md`](CHANGELOG.md) | **Start here** — what shipped, when, and why |
| [`README.md`](README.md) | You want to know what the product is |
| [`docs/architecture.md`](docs/architecture.md) | You need who owns which state, how processes are read, or the version identity — the data flow itself is "Architecture" below |
| [`EXPERIENCE.md`](EXPERIENCE.md) | You are changing anything the user sees — it is the behaviour spec |
| [`docs/scenarios.md`](docs/scenarios.md) | You add or change an acceptance scenario — each row names the tests that pin it |
| [`docs/vendor-formats.md`](docs/vendor-formats.md) | You touch a hook receiver or any per-agent fact — the one place they live: where each hook is installed, what each event becomes, which gives the title and the step; each contract has a pinned source, a test and a weekly drift sentinel |
| [`docs/observability-matrix.md`](docs/observability-matrix.md) | You change what a row claims — the sources, and what is never shown |
| [`docs/attention-protocol.md`](docs/attention-protocol.md) | You touch the event log (`events.tsv`, Attention Protocol v6) or a hook's line |
| [`docs/landing-hosts.md`](docs/landing-hosts.md) | You change how a click lands on a terminal or an editor |

**The roster is seven agents**, an owner decision: Claude, Codex, Cursor (IDE
+ `cursor-agent` CLI), Pi, Gemini CLI, Copilot CLI, OpenCode. Adding one is a
product decision; mechanically it is one `case` and one `AgentSpec` (with its
`HookContract`) in `PulseCore/AgentCatalog.swift`, its receiver adapter in
`PulseHookReceiver`, its icon, README row, a truth table in
`SessionBookTests` and a `hooks` entry in `docs/vendor-formats.json` —
`scripts/catalog_check.py` fails if the roster is not the seven, if a
contract lists a gating event, or if a hook contract has no stated source
or test.

## Invariants

These are product decisions, not preferences. Breaking one is a bug even if it
compiles and ships.

- **No fake Waiting.** Waiting comes from the vendor's own hook / plugin /
  extension event that reports a block (`waiting: .hooks` in the catalog) —
  never from inference. Codex and Cursor have `waiting: .none`: their hooks
  say running and your turn only, the receiver refuses a blocked line for
  them, and the product says "doesn't report when it waits". **Red means
  blocked** — `permission`, `question`, `waiting`. A finished turn (`turn`:
  Claude Stop / `idle_prompt`, Codex Stop) is "your turn": a
  quiet tray count, never the red lamp, never a banner; it comes only from
  hooks and never makes a row of its own.
- **No quota, cost, or reset HUD.** That is a different product. Tokens,
  context, cost, model and plan are not shown, and no source reads a
  `usage` / `token_count` / `rate_limits` / `cost` field (`catalog_check`).
  What a row says — the title (the first prompt), the last step, the last
  words, a turn's error — comes from the events only; Pulse reads no vendor
  file (no session store, no transcript).
- **No judgment transfer, and no blind approve.** Pulse never answers a
  permission request, and the hook receiver never holds — it appends one
  line to the event log and exits. The answer is always given in the vendor's own
  prompt. Forbidden: rules engines, always-allow, auto-approve, approving
  from a truncated summary, and any hold that would freeze an agent.
- **Pulse watches orchestrators; it is not one.** No dispatching sessions,
  no managed runtimes, no worktrees, no running the user's checks, no typing
  into terminals. Bringing any of it back is a product decision, not a
  feature.
- **Pulse keeps no record of its own.** The agents' hooks write the one
  event log (`events.tsv`, append-only, Attention Protocol v6: every hook
  event — start, prompt, tool, block, idle, turn, done, end — one line in
  order); it is the only state that outlives a launch, beside
  `settings.json` and the hook-install ledger. The app appends to it only a
  `done` for a dismissal. What the banner remembers (`WaitLedger`) is in
  memory. A log whose header is not v6 is treated as absent — emptied and
  started over, never read or migrated.
- **Old versions do not exist.** No migration, no compatibility read, no
  cleanup of what an earlier version left: `settings.json` decodes only the
  current keys, the receiver and the installer know only the current marker
  and ledger, and the login item is `SMAppService` alone.
- **Pulse makes no network connection.** No update check, no telemetry:
  Settings' "Releases…" opens the releases page in the browser
  (`catalog_check` refuses `URLSession` and its cousins).
- **Replay before the first projection.** At launch `ScanEngine` reads the
  whole log, applies every line in order to `SessionBook`, and only then
  projects; that projection is the banner baseline. After it the engine
  reads only the bytes after its cursor. A log rewritten by a compaction (a
  new generation in its header) is read whole again and only lines not
  already applied are applied. A failed or empty read changes nothing — it
  never resets what was applied, so an answered block is never replayed red.
- **The log is bounded without losing an answer.** An append that would
  pass `EventLog.maxBytes` compacts first: per session (per agent + folder
  for a session-less one) the last lines and every recent line stay, an
  open block is kept with everything after it in its session, and the line
  being appended is always kept. A rewritten log is re-read whole and its
  lines are matched to the applied ones by position (`EventLog.unapplied`),
  never by text alone; lines end at `\n` bytes only.
- **A source failure must not blank the tray.** A failed libproc scan keeps
  the last good process list; a failed log read keeps what was applied and
  is retried on one backing-off timer (5 s → 60 s); neither ever removes a
  session, and only the launch replay is a banner baseline. Sessions leave only by an event (`end`), a
  process exit (or a pid now running another process — `AgentProcesses.stillRuns`),
  the idle bound, the silent bound or the one-day prune. A live process keeps
  a working or blocked session listed, never an idle or recent one: one
  Cursor or OpenCode process runs many sessions all day.
- **Event-driven, no fixed probe interval.** State moves when the event log
  changes (one `DispatchSource`) or a session's process exits (a per-pid exit
  source). Besides that there is one cheap tick (`ProbeSchedule.tick`: 5 s
  with the tray open or a fresh wait, else 60 s, stopped when nothing is
  listed) and the libproc scan (at launch, on wake, for an unknown hook pid,
  and on a one-shot timer backing off 30 s → 5 min); low power doubles both,
  a sleeping display stops both — a resident menu-bar app flagged for energy
  use is a dead product.
- **The reducer and the projection stay pure.** `SessionBook.apply` and
  `TrayState.project` take the world as values and return values. Side
  effects belong in `ScanEngine`, `WaitNotifier` and `StatusStore`.
- **Install only each supported vendor's documented hook/plugin, only events
  that cannot change the agent's decisions** (never PreToolUse /
  beforeShellExecution-style gating hooks, never anything that returns a
  decision), **and every install is reversible byte-for-byte.** The installer
  is driven by the catalog's `HookContract`s; `HookContract.gatingEvents`
  lists what is never installed, and an event that is not installed is not
  read; `hook-installs.json` records what each install replaced. Codex is
  `hooks.json` only — `config.toml` is never touched. See
  [`docs/attention-bridge.md`](docs/attention-bridge.md).
- **QA code never ships.** Fixtures, captures and the preview window live in
  the `PulseQA` executable; the app is `PulseBar` alone.
  `scripts/surface_check.py` keeps the QA files out of `PulseApp` and
  `scripts/package_check.py` fails an app binary that carries a QA flag.

## Architecture

Everything is Swift under `PulseBar/`, five targets, dependencies pointing
down only:

| Target | Kind | What it holds |
| --- | --- | --- |
| `PulseCore` | library | the agent catalog, bounded and private IO, process supervision, the cadence, the debug log (members `public`) |
| `PulseHarvest` | library | the event sources: the event log (`EventLog`: append, read from a cursor, compact, match a rewrite to what was applied), libproc `AgentProcesses`, `RowIdentity`, `TitleHeuristics` (members `package`) |
| `PulseApp` | library | `SessionBook` → `TrayState` → `StatusStore`, `ScanEngine`, `WaitNotifier` + `WaitLedger`, the hook receiver and installer, every view; owns the resources (`PulseResources`, never `Bundle.module`) |
| `PulseBar` | executable | `PulseBarMain.main()` and nothing else — the shipping app |
| `PulseQA` | executable | `SurfaceFixtures`, `SurfaceCapture`, `StatusStoreFixture`, `TrayPreviewWindowController`, `QADriver` (`@testable import PulseApp`, debug only) |

No library imports AppKit or SwiftUI below `PulseApp`, and none reaches
`StatusStore`. Data flow: a hook appends a line to `events.tsv` →
`AttentionWatcher` wakes `ScanEngine`, which reads the bytes after its cursor
and applies those lines, in order, to `SessionBook` (at launch: the whole log,
before the first projection) → `TrayState.project(book:processes:context:)`
returns rows (each with its last steps and its turn's clock), lamp, title,
one `TrayState.Counts` (counted once; the header, the lamp and VoiceOver
read it) and newly-blocked edges → `StatusStore.land` assigns an
observed property only when it changed; a projection from an event read that
moves only quiet facts (`TrayState.quietSignature`: steps, clocks) lands at
most once per tick →
`WaitNotifier` plans banners from the edges (a wait raised in front of the
person waits 30 s and its app leaving the front) and withdraws each banner
when its wait is answered, dismissed or ends (`WaitLedger` keeps the ids).
`TrayRowModel` says every row's headline and why (the detail page says the
same words), and `TrayState.lampSentence` the lamp's one-sentence rule. How
Pulse reads a session is in Settings → Hooks → "Copy report", not on the
detail page.

## Working on it

```bash
cd PulseBar && swift build      # targets macOS 14+; needs Xcode 26 / Swift 6.2+ (CI: macos-26)
cd PulseBar && swift test       # test count is reported by SwiftPM/CI
```

Every target is in the Swift 6 language mode; every product target treats
warnings as errors. Tests live in `PulseBar/Tests/PulseBarTests/`, one file
per component: `CoreTests` (catalog, bounded IO, libproc processes),
`VendorFormatTests` (hook
contracts and drift), `AttentionTests` (the book reading event lines, the
protocol, the event log, the hook receiver, the installer), `SessionTests` (the seven agents' truth
tables, `TrayState`, identity), `NotifierTests` (`WaitLedger`,
delivery, routing), `TrayTests` (the row's words, the lamp, keys, detail), `SettingsTests`, `DiagnosticsTests` (the
report, the hooks section, the tray notice, the version),
`EngineTests`. A new test goes in the file of the component it tests — never
a file named after a release. `docs/scenarios.md` names suites and methods,
and `scenario_map.py` checks both exist.

Gates, from the repo root — CI, `release.yml`, `scripts/release.sh` and
`package.sh` all run the same list:

```bash
bash scripts/gates.sh                        # every source gate (below)
python3 scripts/package_check.py             # reads the built .app
./scripts/qa_captures.sh                     # surface + status fixture PNGs (builds and runs PulseQA)
```

`gates.sh` runs `version_check` (one semver), `catalog_check` (roster,
libproc-only process rules, privacy rules, no token / usage / cost reads,
no gating event, hook sources), `make_agent_icons --check`,
`surface_check` (surfaces render values; a step never says "running"),
`scenario_map` and a `Bundle.module` grep. A gate earns its place by guarding
a real fact; one that only checks prose or long-deleted code is removed, not
kept "just in case".

**The wall that catches a state regression** is `swift test`:
`SessionBookTests` holds a truth table per agent, `TrayStateTests` and
`TrayAssembleTests` the running / recent / process-only rules and the lamp,
`everyAgentsStepsComeFromItsOwnHook` where each agent's title and steps come
from. A wrong tray
state is fixed with a failing test there — a source-string gate cannot do
that job. `ScanQuietTests` lists every observed `StatusStore` property; a
projection that finds the same world must announce nothing.

No path forks an interpreter to observe a session, and a missing Python
runtime must never block the app, the hooks, or `--selftest`.

**Version truth:** `PulseBar/Sources/PulseApp/Models.swift` →
`PulseVersion.semver`. CHANGELOG's newest heading and the README badge follow
it.

Debug log: `~/Library/Application Support/Pulse/debug.log` (rolls at 2 MB).
User-facing diagnostics are Settings → Hooks and its "Copy report".

## Ship

```bash
./PulseBar/Scripts/package.sh
open zig-out/package/Pulse.app
```

`package.sh` builds `--product PulseBar` in release and packages only it.
Local packaging uses `PULSE_SIGN_IDENTITY` plus `PULSE_NOTARY_PROFILE` for a
distributable build. Release CI uses the base64 Developer ID certificate,
password and App Store Connect API key secrets when available. Without an
Apple Developer account it still publishes GitHub **Latest** for the current
semver, but the binary stays `preview` / ad-hoc / unnotarized — that artifact
must never be labeled `stable` or Gatekeeper-ready (`PulseDistributionChannel`
keeps it honest). Release notes and the DMG's first-launch note lead with
System Settings → Privacy & Security → "Open Anyway" and give
`xattr -dr com.apple.quarantine` as the Terminal alternative (macOS 15
removed Control-click → Open). Every release carries the DMG's `.sha256`
beside it.

"Open at login" is `SMAppService.mainApp`: it works only for an app in a
bundle (a `swift run` shell reads `unavailable`), and macOS may hold it for
approval in System Settings → Login Items, which Settings says. Time
Sensitive banners need the
`com.apple.developer.usernotifications.time-sensitive` entitlement, which
takes a Developer ID with a provisioning profile; Pulse sets the level only
when macOS reports the setting enabled, so without it the banner is an
ordinary one. Never add that entitlement to an ad-hoc build — an
unprovisioned `com.apple.developer.*` entitlement keeps the app from
launching.

## Release

Write the `## x.y.z` section in CHANGELOG.md first — every path refuses
without it. `version_check.py --fix` updates the README only; it never renames
a CHANGELOG heading.

```bash
./scripts/release.sh X.Y.Z            # dry run: bump + gates + diff
./scripts/release.sh X.Y.Z --commit   # commit carrying the [release] marker
./scripts/release.sh X.Y.Z --commit --prerelease   # … [release] [prerelease]
git push                              # CI builds, tags and publishes
```

| Trigger | When |
| --- | --- |
| `[release]` in the pushed commit subject | default; **`main` only** |
| `[release] [prerelease]` in the pushed commit subject | the same build and notes, published as a GitHub **prerelease**; **`main` only** |
| a `v*.*.*` tag push | if you prefer explicit tags and have tag-write rights; any branch |
| `workflow_dispatch` | from the Actions tab |

The marker path is limited to `main` so a release is never cut from a branch
nobody has reviewed. CI verifies the version matches `PulseVersion.semver`,
runs gates and tests, packages the DMG, and publishes a Release whose body is
that version's CHANGELOG section. **It creates the tag with its own
`contents: write` token** — publishing does not depend on any developer's or
agent's local credentials. A version that already has a Release is refused,
so re-pushing is harmless. Pulse checks for no update: Settings' "Releases…"
opens the releases page, where an untagged version does not exist.

**A prerelease is invisible to GitHub Latest** (it is published with `prerelease: true`, `make_latest: false`).
Use it for a version not yet run on a real Mac. After the owner's real-Mac
smoke run, the owner promotes it by editing the release on GitHub: untick
"Set as a pre-release" and tick "Set as the latest release" — or pushes a
commit to `main` with `[promote]` in its subject, and the `promote` job does
the same and rewrites the notes from the current CHANGELOG section (the
Gatekeeper and checksum blocks stay). Nothing is rebuilt: the DMG and its
`.sha256` are already the release's.
`workflow_dispatch` has a `prerelease` switch for the same thing.

## Versioning and language

- A **major** version is for a breaking change to persisted state, a
  protocol, or a removed capability — or a structural change that alters how
  the code is extended. A UI pass is a minor. A schema migration never ships
  in a patch. Every version that lands on `main` is released; do not bump
  without releasing, and do not reserve a number for blocked work.
- A sentence with a version number belongs in CHANGELOG. Code comments and
  docs say what is true now.
- Code comments and agent-facing docs (this file, protocols) are English.
  User-facing copy, CHANGELOG, plans and reviews are Chinese.
- Every target builds warning-free under complete concurrency checking. A
  value that crosses a queue by convention goes in `Unchecked` with a comment
  saying why; prefer `Sendable` types and `Guarded`.
- **A new surface comes with a model, a fixture and a capture**: a pure value
  in `PulseApp`, a fixture in `PulseQA/SurfaceFixtures.swift`, and a PNG from
  `qa_captures.sh`.
