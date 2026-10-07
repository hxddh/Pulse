# Architecture notes

The targets, the data flow and the invariants are in
[`AGENTS.md`](../AGENTS.md); the event log is
[`attention-protocol.md`](attention-protocol.md); per-agent facts are
[`vendor-formats.md`](vendor-formats.md). This page keeps only what those do
not say.

## Who owns what

- **`ScanEngine`** (`@MainActor`, not observed): the `SessionBook`, the
  event-log cursor (generation header + byte offset) and the lines applied
  in this generation, the last good process list, the previous projection's
  open waits (the next edge baseline), one backing-off log retry and the two
  cheap timers. It reads the log and the process table off the main thread,
  calls `TrayState.project`, and hands the result to `StatusStore.land`. It
  holds no UI state.
- **`WaitNotifier`** (`@MainActor`, not observed): banner planning
  (`WaitingDelivery`), posting (`PulseNotify`), rate limiting, withdrawal and
  clicks. Its bookkeeping is the pure `WaitLedger`, in memory only.
- **`StatusStore`** (`@Observable`): only what views read — the snapshot,
  rows, settings, a few flags — and the intents views send; every decision
  is a pure model's (`TrayNoticeModel`, `BannerRoute`, `TrayRowModel`,
  `PulseSnapshot.needsPublish`). `land` assigns an observed property only
  when its value changed (`ScanQuietTests`). Settings (open at login,
  "don't suggest hooks") go through `StatusStore.set`, which writes
  `settings.json` only on a change; a login change asks macOS. The language is the system's
  (`ResolvedLanguage.system`), read once.

## Processes (libproc)

`AgentProcesses` lists the user's processes with `proc_listallpids`, reads
parent, TTY and start time (`PROC_PIDTBSDINFO`), path and argv
(`proc_pidpath`, `KERN_PROCARGS2`, one `KERN_ARGMAX` buffer per pass) and the
working directory (`PROC_PIDVNODEPATHINFO`), and matches each against the
catalog's process rules: the program itself (an interpreter adds its
script), on path-segment boundaries, deny lists first (`pi` is not `pip`,
`pinentry-mac` is not Pi, Cursor's worker daemon is not a session). A
wrapper and its child are one family. It never runs `ps` or `lsof`. A
`DispatchSource` exit source per session pid (`ProcessExitWatch`) ends a
session the moment its process exits; `AgentProcesses.stillRuns` catches a
reused pid.

## Views

`StatusItemController` owns the status item — the lamp (`Lamp`, drawn by
`Lamp.statusBarImage`), the title, the tooltip, the one-shot dip and the
VoiceOver announcement of a new wait — and the tray: an `NSPopover`
(`.transient`) anchored to the button whose content is the SwiftUI
`TrayView` in an `NSHostingController` sized by its ideal size (rows, the
header, at most one notice; → opens `SessionDetailView`). Opening activates
the app so the popover's window takes keys; a local key monitor, live while
the popover is shown, hands every key to the pure `TrayKeys.reduce`
(`TrayUI.handle`); closing with Esc, ⌘W or the button hands the keyboard
back to the app that had it. The row's context menu shows each item's key.
Settings is `SettingsWindowController` rendering `SettingsFace` from
`SettingsModel`.
Views do no I/O; every surface is a value with a fixture in
`PulseQA/SurfaceFixtures.swift` and a capture from `scripts/qa_captures.sh`.

## Landing — how ↩, a click or a banner reaches the prompt

The hook records where its session lives (the v6 `landing` column, most
specific first): `tmux:%3;tmuxsock:<socket>;iterm:w0t1p0:<uuid>;tty:/dev/ttys004;term:<TERM_PROGRAM>;app:<__CFBundleIdentifier>`.
`LandingPlan.make(handle:cwd:pid:hostApp:)` (pure, once per projection)
turns it into ordered steps; `TerminalFocus.land` (on the click) runs them
until one succeeds and reports **exact**, **app only** or **failed** — never
rounded up. The process table only fills what the hook did not say (tty,
Warp, host editor) and gives process-only rows their fallback.

| Handle | Steps | Precision |
| --- | --- | --- |
| `tmux:` (+ `tmuxsock:`) | `tmux [-S sock] switch-client ; select-window ; select-pane -t %N`, then activate the app owning the tmux client, else the `term:` / `app:` app | exact |
| `iterm:` + `term:iTerm.app` | AppleScript: select the session whose `unique id` matches | exact |
| `tty:` + Terminal / iTerm (or unknown) | AppleScript tab search by tty (running apps only) | exact |
| `term:ghostty` / `WezTerm` / `kitty` / `WarpTerminal` | activate the running app | app |
| `term:vscode` (`app:` tells Cursor, Windsurf… apart), `zed`, a host editor on the parent chain | `open -b <bundle> <cwd>`, then activate | app |
| none, live pid | activate the first regular app on the pid's parent chain | app |
| none | no Go; ↩ and banners open the detail page | — |

The AppleScript steps are always planned: no Pulse setting gates them, and
macOS's own Automation prompt on the first Go is the consent. The label is
**Go to terminal** only when the first step is exact, otherwise **Open app**.
An app-only landing says so — and, when an AppleScript step was tried, where
to allow Automation. Nothing is launched to look for a session, no IDE
extension is installed, nothing is typed into a terminal, and running apps
are never enumerated at scan time.

## Version identity

`PulseVersion.semver` is the truth; `package.sh` stamps the git sha, the
build date and the distribution channel into `Info.plist`.

| `PulseVersion.channel` | When | About shows |
| --- | --- | --- |
| `release` | bundle version == compiled version | `Pulse x.y.z` |
| `dev` | no bundle version (`swift run`) | `Pulse x.y.z-dev` |
| `mismatch` | they differ (an old copy still running) | `x.y.z≠a.b.c` and a warning |

`PulseDistributionChannel` is `preview` for every packaged build until a
notarization that stapler validates makes it `stable`; an unnotarized build
is never stable. Pulse makes no network connection: Settings' "Releases…"
opens the releases page in the browser. It never downloads or replaces
itself.
