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

```bash
# 1. write the '## x.y.z' section in CHANGELOG.md first — release.sh refuses without it
./scripts/release.sh 0.23.0          # dry run: bump + gates + diff
./scripts/release.sh 0.23.0 --tag    # commit + annotated tag
git push && git push --tags          # tag push triggers the release workflow
```

Note: `workflow_dispatch` on the release workflow only becomes available once
`release.yml` is on the **default branch** — until then, a tag push is the only
trigger. Tag pushes also need credentials with tag-write scope; a session
restricted to `refs/heads/claude/*` cannot cut the release itself.

`.github/workflows/release.yml` verifies the tag matches `PulseVersion.semver`,
runs the gates and tests, packages the DMG and publishes a GitHub Release whose
body is that version's CHANGELOG section. The in-app update check reads those
Releases, so a version that never got tagged is invisible to users.

Debug log: `~/Library/Application Support/Pulse/debug.log`

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
