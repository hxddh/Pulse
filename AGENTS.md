# Agent handoff — Pulse

macOS menu-bar status lamp for coding agents: `idle` / `running` / `needs you`.

## Orientation

| Doc | Read it when |
| --- | --- |
| [`README.md`](README.md) | You want to know what the product is |
| [`docs/architecture.md`](docs/architecture.md) | You are changing how data reaches the menu bar |
| [`EXPERIENCE.md`](EXPERIENCE.md) | You are changing anything the user sees — it is the acceptance basis |
| [`CHANGELOG.md`](CHANGELOG.md) | **Start here** — what shipped, and why |
| [`docs/review-1.2.md`](docs/review-1.2.md) | You want the defect list at the 1.2.0 baseline, or the next-major evaluation |
| [`docs/plan-respond.md`](docs/plan-respond.md) | The next candidate plan (Respond) — first installment of P0-0 evidence is in the plan; what remains is a short interactive real-machine confirmation. Version numbers are assigned at release, not reserved. |
| [`docs/plan-1.2.md`](docs/plan-1.2.md) | Historical plan (Substance) |
| [`docs/plan-1.1.md`](docs/plan-1.1.md) | Historical plan (Full Transcript) |
| [`docs/plan-1.0.md`](docs/plan-1.0.md) | Historical plan (Remote Fleet) |
| [`docs/plan-0.99.2.md`](docs/plan-0.99.2.md) | Historical plan (Live Wire) |
| [`docs/plan-0.99.md`](docs/plan-0.99.md) | Historical plan (Quiet Data) |
| [`docs/plan-0.98.md`](docs/plan-0.98.md) | Historical plan (Ground Truth) |
| [`docs/plan-0.97.md`](docs/plan-0.97.md) | Historical plan (Hero Honesty) |
| [`docs/plan-0.96.md`](docs/plan-0.96.md) | Historical plan (Return Truth) |
| [`docs/plan-0.95.md`](docs/plan-0.95.md) | Historical plan (Extinguish Honesty) |
| [`docs/plan-0.94.md`](docs/plan-0.94.md) | Historical plan (Waiting Proof) |
| [`docs/plan-0.93.md`](docs/plan-0.93.md) | Historical plan (Look Closure) |
| [`docs/plan-0.92.md`](docs/plan-0.92.md) | Historical plan (Row Clarity) |
| [`docs/plan-0.91.md`](docs/plan-0.91.md) | Historical plan (Row Story) |
| [`docs/plan-0.90.md`](docs/plan-0.90.md) | Historical plan (Waiting Reach) |
| [`docs/plan-0.82.md`](docs/plan-0.82.md) | Historical plan (Tray Fleet Substance) |
| [`docs/plan-0.81.md`](docs/plan-0.81.md) | Historical plan (Tray Substance) |
| [`docs/plan-0.80.md`](docs/plan-0.80.md) | Historical plan (Tray Legibility) |
| [`docs/plan-0.70.md`](docs/plan-0.70.md) | Historical plan (Contract Honesty) |
| [`docs/plan-0.65.md`](docs/plan-0.65.md) | Historical plan (Fleet Coverage / ZCode) |
| [`docs/plan-0.64.md`](docs/plan-0.64.md) | Historical plan (Go-Look Closure) |
| [`docs/plan-0.63.md`](docs/plan-0.63.md) | Historical plan (Live Continuity) |
| [`docs/plan-0.62.md`](docs/plan-0.62.md) | Historical plan (Attention Autonomy) |
| [`docs/plan-0.61.md`](docs/plan-0.61.md) | Historical plan (Hook Autonomy) |
| [`docs/plan-0.60.md`](docs/plan-0.60.md) | Historical plan (Waiting Continuity) |
| [`docs/plan-0.59.md`](docs/plan-0.59.md) | Historical plan (Cache Continuity) |
| [`docs/plan-0.58.md`](docs/plan-0.58.md) | Historical plan (Fleet Continuity) |
| [`docs/plan-0.57.md`](docs/plan-0.57.md) | Historical plan (Fact Continuity) |
| [`docs/plan-0.56.md`](docs/plan-0.56.md) | Historical plan (Landing Precision) |
| [`docs/plan-0.55.md`](docs/plan-0.55.md) | Historical plan (Return Continuity) |
| [`docs/plan-0.54.md`](docs/plan-0.54.md) | Historical plan (Channel Continuity) |
| [`docs/plan-0.53.md`](docs/plan-0.53.md) | Historical plan (Delivery Continuity) |
| [`docs/plan-0.52.md`](docs/plan-0.52.md) | Historical plan (Release Trust) |
| [`docs/plan-0.51.md`](docs/plan-0.51.md) | Historical plan (Observation Truth) |
| [`docs/plan-0.50.md`](docs/plan-0.50.md) | Historical plan (Signal Quality) |
| [`docs/plan-0.27.md`](docs/plan-0.27.md) | Historical plan (0.27) |
| [`CHANGELOG.md`](CHANGELOG.md) | You need to know when something changed |

Everything is Swift under `PulseBar/`; `src/` retains only the optional hook
scripts. The legacy Python collector was deleted in 0.99 and the Vercel Native
SDK shell in 0.22 — recover either from git history if you ever need it.

## Invariants

These are product decisions, not preferences. Breaking one is a bug even if it
compiles and ships.

- **No fake Waiting.** Waiting comes from hooks or harvest `skill=pending`,
  never from inference. An agent with no Waiting path shows Running and says so.
- **No quota, cost, or reset HUD.** That is a different product.
- **No approve/deny in the tray.** Pulse tells you to go look; it does not act
  for you.
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
cd PulseBar && swift build      # macOS 14+, Swift 5.9
cd PulseBar && swift test       # test count is reported by SwiftPM/CI
```

Gates, from the repo root — `package.sh` and CI both run all seven:

```bash
python3 scripts/version_check.py    # --fix aligns the followers
python3 scripts/coverage_check.py
python3 scripts/matrix_check.py
python3 scripts/make_agent_icons.py --check   # every AgentID has a mark
python3 scripts/appearance_check.py          # no appearance frozen into a constant
python3 scripts/resource_budget_check.py     # native fixture wall + RSS
python3 scripts/package_check.py    # reads the built .app
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

## Current state

1.2.0 is the current source version.

**1.0 marks the product, not the signature.** It was previously reserved for
"notarized", which is externally blocked without an Apple Developer ID — a
number that could never be reached said nothing about the product. Channel
honesty lives where it belongs, in `PulseDistributionChannel`: without an Apple
Developer ID, GitHub **Latest** tracks the current semver while the binary stays
`preview` / ad-hoc — **never stamp `stable` or claim Gatekeeper-ready.** See
`CHANGELOG.md`. Substance (1.2.0) shipped; its plan is historical. The next
candidate plan is [`docs/plan-respond.md`](docs/plan-respond.md), still
unnumbered: its foundations shipped as 1.0.1, and the first installment of
P0-0 evidence (vendor-binary code paths from Claude Code 2.1.233, provenance-
labelled) landed in the plan on 2026-08-17 — the worst-case branch (deny-only)
is excluded, and what remains of P0-0 is a short interactive confirmation on a
real machine, listed in the plan. Reserving a number for blocked work is what
forced two renames, so Respond still takes its number at release. A full-source
review at this baseline is [`docs/review-1.2.md`](docs/review-1.2.md).
