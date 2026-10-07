# Agent handoff — Pulse

macOS menu-bar status lamp for coding agents: `idle` / `running` / `needs you`.

This file says what is true now. A sentence with a version number belongs in
CHANGELOG.

## Orientation

| Doc | Read it when |
| --- | --- |
| [`CHANGELOG.md`](CHANGELOG.md) | **Start here** — what shipped, when, and why |
| [`README.md`](README.md) | You want to know what the product is |
| [`EXPERIENCE.md`](EXPERIENCE.md) | You change anything the user sees — it is the behaviour spec |
| [`docs/architecture.md`](docs/architecture.md) | You need who owns which state, how processes are read, how a click lands, or the version identity |
| [`docs/attention-protocol.md`](docs/attention-protocol.md) | You touch the event log (`events.tsv`, Attention Protocol v6) or a hook's line |
| [`docs/vendor-formats.md`](docs/vendor-formats.md) | You touch a hook receiver, the installer or any per-agent fact — each contract has a pinned source (`vendor-formats.json`), a test and a weekly drift sentinel |

The tests are the spec's proof: a behaviour is pinned by a test in the file of
its component, not by a document.

**The roster is seven agents**, an owner decision: Claude, Codex, Cursor (IDE
+ `cursor-agent` CLI), Pi, Gemini CLI, Copilot CLI, OpenCode. Adding one is a
product decision; mechanically it is one `case` and one `AgentSpec` (with its
`HookContract`) in `PulseCore/AgentCatalog.swift`, its receiver adapter in
`PulseHookReceiver`, its icon, README row, a truth table in
`SessionBookTests` and a `hooks` entry in `docs/vendor-formats.json`.

## Invariants

Product decisions, not preferences. Breaking one is a bug even if it ships.

- **No fake Waiting.** Waiting comes only from the vendor's own hook / plugin /
  extension event that reports a block (`waiting: .hooks`). Codex and Cursor
  are `waiting: .none`: the receiver refuses a blocked line for them and the
  product says "doesn't report when it waits". **Red means blocked** —
  `permission`, `question`, `waiting`. A finished turn (`turn`) is "your
  turn": a quiet tray count, never red, never a banner, never a row of its own.
- **No quota, cost or reset HUD.** Tokens, context, cost, model and plan are
  not shown and no source reads a `usage` / `token_count` / `rate_limits` /
  `cost` field. What a row says comes from the events only; Pulse reads no
  vendor file (no session store, no transcript).
- **No judgment transfer, no blind approve.** Pulse never answers a
  permission request; the answer is always given in the vendor's own prompt.
  The hook receiver never holds — it appends one line and exits. No rules
  engine, always-allow or auto-approve.
- **Pulse watches orchestrators; it is not one.** No dispatching sessions,
  managed runtimes, worktrees, running checks or typing into terminals.
- **No network.** Pulse makes no network connection; "Releases…" opens the
  releases page in the browser.
- **Pulse keeps no record of its own.** The hooks write the one event log
  (`events.tsv`, append-only, v6); beside it only `settings.json`, the
  hook-install ledger and `debug.log` outlive a launch. The app appends only a
  `done` for a dismissal. Banner bookkeeping (`WaitLedger`) is in memory. A log
  that is not v6 is treated as absent and started over — never read or
  migrated.
- **Replay before the first projection.** At launch `ScanEngine` applies the
  whole log, in order, to `SessionBook`, and only then projects; that
  projection is the banner baseline. After it only the bytes past the cursor
  are read. A rewritten log (new generation) is read whole and matched to the
  applied lines by position (`EventLog.unapplied`), never by text alone. A
  failed or empty read changes nothing.
- **The log is bounded without losing an answer.** Compaction keeps, per
  session, the recent lines, an open block with everything after it, the
  lines a replay rebuilds the title and clocks from, and always the line being
  appended. Lines end at `\n` bytes only.
- **A source failure must not blank the tray.** A failed libproc scan keeps
  the last good list; a failed log read keeps what was applied and retries on
  one backing-off timer (5 s → 60 s). Sessions leave only by an `end`, a
  process exit (or a reused pid — `AgentProcesses.stillRuns`), the idle bound,
  the silent bound or the one-day prune. A live process keeps a working or
  blocked session listed, never an idle or recent one.
- **Event-driven, no fixed probe interval.** State moves when the log changes
  (one `DispatchSource`) or a session's process exits (a per-pid exit source).
  Besides that: one cheap tick (`ProbeSchedule`: 5 s with the tray open or a
  fresh wait, else 60 s, stopped when nothing is listed) and the libproc scan
  (launch, wake, an unknown hook pid, and a timer backing off 30 s → 5 min).
  Low power doubles both; a sleeping display stops both.
- **The reducer and the projection stay pure.** `SessionBook.apply` and
  `TrayState.project` take values and return values. Side effects live in
  `ScanEngine`, `WaitNotifier` and `StatusStore`.
- **Install only documented, observe-only hooks, reversibly.** Never a gating
  event (`HookContract.gatingEvents`: PreToolUse, beforeShellExecution, …),
  never anything that returns a decision; an event not installed is not read.
  Every install is reversible byte-for-byte (`hook-installs.json`). Codex is
  `hooks.json` only — `config.toml` is never touched.
- **QA code never ships.** Fixtures, captures and the preview window live in
  the `PulseQA` executable; the app is `PulseBar` alone.

## Architecture

Swift under `PulseBar/`, five targets, dependencies pointing down only:

| Target | Kind | What it holds |
| --- | --- | --- |
| `PulseCore` | library | the agent catalog, the protocol, bounded and private IO, process supervision, the cadence, the debug log (members `public`) |
| `PulseHarvest` | library | `EventLog` (append, read from a cursor, compact, match a rewrite), libproc `AgentProcesses`, `RowIdentity`, `TitleHeuristics` (members `package`) |
| `PulseApp` | library | `SessionBook` → `TrayState` → `StatusStore`, `ScanEngine`, `WaitNotifier` + `WaitLedger`, the hook receiver and installer, every view; owns the resources (`PulseResources`, never `Bundle.module`) |
| `PulseBar` | executable | `PulseBarMain.main()` — the shipping app |
| `PulseQA` | executable | fixtures, captures, the preview window, `QADriver` (`@testable import PulseApp`) |

No library below `PulseApp` imports AppKit or SwiftUI, and none reaches
`StatusStore`.

Data flow: a hook appends a line to `events.tsv` → `AttentionWatcher` wakes
`ScanEngine`, which applies the new lines to `SessionBook` →
`TrayState.project(book:processes:context:)` returns rows, lamp, title, one
`TrayState.Counts` and newly-blocked edges → `StatusStore.land` assigns an
observed property only when it changed (a projection that moves only quiet
facts — steps, clocks — lands at most once per tick) → `WaitNotifier` plans
one banner per wait from the edges and withdraws it when the wait is
answered, dismissed or ends. `TrayRowModel` says every row's headline and
why; the detail page says the same words.

## Working on it

```bash
cd PulseBar && swift build      # macOS 14+; Xcode 26 / Swift 6.2+ (CI: macos-26)
cd PulseBar && swift test
```

Every target is in the Swift 6 language mode with complete concurrency
checking; every product target treats warnings as errors. A value that
crosses a queue by convention goes in `Unchecked` with a comment saying why;
prefer `Sendable` types and `Guarded`.

Tests live in `PulseBar/Tests/PulseBarTests/`, one file per component:
`CoreTests`, `VendorFormatTests`, `AttentionTests` (protocol, event log,
receiver, installer), `SessionTests` (the seven agents' truth tables,
`TrayState`, identity), `NotifierTests`, `TrayTests`, `SettingsTests`,
`DiagnosticsTests`, `EngineTests`. A new test goes in its component's file.
A wrong tray state is fixed with a failing test — `SessionBookTests`,
`TrayStateTests`, `TrayAssembleTests`, `HookToBannerTests` — not a source
gate. `ScanQuietTests` lists every observed `StatusStore` property: a
projection that finds the same world announces nothing.

No path forks an interpreter to observe a session; a missing Python never
blocks the app, the hooks or `--selftest`.

**Gates**, from the repo root — CI, `release.yml`, `scripts/release.sh` and
`package.sh` all run `gates.sh`:

```bash
bash scripts/gates.sh                 # source gates
python3 scripts/package_check.py      # the built .app: flat resource bundle, no QA code
./scripts/qa_captures.sh              # surface + status fixture PNGs (PulseQA)
```

`gates.sh` runs `version_check` (one semver), `catalog_check` (roster, hook
contracts and their sources, no gating event, libproc only, AppleScript only
in `TerminalFocus`, no network API, no token / usage / cost reads),
`make_agent_icons --check`, `surface_check` (views render values, QA files
stay in `PulseQA`, a why never says "hook", a step never says "running") and
a `Bundle.module` grep. `vendor_drift.py` runs weekly
(`vendor-drift.yml`). A gate earns its place by guarding a real fact.

**Version truth:** `PulseBar/Sources/PulseApp/Models.swift` →
`PulseVersion.semver`. CHANGELOG's newest heading and the README badge follow
it. Debug log: `~/Library/Application Support/Pulse/debug.log` (rolls at
2 MB). User-facing diagnostics: Settings → Hooks → "Copy report".

## Ship

```bash
./PulseBar/Scripts/package.sh       # release build of PulseBar only, then package_check + --selftest
open zig-out/package/Pulse.app
```

Local distributable builds use `PULSE_SIGN_IDENTITY` and
`PULSE_NOTARY_PROFILE`; release CI uses the base64 Developer ID certificate,
password and App Store Connect API key secrets when present. Without them it
still publishes, but the build is `preview` / ad-hoc / unnotarized and must
never be labelled `stable` or Gatekeeper-ready (`PulseDistributionChannel`).
Release notes and the DMG's note lead with System Settings → Privacy &
Security → "Open Anyway", with `xattr -dr com.apple.quarantine` as the
Terminal alternative. Every release carries the DMG's `.sha256`.

"Open at login" is `SMAppService.mainApp` (works only from a bundle; macOS
may hold it for approval). Never add the
`com.apple.developer.usernotifications.time-sensitive` entitlement to an
ad-hoc build — an unprovisioned `com.apple.developer.*` entitlement keeps the
app from launching; Pulse marks a banner time-sensitive only when macOS
reports it allowed.

## Release

Write the `## x.y.z` section in CHANGELOG.md first — every path refuses
without it (`version_check.py --fix` updates the README only).

```bash
./scripts/release.sh X.Y.Z                         # dry run: bump + gates + diff
./scripts/release.sh X.Y.Z --commit                # commit with [release]
./scripts/release.sh X.Y.Z --commit --prerelease   # … [release] [prerelease]
git push                                           # CI builds, tags, publishes
```

| Trigger | When |
| --- | --- |
| `[release]` in the pushed commit subject | default; `main` only |
| `[release] [prerelease]` | same build, published as a GitHub prerelease; `main` only |
| a `v*.*.*` tag push | any branch |
| `workflow_dispatch` | Actions tab (has a `prerelease` switch) |

CI checks the version against `PulseVersion.semver`, runs gates and tests,
packages the DMG and publishes a Release whose body is that CHANGELOG
section; it creates the tag with its own `contents: write` token. A version
that already has a Release is refused. A prerelease is not GitHub Latest; the
owner promotes it after a real-Mac run by editing the release, or by pushing
a commit to `main` with `[promote]` in its subject (nothing is rebuilt).

## Versioning and language

- **Major**: a breaking change to persisted state or a protocol, a removed
  capability, or a structural change to how the code is extended. A UI pass
  is a minor. A schema change never ships in a patch. Every version that
  lands on `main` is released; never reserve a number.
- Code comments and agent-facing docs (this file, the protocol, vendor
  formats, architecture) are English. User-facing copy, CHANGELOG,
  EXPERIENCE, README, plans and reviews are Chinese.
- **A new surface comes with a model, a fixture and a capture**: a pure value
  in `PulseApp`, a fixture in `PulseQA/SurfaceFixtures.swift`, a PNG from
  `qa_captures.sh`.
