# Architecture notes

The targets, the data flow and the invariants are in
[`AGENTS.md`](../AGENTS.md); the event log is
[`attention-protocol.md`](attention-protocol.md); per-agent facts are
[`vendor-formats.md`](vendor-formats.md). This page keeps only what those do
not say.

## The kernel and the adapters

`PulseKit` is everything that can be said without a screen: the agent
adapters, the protocol and the event log, the hook receiver and the
installer, the process table, the session book, the tray projection, every
surface model and the copy. It imports Foundation (and Darwin, CryptoKit,
CoreGraphics for the cadence) and nothing that draws, notifies or registers
with the system; `surface_check.py` fails an import of SwiftUI, AppKit,
UserNotifications or ServiceManagement there. Its members are `package`: the
app, the QA driver and the tests are its only clients. `PulseApp` keeps
what needs AppKit or the main actor — the engine, the store, the notifier,
terminal focus, the status item, the views, the login item and the
frontmost-app question (`PromptVisibility.promptIsFrontmost`, which the
`--hook` path passes to the receiver without starting NSApplication).

An agent is one file in `PulseKit/Agents/`: an `AgentSpec` (identity,
process rule, waiting source, `HookContract` — path, format, each event
with its action — and a `read` for the events whose meaning is in the
payload, and the payload keys that name its session when they are not the
common order — Cursor's `conversation_id` first). `AgentSpec.reading(_:payload:)` is the whole dispatch: an event
not in the contract writes nothing, otherwise `read` decides or the event's
own action stands. The installer has one writer per `HookFormat`
(`nested`, `versioned`, `ownedJSON`, `module`), parameterized by the
format's flavor — never by the agent.

## Who owns what

- **`ScanEngine`** (`@MainActor`, not observed): the `SessionBook`, the
  event-log cursor (the header read, the byte offset, the log's `gen` and the
  last `seq` applied), the last good process list, the previous projection's
  open waits (the next edge baseline), one backing-off log retry and the two
  cheap timers. It reads the log and the process table off the main thread,
  applies the lines numbered past the cursor, calls `TrayState.project`, and
  hands the result to `StatusStore.land`. It holds no UI state.
- **`WaitNotifier`** (`@MainActor`, not observed): banner planning
  (`WaitingDelivery`), posting (`PulseNotify`), rate limiting, withdrawal and
  clicks. Its bookkeeping is the pure `WaitLedger`, in memory only.
- **`StatusStore`** (`@Observable`): only what views read — the snapshot,
  rows, settings, a few flags — and the intents views send; every decision
  is a pure model's (`TrayNoticeModel`, `BannerRoute`, `TrayRowModel`).
  `land` assigns an observed property only when its value changed
  (`ScanQuietTests`). The projection carries state only — a row's
  `AgentRow.Status`, never a step or a clock — so plain equality says "the
  same world" and a burst of tool lines lands nothing. What a session said
  lately (`SessionFacts`: steps, last words, error, clocks, the vendor
  events behind its state — `stateEvent`, `lastEvent` — and its timeline)
  is read from the book when a row or the detail page is drawn
  (`StatusStore.facts(for:)`),
  on the tray's own clock (`TimelineView`, `TrayChrome.clock`). Settings (open at login,
  "don't suggest hooks") go through `StatusStore.set`, which writes
  `settings.json` only on a change; a login change asks macOS. The language is the system's
  (`ResolvedLanguage.system`), read once.

## Provenance and connections

Every line keeps its vendor event (the v8 `event` column) through the
reducer: a session holds the event that put it in its current state (a
re-raise inside the grace keeps the first raise's, a held turn lands with
its own, a process exit has none) and its last `SessionBook.maxTimeline`
heard lines, each with the `SessionBook.Effect` the reducer decided as it
applied it — raised, said again, answered, your turn, held, dismissed,
seen, stopped, named, a step (or a failed one, with its `took`), a run of
consecutive steps of one speaker merged as it is heard (`StepRun`: each
tool and its count, how many failed — so the ring covers a turn), a
subagent's own lifecycle, an `ignored` line's reason — and which subagent
said it (`Heard.sub`, the v8 `sub` column; the detail page marks it
"Subagent · …"). The session also counts the current turn's steps and
failures, and keeps whether its last turn failed and whether the person
stopped it. Nothing is guessed from an event's name, and all of it is
rebuilt by the launch replay like every other fact. The why says what
happened in plain words and cites no event; the event names are the detail
page's timeline column (`EventName.display` refuses a column that is not a
name), Settings → Hooks and the report, which carries the last three
entries, a step by its tool only. An agent that cannot report a wait
(`WaitingSource.none`) says so — "doesn't report waits" — on its Settings
line, its detail page and its report line.

Settings' per-agent line is a `Connection`: the install
`HooksSupport.inspect` reads from the agent's config — the events that carry
Pulse's command against the adapter's contract (complete or partial), and
the launcher paths they name against this Pulse's launcher, which must run,
as must the app `hook-runner.path` names (else stale) — the last install's
failure, which wins, and the newest line and `ignored` line per agent, kept
by `ScanEngine` as it applies the log — with whether the log still held
every line it was given when it was replayed (`ScanEngine.logWhole`): only
then can "nothing heard yet" be said. `inspect` runs at launch, when
Settings opens and after an install; never on the scan path. Install all
fixes a partial or stale install.

## Processes (libproc)

`AgentProcesses` lists the user's processes with `proc_listallpids`, reads
parent, TTY and start time (`PROC_PIDTBSDINFO`), path and argv
(`proc_pidpath`, `KERN_PROCARGS2`, one `KERN_ARGMAX` buffer per pass) and the
working directory (`PROC_PIDVNODEPATHINFO`), and matches each against the
catalog's process rules: the program itself (an interpreter adds its
script; an interpreter whose arguments are all empty adds its argv[0] —
Node's `process.title = "pi"` overwrites argv in place on macOS, leaving
`node` with `["pi", "", …]`), on path-segment boundaries, deny lists first (`pi` is not `pip`,
`pinentry-mac` is not Pi, Cursor's worker daemon is not a session). A
wrapper and its child are one family. It never runs `ps` or `lsof`. A
`DispatchSource` exit source per session pid (`ProcessExitWatch`) ends a
session the moment its process exits; `AgentProcesses.stillRuns` catches a
reused pid. The hook finds its agent's pid by walking its own parent chain
with the same rules — or, for a module that spawns it directly and says
its pid (Pi), takes that pid when it is the hook's own parent.

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
A row and the detail page redraw on the tray's clock (`TimelineView`,
every `TrayChrome.clock` seconds while the tray is open): their relative
times and the session's facts move without a projection. Views do no I/O;
every surface is a value with a fixture in
`PulseQA/SurfaceFixtures.swift` and a capture from `scripts/qa_captures.sh`.

## Landing — how ↩, a click or a banner reaches the prompt

The hook records where its session lives (the v8 `landing` column, most
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
build date and the distribution channel into `Info.plist`, and the bundle
identifier from `PulseVersion.bundleID` (`io.github.hxddh.pulse`;
`package_check.py` holds the built app to it). Every other reverse-DNS name
— the queues, the reopen notification — derives from it. Nothing is carried
over from an earlier identifier.

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

## Proof — what runs the real path

The unit tests pin each component; these layers run the parts together, the
way an agent and a person reach them. None of them ships: the flags live in
`PulseQA` (`ProofDriver`, `TrayAccessibilityCheck`; `package_check.py`
fails an app binary that carries one).

| Layer | Where | What it proves |
| --- | --- | --- |
| Recorded payloads | `PulseBar/Tests/Fixtures/hooks/<agent>/<event>[@variant].json`, `expected.json` | One payload per installed event at least (`catalog_check` fails an event without one), reconstructed from the contract's pinned source; fields no primary source confirms are `unverified` in `vendor-formats.json` |
| In process | `RecordedPayloadTests` (`VendorFormatTests.swift`) | Every fixture through `PulseHookReceiver.run`, the way its hook hands it over (stdin, or the modules' last argument), becomes the line `expected.json` names — a state or the `ignored` line that says why, never an unreadable payload |
| Modules under Node | `scripts/js_adapters_test.mjs` | The Pi extension and the OpenCode plugin (1.x and 2.x) run against a stub of their vendor's API with a stub launcher; recorded sequences (a turn with tools, an ask and its answer, a question, parallel asks, a subagent, shutdown) produce exactly these ordered `pulse-hook` calls. Linux renders the modules with `scripts/render_adapters.py`; macOS CI renders them with the compiled code (`PulseQA --write-adapters`) and fails when the two differ. A case marked `knownBug` states a defect's correct behaviour and reports XFAIL until it is fixed |
| End to end | `scripts/e2e.sh`, after `package.sh` | In a throwaway home the real installer (`PulseQA --install-hooks`) writes every hook and points the launcher at the packaged app; fixtures go through the installed `pulse-hook` into `PulseBar --hook`; `PulseQA --dump-snapshot` replays that log as `ScanEngine` does (one projection per line, a `WaitLedger` beside it) and the script checks red + one banner, the answer (running, banner withdrawn), the end (no live row) — for Claude on stdin and Pi in argv — then every fixture's line |
| The tray | `qa_captures.sh tray-a11y` (`--assert-tray`) | The real popover opens on a fixture, its window becomes key, and its accessibility tree has each row as a button with its "›" Details as a separate button |
| The owner | `scripts/smoke.sh` | On a real Mac: quarantine, signature, the installed hooks (read-only), then a real Claude permission and a real Pi prompt, their answers and a click, each confirmed against the lines `events.tsv` gains; prints a report in Chinese |

**Home.** Foundation's home directory on macOS honours `CFFIXED_USER_HOME`,
not `HOME`. Pulse's own folder follows `PULSE_HOME` (`EventLog.directory`,
read by the hook and the snapshot); the installer's home is
`HooksInstaller.homeOverride`, which `--install-hooks=<home>` sets, as the
tests do. `e2e.sh` sets all three (and `HOME`) to the throwaway home, so
nothing lands in the real one; no app code reads an override it did not
already read.
