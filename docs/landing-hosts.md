# Landing — how ↩ / click / banner reach the exact prompt

The hook records where its session lives (`HookLanding.handles`, the v6
`landing` column): `tmux:%3;tmuxsock:<socket>;iterm:w0t1p0:<uuid>;tty:/dev/ttys004;term:<TERM_PROGRAM>;app:<__CFBundleIdentifier>`.
`LandingPlan.make(handle:cwd:pid:hostApp:)` (pure, once per
projection) turns it into ordered steps; `TerminalFocus.land` (on the click)
runs them until one succeeds and reports **exact**, **app only** or
**failed** — never rounded up. The process table only fills what the hook did
not say (tty, Warp, host editor) and gives process-only rows their fallback.

| Handle | Steps | Precision | Needs Automation |
| --- | --- | --- | --- |
| `tmux:` (+ `tmuxsock:`) | `tmux [-S sock] switch-client ; select-window ; select-pane -t %N`, then activate the app owning the tmux client (its pid's parent chain), else the `term:`/`app:` app | exact | no |
| `iterm:` + `term:iTerm.app` | AppleScript: select the session whose `unique id` is the part after `:` | exact | yes |
| `tty:` + Terminal / iTerm (or unknown) | AppleScript tab search by tty (running apps only) | exact | yes |
| `term:ghostty` / `WezTerm` / `kitty` / `WarpTerminal` | activate the running app | app | no |
| `term:vscode` (`app:` tells Cursor, Windsurf… apart), `zed`, a host editor on the parent chain | `open -b <bundle> <cwd>`, then activate | app | no |
| none, live pid | activate the first regular app on the pid's parent chain | app | no |
| none | no Go; ↩ and banners open the detail page | — | — |

The AppleScript steps are always planned: no Pulse setting gates them, and
macOS's own Automation prompt, on the first Go, is the consent.

The label follows the plan: **Go to terminal** only when the first step is
exact, otherwise **Open app**. An app-only landing says "Opened the app —
can't select the exact terminal" — or, when the plan tried an AppleScript
step (Automation was denied), where to allow it: System Settings → Privacy &
Security → Automation; no button. A failed one says so and rescans.

## Non-goals

- No IDE extension: an editor cannot be told which integrated terminal, so it
  stays app precision.
- Nothing is launched to look for a session: only running terminals are
  activated or scripted.
- No typing into terminals, no Finder "open folder", no scan-time enumeration
  of `NSWorkspace.shared.runningApplications`.
