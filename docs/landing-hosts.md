# Host landing — what Pulse can (and cannot) deep-link

0.56 Landing Precision documents the spike for Cursor / VS Code / Zed /
Windsurf / Trae / Antigravity. Goal: land nearer than bare app activate when
evidence allows, without new TCC prompts at scan time.

## Available without Automation

| Host | App activate | Workspace folder | Composer / tab / session |
| --- | --- | --- | --- |
| Cursor | `NSWorkspace` / bundle id | `open -a Cursor.app <cwd>` | **Blocked** — no stable public URL scheme for a composer id without vendor API / TCC |
| VS Code | same | `open -a "Visual Studio Code.app" <cwd>` | **Blocked** — `vscode://file/...` opens a file, not a chat; unreliable across builds |
| Windsurf | same | `open -a Windsurf.app <cwd>` | **Blocked** — no documented session deep link |
| Zed | same | `open -a Zed.app <cwd>` | **Blocked** — workspace ok; no agent-thread URL |
| Trae | same | `open -a Trae.app <cwd>` | **Blocked** |
| Antigravity | same | `open -a Antigravity.app <cwd>` | **Blocked** |
| Warp | `NSWorkspace` | n/a (terminal app) | **Blocked** without Automation — Pulse advertises **Warp (app)** only |

## Pulse mapping

| Evidence | `FocusTier` | Click |
| --- | --- | --- |
| `viaWarp` | `.warp` | Activate Warp.app |
| Host + absolute `cwd` | `.hostWorkspace` | `open -a Host.app <cwd>`; fall back to activate |
| Host, no usable cwd | `.hostApp` | Activate host only |
| Real TTY + Shortcuts opt-in | `.tty` | AppleScript tab select (may prompt Automation once) |
| None | nil | Observation only; notify opens tray |

## Explicit non-goals

- Finder “Open directory” is not Focus (EXPERIENCE).
- Expanding the Claude/Codex hook installer is not a landing substitute.
- Scan-time enumeration of `NSWorkspace.shared.runningApplications` stays forbidden.
