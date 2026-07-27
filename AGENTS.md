# Agent handoff — Pulse

macOS menu-bar status lamp for coding agents (`idle` / `running` / `needs you`).

## Start here

| Doc | Role |
| --- | --- |
| [`EXPERIENCE.md`](EXPERIENCE.md) | Product IA / non-goals (source of truth for UX) |
| [`CHANGELOG.md`](CHANGELOG.md) | What shipped per version |
| [`README.md`](README.md) | Build & run |
| [`docs/attention-bridge.md`](docs/attention-bridge.md) | Optional waiting-signal bridge |
| [`docs/review-0.21.md`](docs/review-0.21.md) | Open findings + product gaps (read before planning work) |

**Version truth:** `PulseBar/Sources/PulseBar/Models.swift` → `PulseVersion.semver`.
`app.zon` / `src/version.zig` / CHANGELOG / README follow it — run
`python3 scripts/version_check.py --fix` after any bump. Build fingerprint
(git sha + date) is stamped into `Info.plist` by `package.sh`.

## Architecture (keep)

Probe + Harvest + Attention → `StatusStore.applyScan`. Python SoT lives in `src/`; `package.sh` syncs into app Resources (CI enforces the copies match).

Everything is Swift `PulseBar/`. The old Vercel Native SDK shell (`src/*.zig`, `app.zon`, `assets/`) was deleted in 0.22 — recover from git history if ever needed.

## Ship

```bash
./PulseBar/Scripts/package.sh          # runs all three gates first
open zig-out/package/Pulse.app
(cd PulseBar && swift test)            # PulseBar unit tests
```

Gates (also in CI): `scripts/version_check.py`, `scripts/coverage_check.py`,
`scripts/matrix_check.py`.

Distribution needs `PULSE_SIGN_IDENTITY` (+ optional `PULSE_NOTARY_PROFILE`);
without it the build is ad-hoc signed and Gatekeeper blocks it elsewhere.

## Release

Write the `## x.y.z` section in CHANGELOG.md first — every path refuses without it.

```bash
# preferred: bump + gates, then let CI publish
./scripts/release.sh 0.23.0                 # dry run: bump + gates + diff
./scripts/release.sh 0.23.0 --commit        # commit with the [release] marker
git push                                    # CI builds, tags and publishes
```

Three triggers, all landing in the same job:

| Trigger | When to use |
| --- | --- |
| `[release]` in the pushed commit subject | default; works from any branch, no tag-write rights needed |
| push a `v*.*.*` tag | if you prefer explicit tags and have tag-write access |
| `workflow_dispatch` | only once `release.yml` is on the **default branch** |

CI verifies the requested version matches `PulseVersion.semver`, runs the gates
and tests, packages the DMG, and publishes a Release whose body is that
version's CHANGELOG section. It creates the tag itself with its own
`contents: write` token — that is deliberate, so publishing never depends on a
developer's or agent's local credentials. It refuses to publish a version that
already has a Release, so re-pushing is harmless.

The in-app update check reads these Releases, so a version that never got
released is invisible to users.

## Do not break

- No quota / $ / reset HUD
- No tray approve/deny
- No fake Waiting (hooks / `skill=pending` only)
- No SessionStore / event bus rewrite
- Do not expand hook installer to ~22 agents
- Do not restore a fixed probe interval — cadence follows `ProbeSchedule`
- Do not let a harvest failure blank the whole scan (per-agent `guard`)

## Current IA (0.22+)

Glance traffic-light · session title as row hero · process-only rows de-ranked · whole-row click = focus.
