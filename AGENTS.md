# Agent handoff — Pulse

macOS menu-bar status lamp for coding agents: `idle` / `running` / `needs you`.

## Orientation

| Doc | Read it when |
| --- | --- |
| [`README.md`](README.md) | You want to know what the product is |
| [`docs/architecture.md`](docs/architecture.md) | You are changing how data reaches the menu bar |
| [`EXPERIENCE.md`](EXPERIENCE.md) | You are changing anything the user sees — it is the acceptance basis |
| [`CHANGELOG.md`](CHANGELOG.md) | **Start here** — what shipped, and why |
| [`docs/review-11.0.md`](docs/review-11.0.md) | **The current review** — defects at the 11.0.3 baseline (fixed in 11.0.4) and the next-version evaluation (Kernel before Outcome) |
| [`docs/archive/`](docs/archive/README.md) | Historical plans (0.23 – 6.0) and superseded reviews (0.21, 1.2, 2.2) |
| [`docs/plan-2.0.md`](docs/plan-2.0.md) | The shipped 2.0 plan (Respond) — P0-0 evidence and the remaining real-machine confirmation checklist live here |
| [`docs/plan-12.0.md`](docs/plan-12.0.md) | The shipped 12.0 plan (Kernel) — PulseCore, AgentCatalog, scan-quiet Settings, and what is left for 12.x |
| [`docs/plan-outcome.md`](docs/plan-outcome.md) | The unnumbered next plan (Outcome) — result contracts and comparable evidence; blocked on real-machine Codex evidence |
| [`docs/respond-protocol.md`](docs/respond-protocol.md) | You are touching how a verdict travels between machines |
| [`CHANGELOG.md`](CHANGELOG.md) | You need to know when something changed |

Everything is Swift under `PulseBar/`; `src/` retains only the optional hook
scripts. Since 12.0 there are two targets: `PulseCore` (a Foundation-only
library — evidence, code identity, bounded IO, process supervision, transcript
parsing, probe cadence) and the `PulseBar` app. Nothing in `PulseCore` may
import AppKit, SwiftUI or reach `StatusStore`. **Adding an agent** means one
`case` and one `AgentSpec` in `AgentCatalog.swift`, plus its icon and README
row — `scripts/agent_catalog_check.py` fails if a per-agent table grows back
anywhere else. The legacy Python collector was deleted in 0.99 and the Vercel Native
SDK shell in 0.22 — recover either from git history if you ever need it.

## Invariants

These are product decisions, not preferences. Breaking one is a bug even if it
compiles and ships.

- **No fake Waiting.** Waiting comes from hooks or harvest `skill=pending`,
  never from inference. An agent with no Waiting path shows Running and says so.
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

12.2.0 is the current source version (Kernel + Seams + Groundwork — [`docs/plan-12.0.md`](docs/plan-12.0.md)).
The review behind it is [`docs/review-11.0.md`](docs/review-11.0.md); its
defects were fixed in 11.0.4. The next product axis is Outcome
([`docs/plan-outcome.md`](docs/plan-outcome.md)), unnumbered until the
real-machine Codex P0 evidence exists and the product decision in review-11.0
§4.3 has been made.

Still open: update signing (F-4, dormant until a Developer ID exists) and the
12.x structural phases listed in plan-12.0.
Respond's P0-0 real-machine confirmation (decision shape honoured) remains the
one unverified item of 2.0 — a wrong shape is silently ignored and falls open,
never a wrong approval.

Without an Apple Developer ID, GitHub **Latest** tracks the current semver
while the binary stays `preview` / ad-hoc — **never stamp `stable` or claim
Gatekeeper-ready.** Channel honesty lives in `PulseDistributionChannel`.
