# Agent observability contract

State — and everything a row says — comes from the vendors' own hook /
plugin / extension events. Pulse reads no vendor file: no session store, no
transcript, no protected app data.

## Two sources, each promising only what it can keep

| Source | How | Answers |
| --- | --- | --- |
| **Events** | `pulse-hook` / plugin / extension → the event log `events.tsv` (v5, append-only, one line per hook event) | working, blocked (needs you), your turn, ended; the title (first prompt), the last words, a turn's error, the last steps and the turn's clock |
| **Processes** | libproc at launch / wake / an unknown hook pid, and on a timer backing off 30 s → 5 min; a `DispatchSource` exit source per session pid | is an agent running; is a session's process still alive |

`SessionBook.apply(_:nowMs:)` is the only place state changes, and it is
rebuilt from the log at every launch. A session counts as running only while
its pid is alive; a session whose pid is unknown becomes `.recent` after 30
minutes without an event, and `TrayRowModel.why` says so. A process no session has
claimed is a process-only row (grey dotted lamp), which is how sessions
started before Pulse appear until their next event. A failed process scan
keeps the last good list, and a failed log read keeps what was applied;
neither ever removes a session.

## Per agent

Which events each agent installs, which of them say "needs you", and where
each one's title, steps and last words come from are in
[`vendor-formats.md`](vendor-formats.md) — the one place per-agent facts live
— with each contract's source pinned in `vendor-formats.json`. Every agent
has a truth table in `SessionBookTests`, and
`everyAgentsStepsComeFromItsOwnHook` pins where each one's steps and title
come from.

## What a row does not claim

- A stall (orange) needs an agent whose hook reports every tool call
  (`HookContract.reportsToolActivity`): Cursor and OpenCode speak at a prompt
  and at the end of a reply, so their quiet is never called a stall.
- A step is a past step: "Bash · swift test · 12m ago" says what the hook
  reported and when — never that it is still running.
- **Tokens, context, cost, model and plan are not shown — a decision.** The
  last step comes from events only; no source reads a usage, token count,
  rate limit or cost field (`catalog_check` holds it).
- Unknown is shown as unknown: Pulse never fills a gap by guessing from
  process count, CPU, a filename or an arbitrary JSON `name`.
