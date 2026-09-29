# Agent handoff — Pulse

macOS menu-bar status lamp for coding agents: `idle` / `running` / `needs you`.

## Orientation

| Doc | Read it when |
| --- | --- |
| [`README.md`](README.md) | You want to know what the product is |
| [`docs/architecture.md`](docs/architecture.md) | You are changing how data reaches the menu bar |
| [`EXPERIENCE.md`](EXPERIENCE.md) | You are changing anything the user sees — it is the behaviour spec |
| [`docs/scenarios.md`](docs/scenarios.md) | You add or change an acceptance scenario — each row names the tests that pin it |
| [`CHANGELOG.md`](CHANGELOG.md) | **Start here** — what shipped, and why |
| [`docs/review-11.0.md`](docs/review-11.0.md) | **The current review** — defects at the 11.0.3 baseline (fixed in 11.0.4) and the next-version evaluation (Kernel before Outcome) |
| [`docs/archive/`](docs/archive/README.md) | Historical plans (0.23 – 6.0) and superseded reviews (0.21, 1.2, 2.2) |
| [`docs/plan-2.0.md`](docs/plan-2.0.md) | The shipped 2.0 plan (Respond) — P0-0 evidence and the remaining real-machine confirmation checklist live here |
| [`docs/plan-12.0.md`](docs/plan-12.0.md) | The 12.x plan (Kernel → Surface) — modules, catalog, dialects, narration, scan-quiet surfaces, and what each 12.x release completed |
| [`docs/plan-outcome.md`](docs/plan-outcome.md) | Historical: the Outcome plan (13.0 Mission). Removed in 22.0 with the orchestrator |
| [`docs/respond-protocol.md`](docs/respond-protocol.md) | You are touching how a verdict travels from Pulse to the hook holding for it |
| [`docs/vendor-formats.md`](docs/vendor-formats.md) | You touch any vendor parser — each agent's format has a pinned source, a fixture and a weekly drift sentinel |
| [`CHANGELOG.md`](CHANGELOG.md) | You need to know when something changed |

Everything is Swift under `PulseBar/`; `src/` retains only the optional hook
scripts. There are four targets, dependencies pointing down only:
`PulseCore` (the kernel — the agent catalog, bounded IO, process
supervision, transcript parsing, probe cadence, the debug log),
`PulseHarvest` (the collector), `PulseRespond` (the permission contract and
spool) and the `PulseBar` app (22.0 removed `PulseManaged`). No
library may import AppKit, SwiftUI or reach `StatusStore`; library members are
`package`, Core's are `public`. **Adding an agent** means one
`case` and one `AgentSpec` in `PulseCore/AgentCatalog.swift`, plus its icon, README
row and an entry in `docs/vendor-formats.json` — `scripts/agent_catalog_check.py`
fails if a per-agent table grows back anywhere else, and
`scripts/vendor_formats_check.py` if the agent's format has no stated source. The legacy Python collector was deleted in 0.99 and the Vercel Native
SDK shell in 0.22 — recover either from git history if you ever need it.

## Invariants

These are product decisions, not preferences. Breaking one is a bug even if it
compiles and ships.

- **No fake Waiting.** Waiting comes from hooks, harvest `skill=pending`, or
  (18.0) the vendor's own report of a blocked session — `claude agents --json`
  `status: waiting` — never from inference. An agent with no Waiting path shows Running and says so.
  Since 16.0 (Attention Protocol v3) **red means blocked** — `permission`,
  `question`, `waiting`. A finished turn (`turn`: Claude Stop / `idle_prompt`,
  Codex `agent-turn-complete`) is "your turn": a quiet tray count, never the
  red lamp, never a banner; it comes only from hooks and never makes a row of
  its own.
- **No quota, cost, or reset HUD.** That is a different product.
- **No judgment transfer, and no blind approve.** Respond (scenes AR, AU)
  delivers the user's own decision to a permission request raised by an
  agent **on this Mac** — nothing crosses machines (22.0): key-file opt-in
  (`respond-local.key`), single-use HMAC verdicts bound to request id +
  content digest + agent + host, and **Allow exists only where the full
  request is shown**
  (`canOfferAllow`) — which is why the banner offers Deny and never Allow.
  Everything else stays forbidden: rules engines, always-allow, auto-approve,
  approving from a truncated summary, and **any hold that would freeze an
  agent in front of the person using it** — 2.4 sharpened that last one rather
  than relaxing it, because "someone is touching this Mac" was never the same
  question as "the prompt is in front of them", and where the answer cannot be
  established the request goes straight through. Every failure falls open to
  the vendor's own prompt.
- **Pulse watches orchestrators; it is not one.** No dispatching sessions,
  no managed runtimes, no worktrees, no running the user's checks, no typing
  into terminals. 22.0 removed all of it (see Current state); bringing any of
  it back is a product decision, not a feature.
- **A harvest failure must not blank the scan.** `NativeActivityHarvest` has a
  per-agent bounded adapter; the optional legacy `guard()` path has the same
  isolation. One broken collector cannot blind the other 32.
- **No fixed probe interval.** Cadence follows `ProbeSchedule` — a resident
  menu-bar app flagged for energy use is a dead product.
- **The builder stays pure.** `SnapshotBuilder` takes the world through
  `Context` and returns intents. Side effects belong in `StatusStore`.
- **Don't expand the hook installer** past Claude and Codex. Everything else
  goes through [`docs/attention-bridge.md`](docs/attention-bridge.md)
  / [`docs/attention-protocol.md`](docs/attention-protocol.md).

## Working on it

```bash
cd PulseBar && swift build      # targets macOS 14+; needs Xcode 26 / Swift 6.2+ (CI: macos-26)
cd PulseBar && swift test       # test count is reported by SwiftPM/CI
```

Gates, from the repo root — CI, `release.yml`, `scripts/release.sh` and
`package.sh` all run the same list:

```bash
bash scripts/gates.sh                        # every source gate
python3 scripts/resource_budget_check.py     # native fixture wall + RSS (needs a build)
python3 scripts/package_check.py             # reads the built .app
./scripts/qa_surfaces.sh                     # surface fixture PNGs (needs the .app)
```

`NativeActivityHarvest.swift` is the collector. There is no second one: 0.99
deleted `src/activity_scan.py`, its bundled copy and `harvest_stats_check.py`
— 11,470 lines that never ran for a user, could not catch a native regression,
and were documented as if they could. The remaining Python files are hook
assets only, and a missing Python runtime must never block the app, harvest, or
self-test.

**The wall that catches a parsing regression** is `PulseBar --native-fixture-test`
(`NativeHarvestSelfTest.swift`) plus `swift test`; both assert hero **values**
against vendor-shaped files. A wrong tray hero is fixed with a failing test
there. Believing a source-string gate could do that job is what let 0.96.1,
0.97.0, 0.97.1 and 0.97.2 each ship green with the hero still wrong.

**Version truth:** `PulseBar/Sources/PulseBar/Models.swift` → `PulseVersion.semver`.
CHANGELOG's newest heading and the README badge follow it.

Debug log: `~/Library/Application Support/Pulse/debug.log` (rolls at 2 MB).

## Ship

```bash
./PulseBar/Scripts/package.sh
open zig-out/package/Pulse.app
```

Local packaging uses `PULSE_SIGN_IDENTITY` plus `PULSE_NOTARY_PROFILE` for a
distributable build. Release CI uses the base64 Developer ID certificate,
password and App Store Connect API key secrets when available. Without an
Apple Developer account it still publishes GitHub **Latest** for the current
semver (so `/releases/latest` is not stuck on an older cut), but the binary
stays `preview` / ad-hoc / unnotarized — that artifact must never be labeled
`stable` or Gatekeeper-ready. Release notes include the Control-click recovery.

## Release

Write the `## x.y.z` section in CHANGELOG.md first — every path refuses without it.
`version_check.py --fix` updates the README only; it never renames a CHANGELOG
heading (before 21.0 it did, and 19.0/20.0 shipped 18.0's notes).

```bash
./scripts/release.sh 0.29.0            # dry run: bump + gates + diff
./scripts/release.sh 0.29.0 --commit   # commit carrying the [release] marker
git push                               # CI builds, tags and publishes
```

| Trigger | When |
| --- | --- |
| `[release]` in the pushed commit subject | default; **`main` only** |
| a `v*.*.*` tag push | if you prefer explicit tags and have tag-write rights; any branch |
| `workflow_dispatch` | from the Actions tab |

The marker path is deliberately limited to `main`. It accepted any branch while
`release.yml` lived only on a feature branch — that was then the sole way to
publish — so a release could be cut from a branch nobody had reviewed.

CI verifies the version matches `PulseVersion.semver`, runs gates and tests,
packages the DMG, and publishes a Release whose body is that version's CHANGELOG
section. **It creates the tag with its own `contents: write` token** — publishing
deliberately does not depend on any developer's or agent's local credentials. A
version that already has a Release is refused, so re-pushing is harmless.

The in-app update check reads those Releases; an untagged version is invisible
to users.

## Versioning and language

- A **major** version is for a breaking change to persisted state, a protocol,
  or a removed capability — or a structural change that alters how the code is
  extended (12.0). A UI pass is a minor. A schema migration never ships in a
  patch. Every version that lands on `main` is released; do not bump without
  releasing, and do not reserve a number for blocked work.
- Code comments and agent-facing docs (this file, protocols) are English.
  User-facing copy, CHANGELOG, plans and reviews are Chinese.

## Current state

22.0 (Lamp, in progress) is subtractive. A status lamp should watch
orchestrators, not be one, so it removed: the `PulseManaged` target (managed
sessions, the permission MCP server and `--permission-server`, worktrees,
Missions, acceptance checks, `EvidenceBook`, workspace effect), the Workbench
window and everything that existed for it (dispatch, terminal actuation,
the resume channel, the Mission board and working-copy card), remote Respond
(`requests.d/`, `verdicts.d/`, `secrets/`, `respond-secret.key` — Respond is
local-only, see `docs/respond-protocol.md`; `pulse_hook.py` holds only when
`ioreg` shows nobody at this Mac), and the fleet (`fleet.d/` snapshots, the
`attention.d/` inbox, remote rows; the attention `host` column is ignored).
The settings `workbenchActuation`, `workspaceEffect` and `fleetBroadcast` are
gone (old files still parse). `LegacyCleanup.run()` deletes the removed
features' directories once on launch, behind a marker, and never touches
`respond-local.key`, `respond.d/requests|verdicts`, attention files,
settings or `worktrees/`. The row's detail pane is not back yet: the tray
row has no "Details" menu item, and `WhyDetailSection` /
`SessionDiagnosticsCard` wait in `InspectorDiagnostics.swift`.

21.0.0 is the current source version (Clarity — bug fixes, one visual
system, rows that explain themselves, fewer surfaces). `PulseTheme` owns
spacing, radii, fills, semantic type and one `Tone` per state (system dynamic
colours); views use `.pulseCard()` / `.pulseInner()` / `PulseChip` /
`PulseLamp` instead of hand-written numbers. A tray row shows at most two
verbs and only for a wait (`TrayRowModel.strip`); every verb is in `menu`
once and in VoiceOver actions. `RowNarrator.whyLine` covers stalled, failed
and process-only rows (`whyInline` shows it without a click). The snapshot
counts sessions dropped for age (`staleHidden`). Settings is five panes
(`SettingsView.Pane`); the global shortcut is one `HotkeyChoice` with `.off`
(`hotkeyEnabled` is derived; older files migrate). The self-check, per-agent
reading and reports are one Health window (`SupportCoverageView`); the
Details window was folded into the Workbench (itself removed in 22.0). On macOS
26 the tray surface is `NSGlassEffectView`. `version_check.py --fix` never
touches CHANGELOG any more (it had renamed 18.0's heading into 19.0 and 20.0).

20.0.0 (Drift) made every parser name the vendor source it follows. Each agent's on-disk format has an entry in
`docs/vendor-formats.json`: a pinned vendor commit and the files that define
it (14 agents), the docs read (1), or an honest `unverified` (18); the gate
checks it and `.github/workflows/vendor-drift.yml` goes red weekly when a
pinned file moves. 20.0 rewrote the readers that had drifted, each from the
vendor's source with a vendor-shaped fixture: Gemini (`HarvestGemini.swift`),
the Cline family (`HarvestClineFamily.swift`, the vendors' own interactive-ask
set), Goose (`sessions.db`, `DatabaseAdapter.goose`), Kimi Code, Grok's
`updates.jsonl`, Copilot's `session-state`, Continue and OpenHands
(`HarvestContinueOpenHands.swift`); OpenCode's `pending` is no longer a wait.
Aider and Continue have `waiting: .none`. The hook receiver attributes calls
carrying `GROK_*` to Grok, holds for Respond only where `respondReach` is
`hookSite`, and rejects unknown event names instead of treating them as
Waiting. Fact merge now carries `lastWord` across a session's files.

19.0.0 (Observe) made the store observed field by field, every card under a row is a value, and the Mac can check
itself. `StatusStore` is `@Observable` (Observation, macOS 14): a view is
invalidated only by the properties its body read. Engine bookkeeping is
`@ObservationIgnored`. `ScanQuietTests` tracks every observed property (and fails when one
is added without being listed); AppKit follows the store with
`ObservationLoop`; Settings reads `snapshotAgents`, never `snapshot`.
`surface_check.py` rejects any Combine-era wrapper (`ObservableObject`,
`@Published`, `@ObservedObject`, `@StateObject`, `objectWillChange`). The
cards under a tray row — Respond, the expanded inspector, the digest —
render `RowCardModel` and send
`RowCardModel.Action`; a Respond click carries the request id and digest
that were on screen. The self-check (`DoctorModel` pure, `DoctorProbe`
read-only IO, Settings → About) turns the real-machine confirmations into
one click and a redacted report: Claude/Codex hooks installed and actually
firing, `claude agents --json`, Codex rollout format, Respond verdicts
claimed. The test target is in the Swift 6 mode too: XCTest suites isolate
their test methods to the main actor instead of the class; new suites are
Swift Testing.

Since 18.0 CI and release build on `macos-26` with Xcode 26 (Swift 6.3 at
the time of writing; tools 6.2), GitHub actions on their node24 majors.
Every product target is in the Swift 6 language mode with
`.treatAllWarnings(as: .error)`. Claude:
`ClaudeAgentsProbe` reads `claude agents --json` (rationed: Claude live,
hooks absent, ≥15 s apart, 3 s timeout, back-off) as a vendor-reported
Waiting source (`WaitSignalKind.vendor`); the hook installer matches
elicitation, adds `StopFailure`, and treats a PermissionRequest for
`AskUserQuestion` as a question with no hold. Codex: paginated rollouts
(`item_completed`) are parsed, `.jsonl.zst` is left alone, and
`~/.codex/hooks.json` gets `Stop` + `UserPromptSubmit` only — never
`PermissionRequest`, which fires before Codex's own auto-review. Since 17.0
`RowNarrator.whyLine` says which evidence put a row in its state and never
guesses; `AttentionHistory` (PulseHarvest) keeps what the hooks said, bounded
and sanitized, in `attention-history.json` next to `attention.tsv`, and a
session's events export on click as a v3 TSV that `AttentionReader` and
`TurnTruthTests` replay as-is. The tray row's face is a value
(`TrayRowModel` → `TrayRowFace`, gated by `surface_check.py`). Since 16.0 red means blocked: Attention
Protocol v3 (`AttentionKind`) separates blocked, your turn (a quiet count) and
resolved, and column 8 `front` keeps banners away from a prompt already in
front. Since 15.0 surfaces are values: `scripts/qa_surfaces.sh` renders
their fixtures on CI and `scripts/surface_check.py` keeps views off the
store — **a new surface comes with a model, a fixture and a capture.** 13.0
accepted the orchestrator identity (review-11.0 §4.3) and 14.0 moved
evidence to the working copy; 22.0 reversed that decision and removed both,
so Outcome ([`docs/plan-outcome.md`](docs/plan-outcome.md)) is history.
The 12.x structural work is complete ([`docs/plan-12.0.md`](docs/plan-12.0.md)).

Every target builds warning-free under complete concurrency checking with
`-warnings-as-errors` (12.4). A value that crosses a queue by convention goes
in `Unchecked` with a comment saying why; prefer `Sendable` types and `Guarded`.
A scan that finds the same world must publish nothing (`ScanQuietTests`): write
an observed store property on the scan path only when its value changed —
Observation announces every assignment, equal or not.
Respond's P0-0 real-machine confirmation (decision shape honoured) remains the
one unverified item of 2.0 — a wrong shape is silently ignored and falls open,
never a wrong approval.

Without an Apple Developer ID, GitHub **Latest** tracks the current semver
while the binary stays `preview` / ad-hoc — **never stamp `stable` or claim
Gatekeeper-ready.** Channel honesty lives in `PulseDistributionChannel`.
