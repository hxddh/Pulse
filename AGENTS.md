# Agent handoff — Pulse

macOS menu-bar status lamp for coding agents (`idle` / `running` / `needs you`).

## Start here

| Doc | Role |
| --- | --- |
| [`EXPERIENCE.md`](EXPERIENCE.md) | Product IA / non-goals (source of truth for UX) |
| [`CHANGELOG.md`](CHANGELOG.md) | What shipped per version |
| [`README.md`](README.md) | Build & run |
| [`docs/attention-bridge.md`](docs/attention-bridge.md) | Optional waiting-signal bridge |

**Version truth:** `PulseBar/Sources/PulseBar/Models.swift` → `PulseVersion.semver`

## Architecture (keep)

Probe + Harvest + Attention → `StatusStore.applyScan`. Python SoT lives in `src/`; `package.sh` syncs into app Resources.

Primary UI: Swift `PulseBar/`. Old Zig UI in `src/` is reference only.

## Ship

```bash
./PulseBar/Scripts/package.sh
open zig-out/package/Pulse.app
```

Debug log: `~/Library/Application Support/Pulse/debug.log`

## Do not break

- No quota / $ / reset HUD
- No tray approve/deny
- No fake Waiting (hooks / `skill=pending` only)
- No SessionStore / event bus rewrite
- Do not expand hook installer to ~22 agents

## Current IA (0.21+)

Glance traffic-light · session title as row hero · process-only rows de-ranked · whole-row click = focus.
