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
| [`docs/plan-outcome.md`](docs/plan-outcome.md) | The Outcome plan — β/γ shipped as 13.0 Mission; the second runtime (Codex) is blocked on real-machine P0 evidence |
| [`docs/respond-protocol.md`](docs/respond-protocol.md) | You are touching how a verdict travels between machines |
| [`CHANGELOG.md`](CHANGELOG.md) | You need to know when something changed |

Everything is Swift under `PulseBar/`; `src/` retains only the optional hook
scripts. Since 12.3 there are five targets, dependencies pointing down only:
`PulseCore` (the kernel — the agent catalog, evidence, code identity, bounded
IO, process supervision, transcript parsing, probe cadence, the debug log),
`PulseHarvest` (the collector), `PulseRespond` (the permission contract and
spool), `PulseManaged` (sessions Pulse runs) and the `PulseBar` app. No
library may import AppKit, SwiftUI or reach `StatusStore`; library members are
`package`, Core's are `public`. **Adding an agent** means one
`case` and one `AgentSpec` in `PulseCore/AgentCatalog.swift`, plus its icon and README
row — `scripts/agent_catalog_check.py` fails if a per-agent table grows back
anywhere else. The legacy Python collector was deleted in 0.99 and the Vercel Native
SDK shell in 0.22 — recover either from git history if you ever need it.

## Invariants

These are product decisions, not preferences. Breaking one is a bug even if it
compiles and ships.

- **No fake Waiting.** Waiting comes from hooks or harvest `skill=pending`,
  never from inference. An agent with no Waiting path shows Running and says so.
  Since 16.0 (Attention Protocol v3) **red means blocked** — `permission`,
  `question`, `waiting`. A finished turn (`turn`: Claude Stop / `idle_prompt`,
  Codex `agent-turn-complete`) is "your turn": a quiet tray count, never the
  red lamp, never a banner; it comes only from hooks and never makes a row of
  its own.
- **No quota, cost, or reset HUD.** That is a different product.
- **No judgment transfer, and no blind approve.** Respond (scenes AR, AU)
  delivers the user's own decision to a permission request: key-file opt-in,
  single-use HMAC verdicts bound to request id + content digest + agent +
  host, and **Allow exists only where the full request is shown**
  (`canOfferAllow`) — which is why the banner offers Deny and never Allow.
  Everything else stays forbidden: rules engines, always-allow, auto-approve,
  approving from a truncated summary, and **any hold that would freeze an
  agent in front of the person using it** — 2.4 sharpened that last one rather
  than relaxing it, because "someone is touching this Mac" was never the same
  question as "the prompt is in front of them", and where the answer cannot be
  established the request goes straight through. Every failure falls open to
  the vendor's own prompt.
- **Pulse lays Candidates side by side; it never judges them.** A Mission
  (13.0) shows facts per Candidate in dispatch order. No score, badge,
  recommended colour, "best", auto-choose, or ordering by a quality function;
  "your choice" writes nothing to git; commit / push / PR each need the user's
  click; no merge. Checks run only on the user's click, are never shown to the
  agent, and an agent cannot change the contract — only the user's edit makes
  a new revision, and an old Candidate is never re-judged by a newer one. No
  checks, stale, running or unreadable evidence never reads as passed. Since
  14.0 the same holds for any local working copy (`EvidenceBook`, keyed by
  directory): setting checks for a directory is the opt-in, they run in the
  user's live copy only on a click, and the tray fact is counts only. An
  observed working copy may join a Mission as an external Candidate — it is
  compared, never dispatched, and that is not the Outcome second runtime.
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
cd PulseBar && swift build      # macOS 14+, Swift 5.10 compiler
cd PulseBar && swift test       # test count is reported by SwiftPM/CI
```

Gates, from the repo root — CI, `release.yml`, `scripts/release.sh` and
`package.sh` all run the same list:

```bash
bash scripts/gates.sh                        # every source gate
python3 scripts/resource_budget_check.py     # native fixture wall + RSS (needs a build)
python3 scripts/package_check.py             # reads the built .app
./scripts/qa_surfaces.sh                     # Workbench surface PNGs (needs the .app)
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

16.0.0 is the current source version (Turn — red means blocked). Attention
Protocol v3 (`AttentionKind` in PulseCore) separates blocked, your turn and
resolved, and adds column 8 `front`: whether the prompt's window was frontmost
when an event was raised — a blocked prompt already in front lights the lamp
but raises no banner. `AgentRow.yourTurn` feeds the tray count and the global
hotkey (blocked first, then your turn); focusing a turn row writes a
session-scoped `done`. `TurnTruthTests` pins vendor event sequences end to end.
Since 15.0 the Workbench's judgement surfaces are values (`MissionBoard`,
`ProofCardModel`); `scripts/qa_surfaces.sh` renders them on CI and
`scripts/surface_check.py` keeps views off the store — **a new judgement
surface comes with a model, a fixture and a capture.** Since 14.0 evidence belongs to the working copy
(`EvidenceBook`, `Pulse/evidence/<digest>.json`; managed session state schema
5). 13.0 made the product decision in review-11.0 §4.3: Pulse accepts the
orchestrator identity, and the Workbench stays in the tray's process until one
of the split triggers listed there occurs. What remains of Outcome
([`docs/plan-outcome.md`](docs/plan-outcome.md)) is the second runtime (Codex
App Server), blocked on real-machine P0 evidence; it ships as a 16.x.
The 12.x structural work is complete ([`docs/plan-12.0.md`](docs/plan-12.0.md)).

Every target builds warning-free under complete concurrency checking with
`-warnings-as-errors` (12.4). A value that crosses a queue by convention goes
in `Unchecked` with a comment saying why; prefer `Sendable` types and `Guarded`.
A scan that finds the same world must publish nothing (`ScanQuietTests`): write
a `@Published` property on the scan path only when its value changed.
Respond's P0-0 real-machine confirmation (decision shape honoured) remains the
one unverified item of 2.0 — a wrong shape is silently ignored and falls open,
never a wrong approval.

Without an Apple Developer ID, GitHub **Latest** tracks the current semver
while the binary stays `preview` / ad-hoc — **never stamp `stable` or claim
Gatekeeper-ready.** Channel honesty lives in `PulseDistributionChannel`.
