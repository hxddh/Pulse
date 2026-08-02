# Agent handoff — Pulse

macOS menu-bar status lamp for coding agents: `idle` / `running` / `needs you`.

## Orientation

| Doc | Read it when |
| --- | --- |
| [`README.md`](README.md) | You want to know what the product is |
| [`docs/architecture.md`](docs/architecture.md) | You are changing how data reaches the menu bar |
| [`EXPERIENCE.md`](EXPERIENCE.md) | You are changing anything the user sees — it is the acceptance basis |
| [`CHANGELOG.md`](CHANGELOG.md) | **Start here** — what shipped, and why |
| [`docs/plan-0.27.md`](docs/plan-0.27.md) | The most recent written plan |
| [`CHANGELOG.md`](CHANGELOG.md) | You need to know when something changed |

Everything is Swift under `PulseBar/`, plus three Python scripts in `src/`
(harvest and hooks). The old Vercel Native SDK shell was deleted in 0.22 —
recover from git history if you ever need it.

## Invariants

These are product decisions, not preferences. Breaking one is a bug even if it
compiles and ships.

- **No fake Waiting.** Waiting comes from hooks or harvest `skill=pending`,
  never from inference. An agent with no Waiting path shows Running and says so.
- **No quota, cost, or reset HUD.** That is a different product.
- **No approve/deny in the tray.** Pulse tells you to go look; it does not act
  for you.
- **A harvest failure must not blank the scan.** Per-agent `guard()` in
  `activity_scan.py`; one broken collector cannot blind the other 31.
- **No fixed probe interval.** Cadence follows `ProbeSchedule` — a resident
  menu-bar app flagged for energy use is a dead product.
- **The builder stays pure.** `SnapshotBuilder` takes the world through
  `Context` and returns intents. Side effects belong in `StatusStore`.
- **Don't expand the hook installer** past Claude and Codex. Everything else
  goes through [`docs/attention-bridge.md`](docs/attention-bridge.md).

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
python3 scripts/harvest_stats_check.py       # harvest emits facts that move, and never guesses a tool
python3 scripts/package_check.py    # reads the built .app
```

`src/*.py` is the source of truth; `PulseBar/Sources/PulseBar/Resources/*.py`
are copies `package.sh` syncs. CI fails if they diverge — run `package.sh`
after editing harvest or hooks.

**Version truth:** `PulseBar/Sources/PulseBar/Models.swift` → `PulseVersion.semver`.
CHANGELOG's newest heading and the README badge follow it.

Debug log: `~/Library/Application Support/Pulse/debug.log` (rolls at 2 MB).

## Ship

```bash
./PulseBar/Scripts/package.sh
open zig-out/package/Pulse.app
```

Local packaging uses `PULSE_SIGN_IDENTITY` plus `PULSE_NOTARY_PROFILE` for a
distributable build. Release CI additionally requires the base64 Developer ID
certificate/password and App Store Connect API key secrets documented in the
README; it refuses to publish an ad-hoc or unnotarized build.

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

0.45.0 is the current source version. GitHub's latest public Release must be
checked separately; a merged version is not proof that a signed/notarized DMG
was published. See `CHANGELOG.md` for the complete contract.
