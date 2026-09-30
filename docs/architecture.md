# Architecture notes

The targets, the data flow from a hook's line to the menu bar, and the
invariants are in [`AGENTS.md`](../AGENTS.md) ("Architecture",
"Invariants") — that is the one description. The event log is
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
  rows, settings, a few flags — and the intents views send. `land` assigns
  an observed property only when its value changed (`ScanQuietTests`).
  Settings go through `StatusStore.set` / `update`, which write
  `settings.json` only on a change and apply only that setting's effects
  (`StatusStore.effects(from:to:)`).

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

`StatusPanelController` owns the status item and the one `NSPanel`, which
hosts `TrayPanel` (rows, the header, at most one notice; → opens
`SessionDetailView`) and whose key monitor hands every key to the pure
`TrayKeys.reduce`. The row's context menu shows each item's key. Settings is
`SettingsWindowController` rendering `SettingsFace` from `SettingsModel`.
Views do no I/O; every surface is a value with a fixture in
`PulseQA/SurfaceFixtures.swift` and a capture from `scripts/qa_captures.sh`.

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
is never stable. The update check reads GitHub's `/releases/latest` only,
so a version published as a GitHub prerelease reaches nobody until it is
promoted. Pulse never downloads or replaces itself.
