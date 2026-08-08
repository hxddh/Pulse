# Agent handoff — Pulse

macOS menu-bar status lamp for coding agents: `idle` / `running` / `needs you`.

## Orientation

| Doc | Read it when |
| --- | --- |
| [`README.md`](README.md) | You want to know what the product is |
| [`docs/architecture.md`](docs/architecture.md) | You are changing how data reaches the menu bar |
| [`EXPERIENCE.md`](EXPERIENCE.md) | You are changing anything the user sees — it is the acceptance basis |
| [`CHANGELOG.md`](CHANGELOG.md) | **Start here** — what shipped, and why |
| [`docs/plan-0.81.md`](docs/plan-0.81.md) | The active plan (Tray Substance) |
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

Everything is Swift under `PulseBar/`; `src/` retains optional legacy harvest
and hook scripts. The old Vercel Native SDK shell was deleted in 0.22 —
recover from git history if you ever need it.

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

Gates, from the repo root — `package.sh` and CI both run all eight:

```bash
python3 scripts/version_check.py    # --fix aligns the followers
python3 scripts/coverage_check.py
python3 scripts/matrix_check.py
python3 scripts/make_agent_icons.py --check   # every AgentID has a mark
python3 scripts/appearance_check.py          # no appearance frozen into a constant
python3 scripts/harvest_stats_check.py       # harvest emits facts that move, and never guesses a tool
python3 scripts/resource_budget_check.py     # native fixture wall + RSS
python3 scripts/package_check.py    # reads the built .app
```

`NativeActivityHarvest.swift` is the runtime source of truth. The Python files
are optional legacy/hook assets; `package.sh` may sync them for explicit
compatibility diagnostics, but a missing Python runtime must never block the
app, native harvest, or self-test.

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

0.81.0 is the current source version. Without an Apple Developer ID, GitHub
**Latest** tracks the current semver while the binary stays `preview` / ad-hoc —
never stamp `stable` or claim Gatekeeper-ready. See `CHANGELOG.md`. The active
plan is [`docs/plan-0.81.md`](docs/plan-0.81.md) (Tray Substance).
