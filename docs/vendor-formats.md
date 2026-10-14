# Vendor contracts — every per-agent fact, and where each came from

State, and everything a row says, comes from the vendors' own hook / plugin
/ extension events; Pulse reads no vendor file. The title is the session's
first prompt, the last words and a turn's error are what the turn event
carried, and the steps are the per-tool events. When a vendor changes a hook
contract nothing fails loudly — an event stops arriving, or a new one is read
as the wrong state — so each contract names the source it was read from
(`vendor-formats.json`). The line each event writes is
[`attention-protocol.md`](attention-protocol.md).

Each agent is one adapter file in `PulseBar/Sources/PulseKit/Agents/`
(`Claude.swift`, `Codex.swift`, `Cursor.swift`, `Pi.swift`, `Copilot.swift`,
`OpenCode.swift`): its identity, process rule, where its hook goes and in
which format, every installed event with the action it means, whether it
can report a wait, and a `read` for the events whose meaning is in the
payload. The tables below are those files in prose.

## Install policy

- **Observe-only events.** Never PreToolUse, beforeShellExecution,
  `tool.execute.before`, Pi's `tool_call` / `tool_result` / `input` /
  `before_agent_start` / `turn_end` / `message_end`, permissionRequest or
  any other hook that can gate or change a decision
  (`HookContract.gatingEvents`), and never an answer: `pulse-hook` prints
  nothing and exits 0 at once. Claude's and Codex's entries are `async`.
- **Byte-for-byte reversible.** Before Pulse first writes a file it records
  the file's bytes (or that it did not exist) in
  `~/Library/Application Support/Pulse/hook-installs.json`. A removal puts
  the file back exactly when it is still what Pulse wrote (a file that did
  not exist is deleted again); a file edited since loses only Pulse's
  entries. Pulse's mark is the whole `pulse-hook` command (a path ending in
  `/pulse-hook`, or the bare word) — a user's `impulse-hook.sh` is not
  Pulse's. Invalid JSON, JSONC with comments and a `hooks` value that is not
  "event → array" are never rewritten, and the reason is said; only the
  `hooks` member is rewritten, every other key keeps its order and format;
  CRLF line ends and a UTF-8 BOM are kept. A module file of the same name
  that Pulse did not write is never overwritten.
- **Only agents on this Mac.** An agent whose vendor folder (`~/.claude`,
  `~/.codex`, …) does not exist gets no install. One agent's broken config
  fails only that agent. An agent whose install failed is not offered again
  by the setup card; the card says why.
- **One writer.** The installer writes the native `pulse-hook` launcher into
  every contract; nothing else writes the event log but it and the app's own
  dismissal. The hook records the agent's pid (the first ancestor matching
  the catalog's process rule — never the direct `sh -c` parent, never 1) and
  the landing handles, from `sysctl` and the environment only: it never
  forks and never runs `ps`. `pulse-hook` refuses an agent outside the roster
  (and Grok calling Claude's hooks).

## Where each hook is installed

Four formats (`HookFormat`), each with one writer in the installer: `nested`
(a user's settings file, Claude's and Codex's shape — the flavor says
`async` and which events the vendor runs synchronously), `versioned` (a
user's `{"version": 1, "hooks"}` file), `ownedJSON` (a hook file Pulse owns
whole) and `module` (a JavaScript plugin or extension Pulse owns whole,
rendered by its adapter).

| Agent | Installed into | Form | Reports "needs you" |
| --- | --- | --- | --- |
| Claude Code | `hooks` in `~/.claude/settings.json` | `nested`, every entry `async: true` | yes — `PermissionRequest`, `Notification` permission / question |
| Codex | `~/.codex/hooks.json` (never `config.toml`) | `nested` (`async`; `SessionEnd` synchronous, ≤ 3 s) | **no** — its `PermissionRequest` fires before its own auto-review: installing it would be a fake wait |
| Copilot CLI | `~/.copilot/hooks/pulse.json` (Pulse's own file) | `ownedJSON` | yes — `notification` `permission_prompt` / `elicitation_dialog` |
| OpenCode | `~/.config/opencode/plugins/pulse.js` (Pulse's own file) | `module`: a plugin, `event` only | yes — `permission.asked` / `question.asked` |
| Cursor | `~/.cursor/hooks.json` | `versioned` | **no** — it has no observe-only wait event |
| Pi | `~/.pi/agent/extensions/pulse.js` (Pulse's own file) | `module`: an extension | yes — `ui_prompt_start` / `ui_prompt_end` |

## What each event becomes

Every installed command is `pulse-hook <agent> <vendor event name>`; the
payload is the vendor's JSON on stdin (the two modules: the last argument).
Only the agent's own adapter reads it, and only for an event it installs:
an event's action is in its adapter's table, and `read` refines it from the
payload where the payload decides (marked *payload* below). A payload that
is not a JSON object — cut off at the 1 MiB stdin bound, broken, or plain
text — writes nothing, and so does an event the adapter does not know or
Pulse does not install (Copilot's VS Code–style PascalCase names included:
Pulse installs the camelCase ones).

| Agent | Vendor event | Pulse |
| --- | --- | --- |
| **Claude** (`~/.claude/settings.json`, every entry `async: true`) | `SessionStart` | `start` |
| | `UserPromptSubmit` | `working` (message = `prompt`) |
| | `PostToolUse`, `PostToolUseFailure` | `tool` (tool = `tool_name`, message = its target) |
| | `PermissionRequest` (*payload*) | `permission` — ask = `tool_name: command/file_path/url`, tool = `tool_name`; `AskUserQuestion` → `question`, ask = `tool_input.questions[0].question`; `ExitPlanMode` → ask = the plan's first line |
| | `Notification` `permission_prompt` (*payload*, as every `Notification` row) | `permission` |
| | `Notification` `elicitation_dialog` / `elicitation_url_dialog` / `agent_needs_input` | `question` |
| | `Notification` `idle_prompt` | `idle` |
| | `Notification` `elicitation_complete` / `elicitation_response` | `done` |
| | `Stop` | `turn` (message = `last_assistant_message`) |
| | `StopFailure` | `turn`, tool = `error` (message = `last_assistant_message`, else `error_details`, else `error`) |
| | `SessionEnd` | `end` |
| **Codex** (`~/.codex/hooks.json` only; `config.toml` is never touched) — never blocked | `SessionStart` / `UserPromptSubmit` / `Stop` / `SessionEnd` | `start` / `working` (message = `prompt`) / `turn` (message = `last_assistant_message`) / `end` |
| | `PostToolUse` (async) | `tool` (the stall rule's evidence; tool = `tool_name`, message = its target) |
| | `PermissionRequest` | never installed, not read (fires before Codex's own auto-review) |
| **Copilot CLI** (`~/.copilot/hooks/pulse.json`) | `sessionStart` / `sessionEnd` | `start` / `end` |
| | `userPromptSubmitted` | `working` (message = `prompt`) |
| | `postToolUse` / `postToolUseFailure` | `tool` (the tool ran: answers a `permission_prompt`; tool = `toolName`, message = the command or path in `toolArgs`, a JSON string) |
| | `agentStop` | `turn` |
| | `notification` `permission_prompt` / `elicitation_dialog` (*payload*) | `permission` / `question` |
| | `notification` `agent_idle` / `agent_completed` / `shell_completed` | ignored (background subagents and shells, not the session's turn) |
| | `errorOccurred` (*payload*) | `turn`, tool = `error`, message = `error.message` when `recoverable: false`; else `tool`, tool = `:status` |
| **OpenCode** (plugin `~/.config/opencode/plugins/pulse.js`; payload as the last argument; a subagent's child session is dropped, its asks sent under the root session) | `session.created` | `start` |
| | `session.status` `busy` / `retry` (*payload*) | `tool`, tool = `:status` |
| | `permission.asked` (*payload*: the ask) | `permission` (ask = `permission: patterns`) |
| | `question.asked` (*payload*: the ask) | `question` (ask = first question) |
| | `permission.replied` / `question.replied` / `question.rejected` | `done` |
| | `session.idle` | `turn` |
| | `session.error` | `turn`, tool = `error` (message = the error's message, forwarded by the plugin) |
| | `session.deleted` | `end` |
| **Cursor** (`~/.cursor/hooks.json`) — never blocked | `sessionStart` / `sessionEnd` | `start` / `end` |
| | `afterAgentResponse` | `tool` (no tool name) |
| | `stop` | `turn` (session = `conversation_id`, cwd = `workspace_roots[0]`) |
| **Pi** (extension `~/.pi/agent/extensions/pulse.js`; payload as the last argument) | `session_start` / `session_shutdown` (neither sent on `reason: "reload"`) | `start` / `end` |
| | `agent_start` | `working` (a run began; no text) |
| | `message_start` (sent for `role: "user"` only) | `working` (message = the message's text: the title) |
| | `tool_execution_end` | `tool` (tool = `toolName`, message = one argument — command, path, file_path, pattern, url or query — that the extension kept from the call's `tool_execution_start` by `toolCallId`; the end event carries no arguments. Sliced at 2000 characters only to bound the argv; the receiver redacts the whole value before it shortens it) |
| | `ui_prompt_start` `kind: confirm` / other kinds (*payload*) | `permission` / `question` (ask = `title`; never the event's `reason`, which is `ui_prompt`) |
| | `ui_prompt_end` | `done` |
| | `agent_settled` (*payload*) | `turn` (message = the run's last assistant words, which the extension kept from `agent_end`); `turn`, tool = `error` when that message stopped on an error (message = its `errorMessage`) |
| | `tool_execution_start`, `agent_end` | observed by the extension to fill the events above; never sent |

## Title, steps and last words

| Agent | Title (prompt event) | Step (tool event) | Last words / error |
| --- | --- | --- | --- |
| Claude | `UserPromptSubmit` `prompt` | `PostToolUse(Failure)` `tool_name` + `tool_input` | `Stop` `last_assistant_message`; `StopFailure` error |
| Codex | `UserPromptSubmit` `prompt` | `PostToolUse` `tool_name` + `tool_input` | `Stop` `last_assistant_message` |
| Copilot | `userPromptSubmitted` `prompt` | `postToolUse` `toolName` + `toolArgs` (a JSON string) | unrecoverable `errorOccurred` `error.message` |
| Pi | `message_start` (the person's message) | `tool_execution_end` + its call's argument from `tool_execution_start` | `agent_settled` with `agent_end`'s last assistant words; its `errorMessage` |
| OpenCode | — | — (no tool event) | `session.error` message |
| Cursor | — | — (no tool event) | — |

## The manifest

`docs/vendor-formats.json` has one entry per adapter, and each entry holds
only a `hooks` block:

| `source` | Meaning | Required fields |
| --- | --- | --- |
| `repo` | Open source; the receiver follows this commit | `repo`, `commit` (40 hex), `watch` (vendor files that define the hooks), `checked`, `events`, `tests` |
| `docs` | Closed source; public documentation was read | `urls`, `checked`, `events`, `tests` |

`events` must equal the adapter's `HookContract.events`. `tests` names test
files (grouped by component) that exercise the contract; each must exist and
mention the agent.

`scripts/catalog_check.py` (in `gates.sh`) fails when an agent has no
adapter file or no entry, an entry carries anything besides `hooks`, a repo
block lacks a full commit or watch list, the events disagree with the
adapter, a named test file is missing or never mentions the agent, a
contract lists a gating event, or a source outside `PulseKit/Agents/` spells
an installed vendor event. It also holds two facts: an agent that can raise a block installs an event that
answers it (`HookContract.answerEvents`: a per-tool event, or the vendor's
own "replied" / "prompt closed"), and Claude, Codex, Copilot and Pi
install their per-tool event (`PostToolUse`, `postToolUse`,
`tool_execution_end`) — the answer to a permission, and the only silence
that means a stall
(`HookContract.reportsToolActivity`). Each was checked non-blocking at exit 0
with empty output against the pinned source. Claude also installs
`PostToolUseFailure` (its output cannot change the outcome), never
`PermissionDenied` (its `retry` can change what the model does).
**Changing a hook contract means updating its block and its test in the same
change.**

## The sentinel

`.github/workflows/vendor-drift.yml` runs `scripts/vendor_drift.py` weekly
(and on demand). For every `repo` hooks block it makes a blob-less clone and
lists commits since the pin that touched a `watch` path. Any such commit
turns the run red and names the vendor, file and commits. It only reads
public repositories and prints; it writes nothing.

A red run is a prompt to read, not proof of breakage: read the commits, fix
the receiver and its test if the contract moved, then move the pin
(`commit`, `checked`) — the same change, so the gate and the sentinel agree.
