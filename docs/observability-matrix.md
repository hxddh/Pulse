# Agent observability contract

State comes from the vendors' own hook / plugin / extension events. Pulse
scans no session store and no protected app data (CHANGELOG says when the
harvest layer and its coverage matrix went).

## Three sources, each promising only what it can keep

| Source | How | Answers |
| --- | --- | --- |
| **Events** | `pulse-hook` / plugin / extension → the event log `events.tsv` (v5, append-only, one line per hook event) | working, blocked (needs you), your turn, ended |
| **Processes** | libproc at launch / wake / an unknown hook pid, and on a timer backing off 30 s → 5 min; a `DispatchSource` exit source per session pid | is an agent running; is a session's process still alive |
| **Transcript** | one bounded read (64 KB head + 256 KB tail) at a turn, a wait, or when the detail opens; cached per (path, size, mtime) | title, last message, model, last error |

`SessionBook.apply(_:nowMs:)` is the only place state changes. A session
counts as running only while its pid is alive; a session whose pid is unknown
becomes `.recent` after 30 minutes without an event, and `Explain.why` says so.
A process no session has claimed is a process-only row (grey dotted lamp),
which is how sessions started before Pulse appear until their next event.
A failed process scan keeps the last good list, and an unreadable transcript
only means a thinner row; neither ever removes a session.

## Per agent

| Agent | Hook events installed | Needs you (red) | Transcript dialect |
| --- | --- | --- | --- |
| Claude Code | SessionStart/End, UserPromptSubmit, PostToolUse, PermissionRequest, Notification, Stop, StopFailure | permission, question (elicitation) | Claude JSONL |
| Codex | SessionStart/End, UserPromptSubmit, PostToolUse (async), Stop (+ legacy `notify`) | never — its PermissionRequest fires before its own auto-review | rollout JSONL (legacy and paginated) |
| Cursor | sessionStart/End, afterAgentResponse, stop | never — no observe-only wait event | agent transcript JSONL |
| Pi | session_start/shutdown, agent_start, tool_execution_end, ui_prompt_start/end, agent_settled | `ui_prompt_start` | session JSONL (`session_info.name` wins) |
| Gemini CLI | SessionStart/End, BeforeAgent, AfterAgent, AfterTool, Notification | Notification `ToolPermission` | chat JSONL with `$set` / `$rewindTo` |
| GitHub Copilot | sessionStart/End, userPromptSubmitted, postToolUse, postToolUseFailure, agentStop, notification, errorOccurred | `permission_prompt`, `elicitation_dialog` | `session-state/<id>/events.jsonl` |
| OpenCode | session.created/status/idle/error/deleted, permission.*, question.* | `permission.asked`, `question.asked` | none — the event carries what is shown |

Each contract's source is pinned in `docs/vendor-formats.json` (see
`docs/vendor-formats.md`); every dialect has a vendor-shaped fixture in
`TranscriptSummaryTests`; every agent has a truth table in `SessionBookTests`.

## What a row does not claim

- A stall (orange) needs an agent whose hook reports every tool call
  (`HookContract.reportsToolActivity`): Cursor and OpenCode speak at a prompt
  and at the end of a reply, so their quiet is never called a stall.
- Tool names, skill names, tokens, context %, plan steps and file counts are
  not read. The row is the headline, the state and one age; the detail adds
  the last message, the model and the last error.
- Unknown is shown as unknown: Pulse never fills a gap by guessing from
  process count, CPU, a filename or an arbitrary JSON `name`.
