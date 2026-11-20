# Agent handoff — Pulse

macOS menu-bar status lamp for coding agents: idle / running / needs you.
This file says what is true now; a sentence with a version number belongs in
CHANGELOG. Tests are the spec's proof — a behaviour is pinned by a test in
its component's file, not by a document.

| Doc | Read it when |
| --- | --- |
| [`CHANGELOG.md`](CHANGELOG.md) | **Start here** — what shipped and why |
| [`EXPERIENCE.md`](EXPERIENCE.md) | You change anything the user sees (the behaviour spec, Chinese) |
| [`docs/architecture.md`](docs/architecture.md) | Who owns which state, processes, landing, proof layers |
| [`docs/attention-protocol.md`](docs/attention-protocol.md) | The event log (`events.tsv`, protocol v10) or a hook's line |
| [`docs/vendor-formats.md`](docs/vendor-formats.md) | A hook receiver, the installer, any per-agent fact (`vendor-formats.json`, weekly drift check) |

**Six agents**, an owner decision: Claude Code, Codex, Cursor (IDE + CLI), Pi,
Copilot CLI, OpenCode. Adding one: a `case` in `PulseKit/Agents/Agents.swift`,
its adapter file (`AgentSpec`: process rule, waiting source, `HookContract`,
`read`), icon, README row, truth table in `SessionBookTests`, a `hooks` entry
in `vendor-formats.json`, a recorded payload per installed event
(`Tests/Fixtures/hooks/<agent>/` + `expected.json`). Nothing outside `Agents/`
switches on an agent or spells a vendor word (`catalog_check`).

## Invariants — product decisions; breaking one is a bug

- **No guessed state.** A row says what the events prove. Only agents that
  report a tool start (`silenceCanStall`: Pi, OpenCode) can read "quiet"
  (orange).
- **No fake waiting. Red means blocked** (`permission`, `question`,
  `waiting`), and only from the vendor's own blocking event. Codex and
  Cursor cannot report one (`waiting: .none`): their blocked lines are
  `ignored`. A request nobody can be shown, or a notice that may be another
  session's, is `ignored` too. A finished turn is "done" (好了): a quiet
  count, never red, and a banner only when the person asked for that turn
  (`TurnWatch`). Muting an agent stops its banners, not its lamp.
- **A subagent is not the person.** In the reducer it is a `Speaker`: it
  never answers a block it did not raise, never revives an ended turn, and
  its prompt is never the person's.
- **No quota, cost, token, model or plan HUD**; no source reads `usage` /
  `token_count` / `rate_limits` / `cost`. Pulse reads no vendor session
  file — only the hook configs it edits and, read-only, the settings that
  silence hooks (`offSwitches`).
- **No judgment transfer.** Pulse never answers a permission request; the
  receiver appends one line and exits. No rules engine, no auto-approve.
- **A lamp, not an orchestrator.** No dispatching, worktrees, checks or
  typing into terminals. A subprocess runs only on a click (`TerminalFocus`,
  `ConnectionTest`).
- **No network.** "Releases…" opens the browser.
- **No record of its own.** Hooks write `events.tsv` (+ one rotation
  `events.1.tsv`); beside it only `settings.json`, the install ledger,
  `debug.log`, `hook-ping` and `snapshot.json` (a cache of the replay,
  ignored when it does not decode). The app appends only `dismiss` lines.
  Banner bookkeeping and turn watches are in memory. A log that is not v10
  is started over, never migrated.
- **Every heard event is one line** — a state line or an `ignored` line
  saying why, never the payload's words.
- **Replay before the first projection.** Restore the snapshot, apply every
  line past its `seq` (all of them for another `gen`), then project: that
  projection is the banner baseline. Identity is the `seq`, never the text.
  Snapshot + the rest equals the whole replay (a property test).
- **Bounded by rotation, never by meaning.** Past 1 MiB the hook moves the
  bytes unread to `events.1.tsv`; it never parses the log. Lines ≤ 8 KiB.
- **A failed source never blanks the tray.** Sessions leave only by an
  `end`, a process exit or reused pid, the idle / silent bounds or the
  one-day prune.
- **Event-driven.** The log's `DispatchSource` and per-pid exit sources;
  besides them one cheap tick (5 s open / 60 s, stopped when empty) and a
  backing-off libproc scan. Low power doubles both; a sleeping display stops
  both.
- **Pure core.** `SessionBook.apply` (a `Signal` by a `Speaker`, one
  transition) and `TrayState.project` take and return values; the
  projection carries state only, so an unchanged world lands nothing
  (`ScanQuietTests`). Side effects live in `ScanEngine`, `WaitNotifier`,
  `StatusStore`.
- **Observe-only hooks, reversibly.** Never a gating event
  (`gatingEvents`); decision-capable events are installed async. One owner
  exception: Copilot's synchronous `agentStop` / `postToolUse` print
  nothing. Owned plugins read the event stream only and never throw or
  block. Every install reverts byte-for-byte; Codex's `config.toml` is never
  read. No environment variable is followed for a vendor's config folder —
  Settings says so when the default is missing.
- **QA code never ships** (`PulseQA`; `package_check.py` enforces it).

## Code

`PulseBar/` (Swift 6, warnings are errors, macOS 14+):

| Target | Holds |
| --- | --- |
| `PulseKit` (Foundation only) | adapters (with real JS templates in `Agents/JS/` synced via `scripts/sync_js_modules.py`), protocol, `EventLog`, `BookSnapshot`, receiver + installer, libproc, `SessionBook` → `TrayState`, every surface model, `L10n` |
| `PulseHook` | lightweight native hook receiver (`Contents/MacOS/pulse-hook`, links only `PulseKit` + CoreGraphics) |
| `PulseApp` | `ScanEngine`, `StatusStore`, `WaitNotifier`, `TerminalFocus`, `GlobalShortcut`, `AutomationCheck`, views, resources (`PulseResources`, never `Bundle.module`) |
| `PulseBar` | the shipping app executable |
| `PulseQA` | fixtures, captures, preview, `QADriver` |

Flow: hook line → `AttentionWatcher` → `ScanEngine` applies lines past its
cursor → `TrayState.project` → `StatusStore.land` (only changed values) →
`WaitNotifier` (one banner per wait, withdrawn when it ends). Rows and the
detail page read `SessionFacts` from the book when drawn. Every key is a
`SessionKey`; its `description` is the only string that leaves the process.

```bash
cd PulseBar && swift build && swift test
bash scripts/gates.sh            # version, catalog, icons, surfaces, DMG art
node scripts/js_adapters_test.mjs
./PulseBar/Scripts/package.sh    # then ./scripts/e2e.sh, ./scripts/qa_captures.sh
```

Tests: one file per component (`CoreTests`, `VendorFormatTests`,
`AttentionTests`, `SessionTests`, `NotifierTests`, `TrayTests`,
`SettingsTests`, `DiagnosticsTests`, `EngineTests`). A wrong state is fixed
with a failing test, not a source gate. Copy rules are string tests
(`CopyRuleTests`). A gate earns its place by guarding a real fact.
A new surface comes with a pure model, a fixture and a capture.

Version truth: `PulseApp/Models.swift` → `PulseVersion.semver`; CHANGELOG's
newest heading and the README badge follow it.

## Ship and release

`package.sh` decides the channel before signing (Info.plist is sealed),
signs with `Packaging/Pulse.entitlements` (Apple Events for the tab search),
then notarizes and staples last. Without Developer ID secrets the build is
`preview`, ad-hoc and unnotarized — never labelled `stable`. Never add a
`com.apple.developer.*` entitlement to an ad-hoc build. Distribution is the
DMG only, with `.sha256` and a build-provenance attestation.

Write the `## x.y.z` CHANGELOG section first, then:

| Trigger | Result |
| --- | --- |
| `[release]` in a commit subject on `main` | build, tag, publish |
| `[release] [prerelease]` | same, as a prerelease |
| `[promote]` on `main` | the current prerelease becomes Latest (no rebuild) |
| `v*.*.*` tag push / `workflow_dispatch` | manual paths |

## Versioning and language

Major: a breaking change to persisted state, a protocol, or how the code is
extended. Feature or UI pass: minor. Fix: patch. A release not run on a real
Mac (`scripts/smoke.sh`) is a prerelease unless the owner decides otherwise,
and CHANGELOG says so. Every version on `main` is released. Code, comments
and agent docs are English; user copy, CHANGELOG, EXPERIENCE, README, plans
and reviews are Chinese.
