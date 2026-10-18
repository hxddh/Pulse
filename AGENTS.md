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
| [`docs/attention-protocol.md`](docs/attention-protocol.md) | You touch the event log (`events.tsv`, Attention Protocol v8) or a hook's line |
| [`docs/vendor-formats.md`](docs/vendor-formats.md) | You touch a hook receiver, the installer or any per-agent fact — each contract has a pinned source (`vendor-formats.json`), a test and a weekly drift sentinel |

The tests are the spec's proof: a behaviour is pinned by a test in the file of
its component, not by a document.

**The roster is six agents**, an owner decision: Claude Code, Codex, Cursor
(IDE + `cursor-agent` CLI), Pi, Copilot CLI, OpenCode. Adding one is a
product decision; mechanically it is one `case` in
`PulseKit/Agents/Agents.swift`, one adapter file beside it (its `AgentSpec`:
identity, process rule, waiting source, `HookContract` with each event's
action, and a `read` for payload-dependent events), its icon, README row, a
truth table in `SessionBookTests`, a `hooks` entry in
`docs/vendor-formats.json` and a recorded payload per installed event
(`PulseBar/Tests/Fixtures/hooks/<agent>/`, its line in `expected.json`). Nothing outside `Agents/` switches on an agent
or spells a vendor event (`catalog_check`).

## Invariants

Product decisions, not preferences. Breaking one is a bug even if it ships.

- **No guessed state.** A row says what the events prove. Only an agent
  that reports a tool start (`HookContract.silenceCanStall`: Pi, OpenCode)
  can stall; for the rest a long command and a stuck one look the same, so
  their rows never turn orange. Settings says nothing a process's start
  time or a compacted log cannot prove.
- **No fake Waiting.** Waiting comes only from the vendor's own hook / plugin /
  extension event that reports a block (`waiting: .hooks`). Codex and Cursor
  are `waiting: .none`: the receiver writes an `ignored` line instead of a
  blocked one, the reducer refuses one whoever wrote it, and the product says
  "doesn't report when it waits". A request nobody can be shown (Claude's
  `dontAsk`, `claude -p` without a permission host) and a notice that may
  be another session's (Claude's `agent_needs_input`) are `ignored` lines
  too. **Red means blocked** —
  `permission`, `question`, `waiting`. A finished turn (`turn`) is "your
  turn": a quiet tray count, never red, never a banner, never a row of its own.
- **A subagent is not the person.** A line carries the vendor's subagent id
  (`sub`) when a subagent wrote it. It never answers a block the main agent
  (or another subagent) raised, never revives a turn that has ended, and its
  prompt is never the person's prompt (no title, no turn clock); its steps
  are marked as its own. A Pi subagent (`--mode json`) sends nothing.
- **No quota, cost or reset HUD.** Tokens, context, cost, model and plan are
  not shown and no source reads a `usage` / `token_count` / `rate_limits` /
  `cost` field. What a row says comes from the events only; Pulse reads no
  vendor file (no session store, no transcript) — besides the hook configs
  the installer edits and, read-only for Settings, the vendor settings
  that silence hooks (`HookContract.offSwitches`).
- **No judgment transfer, no blind approve.** Pulse never answers a
  permission request; the answer is always given in the vendor's own prompt.
  The hook receiver never holds — it appends one line and exits. No rules
  engine, always-allow or auto-approve.
- **Pulse watches orchestrators; it is not one.** No dispatching sessions,
  managed runtimes, worktrees, running checks or typing into terminals.
- **No network.** Pulse makes no network connection; "Releases…" opens the
  releases page in the browser.
- **Pulse keeps no record of its own.** The hooks write the one event log
  (`events.tsv`, append-only, v8); beside it only `settings.json`, the
  hook-install ledger and `debug.log` outlive a launch. The app appends only a
  `dismiss` (a wait set aside, a finished turn looked at). Banner bookkeeping
  (`WaitLedger`) is in memory. A log that is not v8 is treated as absent and
  started over — never read or migrated.
- **Every heard event is one line.** The receiver writes a state line, or an
  `ignored` line that says why not (an event not installed, a payload that is
  not JSON, a blocked event from an agent that cannot report one, a vendor
  prompt that does not block) — never the payload's words. The reducer changes no state for `ignored`; it goes on its
  session's timeline and Settings' "last not used" — it is there to be read.
- **Replay before the first projection.** At launch `ScanEngine` applies the
  whole log, in order, to `SessionBook`, and only then projects; that
  projection is the banner baseline. Every line carries a `seq` assigned
  under the append lock; after the replay only the bytes past the cursor are
  read, and only lines numbered past the last applied are applied. A
  rewritten log (a compaction keeps the log's `gen` and every kept line's
  `seq`) is read whole and applied past that number; a log started over
  (another `gen`) is applied whole. Identity is the number, never the text.
  A failed or empty read changes nothing.
- **The log is bounded without losing an answer.** Compaction keeps, per
  session, the recent lines, an open block with everything after it, the
  lines a replay rebuilds the title and clocks from, and always the line being
  appended — each under its own `seq`. Lines end at `\n` bytes only.
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
  The projection carries state only (`AgentRow.Status`); what moves with
  every tool line — steps, last words, clocks, the vendor events behind the
  state and the timeline (`SessionFacts`) — is read from the book when a row
  is drawn, so a projection that finds the same world is equal and lands
  nothing.
- **Install only documented, observe-only hooks, reversibly.** Never a gating
  event (`HookContract.gatingEvents`: PreToolUse, beforeShellExecution, an
  event whose hook takes the vendor's place — Elicitation, WorktreeCreate,
  MessageDisplay — …), never anything whose decision the vendor reads; an
  event not installed is not read. Async neutralizes decision output: the
  vendor reads no decision from an `async` entry, so an event whose only
  control is a decision (Claude's `PermissionDenied` `retry`,
  `SubagentStop`) is observe-only installed async. One documented exception
  (owner decision): Copilot's `agentStop`/`postToolUse` are synchronous and
  could return a decision; Pulse's hook appends one line and prints nothing,
  so it never decides. A plugin or extension Pulse owns reads the vendor's
  event stream only (OpenCode's bus, Pi's events) — never a hook that can
  change a tool, a message or a permission — and its handlers never throw,
  never return a decision and never block. Every install is
  reversible byte-for-byte (`hook-installs.json`). Codex is `hooks.json`
  only — `config.toml` is never touched, not even read. No environment
  variable is followed for where a vendor reads its config (a GUI app cannot
  see the shell's): a folder a variable can move (Pi's `PI_CODING_AGENT_DIR`,
  OpenCode's `OPENCODE_CONFIG_DIR` / `XDG_CONFIG_HOME`, Copilot's
  `COPILOT_HOME`) is said in Settings when the default is missing, never
  guessed.
- **QA code never ships.** Fixtures, captures and the preview window live in
  the `PulseQA` executable; the app is `PulseBar` alone.

## Architecture

Swift under `PulseBar/`, four targets (and the tests), dependencies
pointing down only:

| Target | Kind | What it holds |
| --- | --- | --- |
| `PulseKit` | library, Foundation only | the agent adapters (`Agents/`), the protocol, `EventLog`, the hook receiver and installer (`JSONSplice`, the ledger), libproc `AgentProcesses`, `SessionBook` → `TrayState`, `WaitLedger`, `WaitingDelivery`, `LandingPlan`, every surface model (`TrayRowModel`, `DetailModel`, `SettingsModel`, `Connection`, `TrayKeys`…), `L10n`, bounded and private IO, the cadence, the debug log (members `package`) |
| `PulseApp` | library | `ScanEngine` and the watchers, `StatusStore`, `WaitNotifier` + `PulseNotify`, `TerminalFocus`, `StatusItemController`, every view, the login item; owns the resources (`PulseResources`, never `Bundle.module`) |
| `PulseBar` | executable | `PulseBarMain.main()` — the shipping app |
| `PulseQA` | executable | fixtures, captures, the preview window, `QADriver` (`@testable import PulseApp`, `PulseKit`) |

`PulseKit` imports no AppKit, SwiftUI, UserNotifications or
ServiceManagement (`surface_check`) and never reaches `StatusStore`; the
`--hook` path runs in it without starting AppKit.

Data flow: a hook appends one numbered line to `events.tsv` →
`AttentionWatcher` wakes `ScanEngine`, which applies the lines numbered past
its cursor to `SessionBook` → `TrayState.project(book:processes:context:)`
returns rows (each with one `AgentRow.Status` — state only), lamp, title, one
`TrayState.Counts` and newly-blocked edges → `StatusStore.land` assigns an
observed property only when it changed (plain equality: the projection
carries no step and no clock) → `WaitNotifier` plans one banner per wait from
the edges and withdraws it when the wait is answered, dismissed or ends.
`TrayRowModel` says every row's headline and why — citing the vendor event
that caused the state — from the row and its `SessionFacts`, read from the
book when it is drawn (the tray's `TimelineView` clock); the detail page
says the same words and draws the session's timeline. Settings → Hooks says
each agent's `Connection` (install complete / partial / stale / failed, the
event heard last, the last one not used). Every key inside
Pulse is a `SessionKey`; its `description` is the one string that leaves the
process (a banner's id and user info).

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
receiver, installer), `SessionTests` (the six agents' truth tables,
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
node scripts/js_adapters_test.mjs     # the Pi extension and OpenCode plugin under Node
./scripts/e2e.sh                      # after package.sh: installer → pulse-hook → PulseBar --hook → snapshot
```

The proof layers (recorded payloads, the modules under Node, the end-to-end
run, the owner's `scripts/smoke.sh`) are in `docs/architecture.md` → Proof;
their flags live in `PulseQA` and `package_check.py` fails an app carrying one.

`gates.sh` runs `version_check` (one semver), `catalog_check` (roster, one
adapter file per agent and no vendor event spelled outside `Agents/`, hook
contracts and their sources, no gating event, libproc only, AppleScript only
in `TerminalFocus`, no network API, no token / usage / cost reads),
`make_agent_icons --check`, `surface_check` (views render values, the pure
models stay in `PulseKit` and it imports no UI framework, QA files stay in
`PulseQA`, a why never says "hook", a step never says "running", and the
one live line — "Now: …", `nowLine` — reads only `SessionFacts.running`) and
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
Terminal alternative. Every release carries the DMG's `.sha256` and a
build-provenance attestation (`actions/attest-build-provenance`, checked
with `gh attestation verify <dmg> -R hxddh/Pulse`; the release job alone
holds `id-token` / `attestations: write`). Provenance is not notarization.

Distribution is the DMG only — no Homebrew, no Sparkle, no update check.
The DMG (`pulse-<ver>-macos-PulseBar.dmg`, volume "Pulse", the app icns as
volume icon) opens to Pulse.app left, an arrow, an `/Applications` link
right, and — unnotarized builds only — "首次打开必读 · Read Me First.txt"
below. `scripts/make_dmg_art.py` draws the background (shapes only, no
text) and writes `PulseBar/Packaging/DMG/layout.json`, the one source of
the geometry (`--check` in `gates.sh`); `dmgbuild` with `DMG/settings.py`
writes the window's `.DS_Store` headlessly. dmgbuild is a hash-pinned
packaging tool (`DMG/requirements.txt`) that CI installs into a throwaway
venv and passes as `PULSE_DMGBUILD`; it never ships. The layout is
cosmetic: dmgbuild missing or failing falls back to a plain `hdiutil` image
that still holds the app, the link and the guide — package.sh mounts the
result and fails only when one of those is missing.

When `xcrun -f actool` exists, package.sh compiles the Icon Composer bundle
`PulseBar/Packaging/Pulse.icon` (from `make_brand.py`) to `Assets.car` and
adds `CFBundleIconName=Pulse` only then; `CFBundleIconFile=AppIcon` and
`AppIcon.icns` are always there. An actool failure warns and ships the
icns alone. `package_check.py` requires the icns, allows `Assets.car`, and
fails a `CFBundleIconName` without it.

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
