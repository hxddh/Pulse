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
| [`docs/vendor-formats.md`](docs/vendor-formats.md) | You touch any vendor parser — each agent's format has a pinned source, a fixture and a weekly drift sentinel |
| [`CHANGELOG.md`](CHANGELOG.md) | You need to know when something changed |

Everything is Swift under `PulseBar/` (23.0 deleted `src/` and the Python
hook scripts). There are three targets, dependencies pointing down only:
`PulseCore` (the kernel — the agent catalog, bounded IO, process
supervision, transcript parsing, probe cadence, the debug log),
`PulseHarvest` (the collector) and the `PulseBar` app (22.0 removed
`PulseManaged`, 23.0 removed `PulseRespond`). No
library may import AppKit, SwiftUI or reach `StatusStore`; library members are
`package`, Core's are `public`. **Adding an agent** means one
`case` and one `AgentSpec` in `PulseCore/AgentCatalog.swift`, plus its icon, README
row and an entry in `docs/vendor-formats.json` — `scripts/catalog_check.py`
fails if a per-agent table grows back anywhere else, if the README matrix
disagrees with the catalog, or if the agent's format has no stated source. The legacy Python collector was deleted in 0.99 and the Vercel Native
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
- **No judgment transfer, and no blind approve.** 23.0 removed Respond:
  Pulse never answers a permission request, and the hook receiver never
  holds — it writes one attention line and exits. The answer is always given
  in the vendor's own prompt. Forbidden: rules engines, always-allow,
  auto-approve, approving from a truncated summary, and any hold that would
  freeze an agent.
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

Tests live in `PulseBar/Tests/PulseBarTests/`, one file per component (23.0):
`CoreTests` (catalog, bounded IO, processes), `HarvestTests`,
`TranscriptTests`, `VendorFormatTests` (fixtures built from vendor source),
`AttentionTests` (reader, protocol, hook receiver, installer, `claude
agents`), `BuilderTests`, `ExplainTests`, `SessionLogTests`, `NotifierTests`,
`TrayTests`, `SettingsTests`, `DiagnosticsTests`, `EngineTests`. A new test
goes in the file of the component it tests — never a file named after a
release. A file may hold several suites; `docs/scenarios.md` names suites
and methods, and `scenario_map.py` checks both exist.

Gates, from the repo root — CI, `release.yml`, `scripts/release.sh` and
`package.sh` all run the same list:

```bash
bash scripts/gates.sh                        # every source gate (below)
python3 scripts/resource_budget_check.py     # native fixture wall + RSS (needs a build)
python3 scripts/package_check.py             # reads the built .app
./scripts/qa_surfaces.sh                     # surface fixture PNGs (needs the .app)
./scripts/qa_observation_truth.sh            # status fixture PNGs (needs the .app; CI)
```

`gates.sh` runs `version_check` (one semver), `catalog_check` (roster,
harvest roots, probe and privacy rules, README matrix, vendor formats —
23.0 merged four gates into it), `make_agent_icons --check`,
`appearance_check`, `surface_check`, `scenario_map` and a `Bundle.module`
grep. A gate earns its place by guarding a real fact; one that only checks
prose or long-deleted code is removed, not kept "just in case".
`qa_mac_cursor_appdata_ab.sh` is a manual Mac-only A/B for the app-data
switch, not CI.

`NativeActivityHarvest.swift` is the collector. There is no second one: 0.99
deleted `src/activity_scan.py`, its bundled copy and `harvest_stats_check.py`
— 11,470 lines that never ran for a user, could not catch a native regression,
and were documented as if they could. 23.0 deleted the Python hook scripts
too; the installer writes only the native `pulse-hook`. A missing Python
runtime must never block the app, harvest, or self-test.

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

22.0.0 is the current source version (Lamp). It is subtractive: a status
lamp should watch orchestrators, not be one, so it removed the `PulseManaged`
target (managed sessions, the permission MCP server and `--permission-server`,
worktrees, Missions, acceptance checks, `EvidenceBook`, workspace effect), the
Workbench window and everything that existed for it (dispatch, terminal
actuation, the resume channel, the Mission board and working-copy card),
remote Respond (`requests.d/`, `verdicts.d/`, `secrets/`,
`respond-secret.key`; 23.0 then removed local Respond too), and the
fleet (`fleet.d/` snapshots, the `attention.d/` inbox, remote rows; the
attention `host` column is ignored). The settings `workbenchActuation`,
`workspaceEffect` and `fleetBroadcast` are gone, as are grouping, sound,
quiet hours, the per-agent mute list, the stall threshold, snooze length and
history retention in Settings (muting moved to the row menu).

23.0 continued the subtraction: no compatibility with older versions. The
updater only checks GitHub Releases and opens the release page (no download,
DMG verification, in-place install, rollback, duplicate-install finder or
crash-after-update banner). `LegacyCleanup` and every settings migration are
gone, as are the live
updates switch (the scan always follows `ProbeSchedule`), snooze, look
continuity / the resolved-wait history, the session digest
(`session-digests.json`; a transcript past its read window reports its record
count as unknown) and the `SessionSource` seam. The stall threshold is the
constant `AgentRow.stalledSeconds`.

23.0 split the app layer's state three ways. `StatusStore` is the one
`@Observable` model views read — the snapshot and `cachedAll` rows, `settings`,
`logRevision`, and a few UI flags (`settingsFocus`, `diagnostics`, hook and
notification status, update status); 17 observed properties, every one listed
in `ScanQuietTests` (which fails past 25), plus the intents views send.
`ScanEngine` (`@MainActor`, not observed) owns the probe timer and
`ProbeSchedule` cadence, runs the probe / harvest / attention / `claude
agents` / spool reads off the main thread, keeps the harvest supervisor,
collector health, probe stats and every between-scan cache, calls the pure
`SnapshotBuilder`, and hands the result to `StatusStore.land`, which assigns
an observed property only when it changed. `WaitNotifier` (`@MainActor`, not
observed) owns the "needs you" banner: `WaitingDelivery` planning, posting,
rate limiting, outcomes and clicks on the `SessionLog`, and banner-click
routing. Tests drive a scan with `store.engine.applyScan(...)`. The files are
`StatusStore.swift` (model and intents), `StatusStoreViews.swift` (the row
and detail values, the tray notice), `StatusStoreHealth.swift` (Diagnostics and
reports), `StatusStoreFixture.swift` (CLI fixtures), `ScanEngine.swift` and
`WaitNotifier.swift`; the harvest's own between-scan memory is
`HarvestMemory` in PulseHarvest. Settings are a `Codable` `PulseSettings`
saved as `settings.json` (0600, `PrivateFile`) and changed through
`StatusStore.set(_:_:)`, which saves and applies only after `start()`: launch
at login, language, hotkey, notify on waiting, muted agents, terminal
automation, `readProtectedAppData` (one switch for every agent with
`requiresAppDataOptIn` — the per-agent scopes are gone), update check and
hooks-nudge-off. A `settings.txt` is deleted at load, never read. The "notify
when idle" banner is gone.

What remains was rebuilt around one line per session. The tray
(`TrayPanel`) has no groups, folds, chips, row tint or refresh button: a row
is one line (lamp, agent, project unless it is the headline, headline, one
age), plus a second line only for a wait (the ask) or an orange row (the
why); a your-turn row carries a quiet "your turn" label and a muted agent a
`bell.slash`. The lamp has a shape as well as a tone (`LampFace`: filled =
needs you, ring = running, hollow = your turn / recent, dotted = process
only; orange only for a stall or an error, never for a process-only row),
drawn by `LampShapeView` in the row and by `PulseBrand.statusBarIcon` in the
menu bar, whose title is empty unless something is blocked ("2 · 4m",
within `GlanceTitle`'s budget) and whose tooltip is one `LampExplanation`
sentence. Every verb lives in the row `menu` (go, details, dismiss,
mute/unmute) and VoiceOver actions. `SessionDetailView` (→ / Space or the
menu's Details; ← / Esc back) renders a `DetailModel` through
`SessionDetailFace`: header, the full ask with Go / Dismiss, the why once, a
`TimelineStripView` of the last hour, the last message, plan, the last
error, the notification audit, a facts grid (model, source, folder, start)
and a folded diagnostics block. Every tray key goes through one pure
reducer, `TrayKeys.reduce`, called by the panel's key monitor through
`TrayUI` (the per-open state: keys, the frozen `TrayOrder`, the list's
height budget): typing shows a visible filter (over every retained
session), ⌫ only edits it, ↑↓ select, ↩ go (the terminal, else the detail),
D dismiss, M mute, Esc clears the filter, then closes; ⌘R refreshes, ⌘,
opens Settings. The header (`TrayHeaderModel`) is one line of tone-coloured
counts and the freshness (orange when the scan is late or the Mac asleep)
with a ⋯ menu (Diagnostics, Settings, Quit); at most one notice
(`TrayNoticeModel`, one action); the footer carries "N more" and the key
hints; the empty state is one sentence. A banner click focuses the
terminal and nothing else, or opens the row's detail when there is no
handle (`BannerRoute`); the global shortcut toggles the tray. Settings is a
single scrolling page of seven sections (`SettingsModel`); jumping in from
elsewhere bumps `settingsFocus.token` and scrolls to the section.
Diagnostics (it was Health; `DiagnosticsModel`) lists problems first, then
the self-check, then one line per agent, with the activity log in its own
tab and one "Copy report".

Observability (23.0): one event store, `SessionLog` (pure value) in
`session-log.json` via `SessionLogStore` (debounced, `PrivateFile`), replaced
the attention ledger, the hook history, the session timeline and the
dismiss list (their files are deleted at launch, never migrated). Per row
key it keeps state spans (`SessionTimeline.transitions`: running / thin /
stalled / blocked / turn / recent, evidence hook / pending / vendor /
harvest / process) and wait records (raised, queued, notified, banner
outcome — a `WaitingDelivery.SkipReason` raw value or posted / summary —
clicked by wait id, dismissed, resolved); owed banners (`queuedKeys`), soft
dismissals (`suppressedKeys`) and the edge baseline (`waitingKeys`) derive
from it. Bounded: 128 sessions, 48 spans, 24 h after end; open spans and
waits are never evicted, and spans a quit left open close at the last
save. Every change goes through `StatusStore.updateLog`, which bumps the
observed `logRevision` and writes only when content changed — a quiet scan
writes nothing. `logRevision` and `settingsFocus` are observed store
properties listed in `ScanQuietTests`. `LampExplanation` gives the rule that set the
lamp as one sentence — the status item's whole tooltip (23.0) — and
`LampFace` the lamp's shape and tone, shared by the tray row and the menu
bar (filled = needs you, ring = running, hollow = your turn / recent,
dotted = process only; orange only for a stall or an error).
`NotificationAuditModel` renders a wait's
banner fate in the detail view; `ActivityLogModel` merges spans and banner
fates across sessions into the Diagnostics window's Activity tab,
filterable by agent; times go through `LogClock` (the day is said when it
is not today).
`staleHidden` counts only sessions that stopped within the last 24 h
(`SnapshotBuilder.staleHiddenWindowMs`), and the scan's `apply` debug-log
line is written only when it changed.

Rows (23.0, P2c). **A row's key is decided once and never changes**
(`RowIdentity`, PulseHarvest): a session row is `agent|<vendor session id>`
(else `agent|file:<hash of the transcript path>`, else `agent|at:<hash of
cwd + start>`); a hook wait the harvest has not met is keyed like the session
it names (`agent|<session>`, or `agent|hook:<hash of cwd>` when it names
none), so the transcript turning up later finds the same row; a process with
no session row is its own ephemeral `agent|pid:<pid>` row that is simply not
built once the agent has a session (or hook) row — the process attaches to
that row instead. Hooks attach by session id, then by folder (never onto a
row that owns a different session, never onto a process row). The remap
machinery (`remappedRowKeys`, `SessionLog.remap`, timeline `remapped`,
`WaitNotifier.followRemap`) is gone; `session-log.json` is schema 2 and a
version-1 file is not read. `AgentRow` is slim: identity (key, agent,
session, `attentionSession`, cwd, project), the process handle (pid, tty,
Warp, host app, `focusTier`), what it is doing (task, model, `lastWord`,
`planSteps`, errors, `lastErrorText`), and one `RowState` — `.blocked(RowWait)`
(kind, ask, since, signal, inFront), `.running`, `.yourTurn(sinceMs:)`,
`.recent`, `.processOnly` — plus `isStalled`, `harvestMs` / `activityMs`,
`startedMs` and `source` (`RowSource`: session / cache / hooks / process).
Process evidence, start and count live on `ScanEngine.processesByAgent`
(`ProcessFacts`) for Diagnostics. **One Explain**: `Explain` (pure) gives a row's
`headline` (the tray hero), `why` (which evidence put it in this state and
since when), `source`, `state` and `ask`; `TrayRowModel`, `DetailModel` and
`LampExplanation` all say its words. `RowNarrator`, `RowCardModel`, the Why
card, the diagnostics card, `ObservationQuality`, `TrayRowLead` and
`RowValueEngine` are gone, with tokens, CPU/memory, context %, files, tool,
phase/outcome, subagent counts and the activity-change diff on the row
(the harvest still reads tool, tokens, phase and subagents for waits,
freshness, state and Diagnostics' fact classes; files and context % are no
longer read). User copy is L10n only — `DoctorModel`'s inline pairs became
keys.

21.0.0 (Clarity — bug fixes, one visual
system, rows that explain themselves, fewer surfaces). `PulseTheme` owns
spacing, radii, fills, semantic type and one `Tone` per state (system dynamic
colours); views use `.pulseCard()` / `.pulseInner()` / `PulseChip` /
`PulseLamp` instead of hand-written numbers. A tray row shows at most two
verbs and only for a wait (`TrayRowModel.strip`); every verb is in `menu`
once and in VoiceOver actions. The why line (since 23.0 `Explain.why`)
covers stalled, failed and process-only rows (`whyInline` shows it without a
click). The snapshot
counts sessions dropped for age (`staleHidden`). 21.0 split Settings into
five panes (one page since 22.0); the global shortcut is one `HotkeyChoice` with `.off`
(`hotkeyEnabled` is derived; older files migrate). The self-check, per-agent
reading and reports are one window (23.0: Diagnostics, `DiagnosticsView` →
`DiagnosticsFace`); the Details window was folded into the Workbench
(itself removed in 22.0). 23.0 made every tray key go through one pure
reducer (`TrayKeys.reduce`, called from the panel's key monitor through
`TrayUI`), froze the row order while the panel is open (`TrayOrder`), and
gave the header (`TrayHeaderModel`), the one notice (`TrayNoticeModel`),
Settings (`SettingsModel`) and Diagnostics (`DiagnosticsModel`) a value
each. On macOS
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
carrying `GROK_*` to Grok and rejects unknown event names instead of treating them as
Waiting. Fact merge now carries `lastWord` across a session's files.

19.0.0 (Observe) made the store observed field by field, every card under a row is a value, and the Mac can check
itself. `StatusStore` is `@Observable` (Observation, macOS 14): a view is
invalidated only by the properties its body read. Engine bookkeeping is
`@ObservationIgnored`. `ScanQuietTests` tracks every observed property (and fails when one
is added without being listed); AppKit follows the store with
`ObservationLoop`; Settings never reads `snapshot` or the rows.
`surface_check.py` rejects any Combine-era wrapper (`ObservableObject`,
`@Published`, `@ObservedObject`, `@StateObject`, `objectWillChange`). The
cards under a tray row — the expanded inspector, the digest (in
22.0 the detail view; 23.0 `DetailModel`) — render a value and send
intents. The self-check (`DoctorModel` pure, `DoctorProbe`
read-only IO, Settings → About) turns the real-machine confirmations into
one click and a redacted report: Claude/Codex hooks installed and actually
firing, `claude agents --json`, Codex rollout format. The test target is in the Swift 6 mode too: XCTest suites isolate
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
the why line (23.0: `Explain.why`) says which evidence put a row in its
state and never guesses (the hook-history copy and its TSV export are gone —
`TurnTruthTests` replays static fixtures through `AttentionReader`). The tray row's face is a value
(`TrayRowModel` → `TrayRowFace`, gated by `surface_check.py`). Since 16.0 red means blocked: Attention
Protocol v3 (`AttentionKind`) separates blocked, your turn (a quiet count) and
resolved, and column 8 `front` keeps banners away from a prompt already in
front. Since 15.0 surfaces are values: `scripts/qa_surfaces.sh` renders
their fixtures on CI and `scripts/surface_check.py` keeps views off the
store — **a new surface comes with a model, a fixture and a capture.** 13.0
accepted the orchestrator identity and 14.0 moved evidence to the working
copy; 22.0 reversed that decision and removed both. The 12.x structural work
is complete (see CHANGELOG).

Every target builds warning-free under complete concurrency checking with
`-warnings-as-errors` (12.4). A value that crosses a queue by convention goes
in `Unchecked` with a comment saying why; prefer `Sendable` types and `Guarded`.
A scan that finds the same world must publish nothing (`ScanQuietTests`): write
an observed store property on the scan path only when its value changed —
Observation announces every assignment, equal or not.
Since 23.0 an agent whose on-disk format is `unverified` in
`docs/vendor-formats.json` has `waiting: .none`: its harvest `pending` is not
evidence, and `SnapshotBuilder` lights harvest pending only for
`waiting: .harvestPending`. Attention lines need all eight v3 columns.

Without an Apple Developer ID, GitHub **Latest** tracks the current semver
while the binary stays `preview` / ad-hoc — **never stamp `stable` or claim
Gatekeeper-ready.** Channel honesty lives in `PulseDistributionChannel`.
