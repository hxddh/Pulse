# Vendor contracts — every per-agent fact, and where each came from

State, and everything a row says, comes from the vendors' own hook / plugin
/ extension events; Pulse reads no vendor file. The title is the session's
first prompt, the last words and a turn's error are what the turn event
carried, and the steps are the per-tool events. When a vendor changes a hook
contract nothing fails loudly — an event stops arriving, or a new one is read
as the wrong state — so each contract names the source it was read from
(`vendor-formats.json`). The line each event writes is
[`attention-protocol.md`](attention-protocol.md).

Every installed event also has a payload in
`PulseBar/Tests/Fixtures/hooks/<agent>/<event>.json` (variants
`<event>@<variant>.json`), as the hook hands it to `pulse-hook`, and
`expected.json` there says the line it becomes; `catalog_check` fails an
event without one. They are reconstructed from the pinned source, not
captured from a live run: a field no primary source confirms is listed under
the agent's `unverified` in `vendor-formats.json` (today: Cursor's payload
fields). `RecordedPayloadTests` reads them in process and `scripts/e2e.sh`
through the packaged app ([`architecture.md`](architecture.md), "Proof").

Each agent is one adapter file in `PulseBar/Sources/PulseKit/Agents/`
(`Claude.swift`, `Codex.swift`, `Cursor.swift`, `Pi.swift`, `Copilot.swift`,
`OpenCode.swift`): its identity, process rule, where its hook goes and in
which format, every installed event with the action it means, whether it
can report a wait, and a `read` for the events whose meaning is in the
payload. The tables below are those files in prose.

## Install policy

- **Observe-only events.** Never PreToolUse, beforeShellExecution,
  `tool.execute.before`, Pi's `tool_call` / `tool_result` / `input` /
  `before_agent_start` / `turn_end` / `message_end` / `user_bash` /
  `session_before_*`, permissionRequest or
  any other hook that can gate or change a decision
  (`HookContract.gatingEvents`), and never an answer: `pulse-hook` prints
  nothing and exits 0 at once. Claude's and Codex's entries are `async`.
- **Async neutralizes decision output.** The vendor runs an async entry in
  the background and reads no decision from it — Claude: `decision`,
  `permissionDecision`, `continue` (and `PermissionDenied`'s `retry`) have
  nothing left to control; Codex never reads an async handler's output. So
  an event whose only control is a decision output is observe-only when
  installed async (Claude's `PermissionDenied`, `SubagentStop`; Codex's
  `SubagentStop`). One exception, an owner decision: Copilot's `agentStop`
  and `postToolUse` / `postToolUseFailure` are synchronous and could return
  a decision (`decision: "block"`, `modifiedResult`); Pulse's hook appends
  one line and prints nothing, so it never decides. An event whose hook takes the vendor's place —
  `PreToolUse` gates a tool, `Elicitation` can answer an MCP form for the
  person, `WorktreeCreate` makes the worktree, `MessageDisplay` holds every
  streamed batch and replaces what is shown — is never installed, async or
  not.
- **Modules read the stream, never a hook.** The OpenCode plugin and the Pi
  extension subscribe to the vendor's own event stream (OpenCode's bus — the
  1.x `event` hook, 2.x `ctx.event.subscribe` —, Pi's `pi.on`). Never a hook
  that can change a tool's input or output, a message, a prompt or a
  permission (`tool.execute.before` / `after`, `chat.message`,
  `chat.params`, `permission.ask`, 2.x's `ctx.*.hook` / `transform`). Every
  handler is wrapped in `try`, returns nothing and never awaits a child.
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
  `~/.codex`, …) does not exist gets no install. No environment variable is
  followed (a GUI app cannot see the shell's): Pi loads extensions from
  `getAgentDir()`, which `PI_CODING_AGENT_DIR` can move; Pulse installs to
  `~/.pi/agent` regardless, and when that folder is missing on a Mac where
  Pi is present (`~/.pi`, or a running Pi process) Settings → Hooks says
  where Pulse installs (`HookContract.relocation`,
  `Connection.configDirMissing`). A Pi pointed elsewhere does not load it.
  The same holds for OpenCode (`OPENCODE_CONFIG_DIR` — 1.x an extra folder,
  2.x the global one — and `XDG_CONFIG_HOME`, which moves `~/.config`) and
  Copilot (`COPILOT_HOME`: hooks then load from `$COPILOT_HOME/hooks/`).
  Copilot's session sandbox runs user hooks inside it with the agent's own
  access: Pulse's folder (`~/Library/Application Support/Pulse`) must be
  granted in `sandbox.userPolicy` (`~/.copilot/settings.json`), or the hook
  cannot write its line. Pulse never edits that setting; Settings → Hooks
  says "installed — nothing heard yet" for a whole install nothing was heard
  through (`Connection.Caveat.neverHeard`: no line from the agent at all, or,
  in a file Pulse owns whole, none since it was written). One agent's broken config
  fails only that agent. An agent whose install failed is not offered again
  by the setup card; the card says why.
- **One writer.** The installer writes the native `pulse-hook` launcher into
  every contract; nothing else writes the event log but it and the app's own
  dismissal. The hook records the agent's pid (the first ancestor matching
  the catalog's process rule — never the direct `sh -c` parent, never 1; or,
  for Pi, whose extension spawns the hook itself, the `pid` it sends, only
  when it is the hook's own parent) and the landing handles, from `sysctl` and the environment only: it never
  forks and never runs `ps`. `pulse-hook` refuses an agent outside the roster
  (and Grok calling Claude's hooks).

## Where each hook is installed

Four formats (`HookFormat`), each with one writer in the installer: `nested`
(a user's settings file, Claude's and Codex's shape — the flavor says
`async` and which events the vendor runs synchronously), `versioned` (a
user's `{"version": 1, "hooks"}` file), `ownedJSON` (a hook file Pulse owns
whole; `OwnedCommand` says whether an entry is a shell line or the launcher
run directly — `exec` + `args` — and an event's `matcher` is written) and
`module` (a JavaScript plugin or extension Pulse owns whole, rendered by its
adapter).

| Agent | Installed into | Form | Reports "needs you" |
| --- | --- | --- | --- |
| Claude Code | `hooks` in `~/.claude/settings.json` | `nested`, every entry `async: true` | yes — `PermissionRequest`, `Notification` permission / question (not when nobody can be shown it: `dontAsk`, `claude -p` without a permission host) |
| Codex | `~/.codex/hooks.json` (never `config.toml`) | `nested` (`async`; `SessionEnd` synchronous, ≤ 3 s; `Interrupt` async, timeout written at its 3 s cap) | **no** — its `PermissionRequest` fires before its own auto-review: installing it would be a fake wait |
| Copilot CLI | `~/.copilot/hooks/pulse.json` (Pulse's own file; `COPILOT_HOME` is not followed) | `ownedJSON`, each entry `exec` + `args` (no shell), `timeoutSec`; `notification` and `preCompact` with a `matcher` | yes — `notification` `permission_prompt` / `elicitation_dialog` |
| OpenCode (1.x and 2.x) | `~/.config/opencode/plugins/pulse.js` (Pulse's own file; `OPENCODE_CONFIG_DIR` / `XDG_CONFIG_HOME` are not followed) | `module`: one plugin, `export default { id, server, setup }` — 1.x calls `server` (its `event` hook), 2.x calls `setup` (`ctx.event.subscribe`) | yes — 1.x `permission.asked` / `question.asked`, 2.x `permission.asked` / `form.created` |
| Cursor | `~/.cursor/hooks.json` | `versioned` | **no** — it has no observe-only wait event |
| Pi | `~/.pi/agent/extensions/pulse.js` (Pulse's own file; `PI_CODING_AGENT_DIR` is not followed) | `module`: an extension | yes — `ui_prompt_start` / `ui_prompt_end` (not its `/login` wait or its missing-cwd confirm) |

## What each event becomes

Every installed command is `pulse-hook <agent> <vendor event name>`; the
payload is the vendor's JSON on stdin (the two modules: the last argument).
Only the agent's own adapter reads it, and only for an event it installs:
an event's action is in its adapter's table, and `read` refines it from the
payload where the payload decides (marked *payload* below). Every line
carries the vendor's event name in its `event` column. A payload that is
not a JSON object — cut off at the 1 MiB stdin bound, broken, or plain text
— is an `ignored` line and nothing else, and so is an event the adapter
does not know or Pulse does not install (Copilot's VS Code–style PascalCase
names included: Pulse installs the camelCase ones), a known event that says
nothing Pulse shows ("ignored" below), activity or a prompt that names no
session, and a blocked event from Codex or Cursor. The `ignored` line's
message says which (`PulseHookReceiver.Ignored`); the reducer skips it.

**Subagents.** Inside a subagent Claude's and Codex's events carry
`agent_id`, Copilot's `agentId` (`AgentSpec.subagentKeys`): the line's `sub`
column. A subagent's line never answers the main agent's block (or another
subagent's), never revives an ended turn, and its prompt is not the person's
(`attention-protocol.md`, reader rules). OpenCode's plugin folds a child
session's asks (and their answers) into the root session and drops its
lifecycle, prompts and steps — the child is learned from the `parentID` on
any session event that carries one; Pi's subagents are separate
`pi --mode json` processes, which the extension silences. Copilot's
`subagentStart` names the agent (`agentName`), not the `agentId` its own
events carry: its status line is marked with the name.

| Agent | Vendor event | Pulse |
| --- | --- | --- |
| **Claude** (`~/.claude/settings.json`, every entry `async: true`) | `SessionStart` | `start` |
| | `UserPromptSubmit` | `working` (message = `prompt`) |
| | `PostToolUse`, `PostToolUseFailure` (*payload*) | `tool` (tool = `tool_name`, an MCP tool `mcp__server__tool` as `server · tool`; message = its target — an `Agent` / `Task` call's `description`, else `subagent_type`; a `Skill`'s `skill`; else the command, path, URL, pattern or query; `PostToolUseFailure`: `err` = 1) |
| | `PostToolUseFailure` with `is_interrupt: true` | `stopped` (the call reached Claude as an abort: the person interrupted) |
| | `PermissionRequest` (*payload*) | `permission` — ask = `tool_name: command/file_path/url` (an `Agent` call: its description), tool = `tool_name`; `AskUserQuestion` → `question`, ask = `tool_input.questions[0].question`; `ExitPlanMode` → ask = the plan's first line. `ignored` — "no prompt can be shown" — when `permission_mode` is `dontAsk`, or the Claude process runs `-p` / `--print` without `--permission-prompt-tool` (its argv, `AgentProcessRule.promptlessFlags`): Claude denies it itself |
| | `PermissionDenied` (*payload*; async) | `status` (message = `auto mode denied <tool>`; no tool column — a status that names a tool says it runs now; `reason` is not read) |
| | `Notification` `permission_prompt` (*payload*, as every `Notification` row) | `permission` |
| | `Notification` `elicitation_dialog` / `elicitation_url_dialog` | `question` |
| | `Notification` `agent_needs_input` | `ignored` — "may be about another session" (agent view's background session, a teammate's setup question, a billing notice: the payload does not name the session that waits) |
| | `Notification` `idle_prompt` | `idle` |
| | `Notification` `elicitation_complete` / `elicitation_response` | `done` |
| | `SubagentStart` / `SubagentStop` (*payload*) | `start` / `turn` with `sub` = `agent_id` — the subagent's own lifecycle, timeline only (its `SubagentStop` answers only its own block); without `agent_id`: ignored |
| | `PostCompact` (*payload*) | `status` (message = `compacted`) when `trigger` is `auto`; a manual `/compact` (the person at the prompt, no `Stop` follows) is ignored. `compact_summary` is never read |
| | `Stop` | `turn` (message = `last_assistant_message`; `background_tasks` / `session_crons` are not read) |
| | `StopFailure` | `failed` (message = `last_assistant_message`, else `error_details`, else `error`) |
| | `SessionEnd` | `end` |
| **Codex** (`~/.codex/hooks.json` only; `config.toml` is never touched) — never blocked | `SessionStart` / `UserPromptSubmit` / `Stop` / `SessionEnd` | `start` / `working` (message = `prompt`; a subagent's, with `agent_id`, is its own task) / `turn` (message = `last_assistant_message`) / `end` |
| | `PostToolUse` (async) | `tool` (the stall rule's evidence; tool = `tool_name`, message = its target) |
| | `SubagentStop` (*payload*; async) | `turn` with `sub` = `agent_id` (the child thread; `session_id` is the root's) — timeline only, never the end of the person's turn |
| | `Interrupt` (async, ≤ 3 s; root turns only) | `stopped` (the person interrupted the turn) |
| | a turn that ends on an error | nothing: Codex fires no `Stop` for it, and Pulse infers nothing — the row stays working until the next event, the process's exit or the silent bound |
| | `PermissionRequest` | never installed, not read (fires before Codex's own auto-review) |
| **Copilot CLI** (`~/.copilot/hooks/pulse.json`, `exec` + `args`) | `sessionStart` (*payload*) / `sessionEnd` | `start` (message = `initialPrompt`, a `-p` run's prompt: the session's name) / `end` |
| | `userPromptSubmitted` | `working` (message = `prompt`) |
| | `postToolUse` / `postToolUseFailure` (synchronous — the owner-approved exception) | `tool` (the tool ran: answers a `permission_prompt`; tool = `toolName`, message = the command or path in `toolArgs`, a JSON string; `postToolUseFailure`: `err` = 1; with `agentId`: the subagent's step, never the answer to the main agent's block) |
| | `agentStop` (synchronous — the owner-approved exception) | `turn` |
| | `notification` `permission_prompt` / `elicitation_dialog` (*payload*; installed with `matcher` `permission_prompt\|elicitation_dialog\|agent_idle`) | `permission` / `question` |
| | `notification` `agent_idle` | ignored (a background subagent's idle, not the session's turn) |
| | `errorOccurred` (*payload*) | `failed`, message = `error.message` when `recoverable: false`; else `status` (work going on: never starts a turn) |
| | `subagentStart` (*payload*; cannot block) | `status` with `sub` = `agentName`, message = `subagent started` — timeline only |
| | `preCompact` (*payload*; notification only, `matcher` `auto`) | `status` (message = `compacting`); `trigger: manual` ignored |
| **OpenCode 1.x** (plugin `~/.config/opencode/plugins/pulse.js`, `event` hook; payload as the last argument, the plugin's own shape; one child at a time, in order; a subagent's child session dropped, its asks sent under the root session) | `session.created` | `start` (message = a non-default `info.title`) |
| | `session.updated` (sent when a root's non-default title changes) | `title` (message = `info.title`) |
| | `message.part.updated` (*payload*: `phase`) | a user message's first non-synthetic text (`message.updated` role user, observed) → `working` (message = the text: the title); a tool part's first `running` state → `status` (tool = `tool`, message = one input argument: what runs now); its `completed` / `error` state, once per `callID` → `tool` (`err` on error, `took` = `time.end − time.start`; a call an abort interrupted is not sent) |
| | `session.status` `busy` (sent when it changes) / `retry` (*payload*) | `status` (anything else: `ignored`) |
| | `permission.asked` (*payload*: the ask) | `permission` (ask = `permission: patterns`; tool = the asking call's tool, by `tool.callID`, else the permission) |
| | `question.asked` (*payload*: the ask) | `question` (ask = first question) |
| | `permission.replied` / `question.replied` / `question.rejected` (*payload*: `pending`) | `done` when no other ask of the root is open; else ignored (the lamp stays red) |
| | `session.idle` | `turn` (not sent after an abort) |
| | `session.error` (*payload*: `error_name`) | `MessageAbortedError` → `stopped`; `ContextOverflowError` → `status` (`compacting`: auto-compaction goes on; with it off, `session.idle` follows); else `failed` (message = the error's message); no `sessionID` → ignored ("no session") |
| | `session.compacted` | `status` (message = `compacted`) |
| | `session.deleted` | `end` |
| **OpenCode 2.x** (the same plugin, `setup`: `ctx.event.subscribe`; events of another folder skipped) | `session.created` / `session.renamed` | `start` (message = `title`) / `title` (sent when it changes) |
| | `session.execution.started` / `session.inbox.enqueued` (user items only) | `working` (no text) / `working` (message = the item's text) |
| | `session.tool.called` | `status` (tool = the name `session.tool.input.started` gave the call — observed, never sent —, message = one input argument) |
| | `session.tool.success` / `session.tool.failed` | `tool` (`err` on failed, `took` from the events' `created` clocks) |
| | `permission.asked` (*payload*) | `permission` (ask = `message`, else `action: resources`; tool = the asking call's, by `source.id`, else the action) |
| | `form.created` (*payload*) | `question` (ask = the first field's `description`, else its `title`, else the form's) |
| | `permission.replied` / `form.replied` / `form.cancelled` (*payload*: `pending`) | `done` when no other ask of the root is open; else ignored |
| | `session.execution.succeeded` / `session.execution.failed` | `turn` / `failed` (message = `error.message`) |
| | `session.execution.interrupted` (*payload*: `reason`) | `user` → `stopped`; `inactivity` → `failed`; `superseded` / `shutdown` ignored |
| | `session.retry.scheduled` / `session.compaction.ended` | `status` (message = `retrying` / `compacted`; no cost or token field is read) |
| | `session.deleted` | `end` |
| **Cursor** (`~/.cursor/hooks.json`; session = `conversation_id`, read before `session_id`; cwd = `workspace_roots[0]`) — never blocked | `sessionStart` / `sessionEnd` | `start` / `end` |
| | `afterShellExecution` (*payload*) | `tool` (tool = `Shell`, message = `command`, `took` = `duration` when present; `output` is never read) |
| | `afterFileEdit` (*payload*) | `tool` (tool = `Edit`, message = `file_path` relative to its workspace root, else its name; `edits` are never read) |
| | `afterMCPExecution` (*payload*) | `tool` (tool = `server · tool` when the payload names its server, else `tool_name`; `tool_input` / `result_json` are never read) |
| | `afterAgentResponse` (*payload*) | `tool` with no tool name (message = `text`: the turn's last words so far) |
| | `stop` (*payload*: `status`) | `completed` → `turn`; `error` → `failed` (no error text); `aborted` → `stopped` |
| **Pi** (extension `~/.pi/agent/extensions/pulse.js`; payload as the last argument; nothing sent when `ctx.mode` is `json` or `print`; one child at a time, in emission order) | `session_start` / `session_shutdown` (neither sent on `reason: "reload"`) | `start` (message = `getSessionName()`, when set) / `end` (flushes the queue) |
| | `session_info_changed` | `title` (message = the new name; empty clears it) |
| | `agent_start` | `working` (a run began; no text) |
| | `message_start` (sent for `role: "user"` only) | `working` (message = the message's text: the title; a skill block is sent as `/skill:name args`, never its path) |
| | `tool_execution_start` (not sent with `parentToolCallId`) | `status` (tool = `toolName`, message = its target: what runs now; a long tool is not a stall) |
| | `tool_execution_end` (not sent with `parentToolCallId`) (*payload*) | `tool` (tool = `toolName`, message = the target the extension kept from the call's `tool_execution_start` by `toolCallId` — `command` for bash / powershell, `path` for read / edit / write / ls, `pattern` for grep / find, else the first of command, path, file_path, pattern, url, query; `err` = `isError`, `took` = `durationMs`. Sliced at 2000 characters only to bound the argv; the receiver redacts the whole value before it shortens it) |
| | `ui_prompt_start` `kind: confirm` / `select`, `input`, `editor` (*payload*) | `permission` / `question` (ask = `title`; never the event's `reason`, which is `ui_prompt`) — as Pi's own `setBlocked` reporter says them |
| | `ui_prompt_start` / `ui_prompt_end` `kind: custom` (*payload*) | `ignored` — "a prompt that does not block" (a custom view; Pi never marks it blocked) |
| | `ui_prompt_end` | `done` |
| | `agent_settled` (*payload*) | `turn` (message = the run's last assistant words, which the extension kept from `agent_end`); `failed` when that message stopped on an error (message = its `errorMessage`); `stopped` when `aborted` (the person pressed Escape: no words) |
| | `agent_end` | observed by the extension to fill `agent_settled`; never sent |

**What Claude says without a prompt.** Claude runs `PermissionRequest`
hooks in sessions that cannot show a prompt and denies the call when no hook
decides; in `dontAsk` mode it denies whatever is not pre-approved. Neither is
a wait: the line is `ignored`, "no prompt can be shown". A `claude -p` run
with `--permission-prompt-tool` (the Agent SDK's host — Claude Desktop, the
VS Code extension) does show its prompt and stays a wait.

**Silenced installs.** Settings → Hooks reads, never writes, what keeps an
installed hook from running (`HookContract.offSwitches`,
`Connection.Caveat`): Claude's `disableAllHooks: true` in
`~/.claude/settings.json` ("turned off in Claude's settings"), and
`allowManagedHooksOnly` / `disableAllHooks: true` in
`/Library/Application Support/ClaudeCode/managed-settings.json` or
`managed-settings.d/*.json` ("a managed policy keeps Claude from running
it"). A project's own `disableAllHooks: false` can override the user's
`true`; Pulse reads only the user file and says so as a warning, not a
verdict. Codex trusts each hook by a hash of its entry
(`engine/discovery.rs`): any change Pulse makes leaves its entries
"modified" and silent until the person trusts them again in `/hooks`
(`NestedFlavor.trustBound`). When the install is whole, a Codex process
started after `hooks.json` last changed and nothing was heard since,
Settings says Codex hasn't run it — trust it in `/hooks`. Codex's
`allow_managed_hooks_only` lives in `config.toml`, which Pulse never reads.

**What Pi cannot report.** Pulse sees only what passes through Pi's
extension events. Pi's `/login` OAuth wait (`setBlocked("login")`) and its
"Session cwd not found" confirm on resume (`promptForMissingSessionCwd`)
show no `ui_prompt_*` event: Pi waits there and the lamp does not turn red.

**Order.** Each event is one `pulse-hook` child and the log numbers lines
in the order the children take its lock, so the extension spawns the next
child only when the one before it has exited (or after a 1.5 s guard), keeps
at most 64 waiting (a block, its answer, the turn's end and the shutdown are
dropped last) and spawns whatever is left at once on `session_shutdown`. A
prompt's end is never numbered before its start.

## Title, steps and last words

| Agent | Title (prompt event) | Step (tool event) | Last words / error |
| --- | --- | --- | --- |
| Claude | `UserPromptSubmit` `prompt` | `PostToolUse(Failure)` `tool_name` (MCP: `server · tool`) + `tool_input` (`Agent`: `description` / `subagent_type`; `Skill`: `skill`) | `Stop` `last_assistant_message`; `StopFailure` error |
| Codex | `UserPromptSubmit` `prompt` | `PostToolUse` `tool_name` + `tool_input` | `Stop` `last_assistant_message`; none for a turn that ends on an error (no `Stop`) |
| Copilot | `userPromptSubmitted` `prompt` | `postToolUse` `toolName` + `toolArgs` (a JSON string) | unrecoverable `errorOccurred` `error.message` |
| Pi | `session_info_changed` / `session_start` name, else `message_start` (the person's message) | `tool_execution_end` + its call's argument from `tool_execution_start` (failed, duration); `tool_execution_start` is what runs now | `agent_settled` with `agent_end`'s last assistant words; its `errorMessage`; none when aborted |
| OpenCode | `session.updated` / 2.x `session.renamed` title, else the user message's text (1.x) / `session.inbox.enqueued` (2.x) | 1.x tool part `completed` / `error` + one input argument; 2.x `session.tool.success` / `failed` (+ the call's name and argument); the tool's start is what runs now | `session.error` / `session.execution.failed` message |
| Cursor | — (`beforeSubmitPrompt` can stop a prompt: not installed) | `afterShellExecution` command, `afterFileEdit` path, `afterMCPExecution` server · tool | `afterAgentResponse` `text`; no error text |

## The manifest

`docs/vendor-formats.json` has one entry per adapter, and each entry holds
only a `hooks` block:

| `source` | Meaning | Required fields |
| --- | --- | --- |
| `repo` | Open source; the receiver follows this commit | `repo`, `commit` (40 hex), `watch` (vendor files that define the hooks), `checked`, `events`, `tests` — or, for an adapter that supports several release lines at once (OpenCode 1.x and 2.x), `pins` in place of `commit` / `watch`: each with its `line`, the `branch` it is released from, the `tag` read, its `commit` and `watch` |
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
own "replied" / "prompt closed"), and Claude, Codex, Copilot, Pi, OpenCode
and Cursor install their per-tool event (`PostToolUse`, `postToolUse`,
`tool_execution_end`, `message.part.updated` and `session.tool.success`,
`afterShellExecution`) — the answer to a permission, and the only silence
that means a stall
(`HookContract.reportsToolActivity`). Each was checked non-blocking at exit 0
with empty output against the pinned source. Claude also installs
`PostToolUseFailure` (its output cannot change the outcome) and, async,
`PermissionDenied` (its `retry` is a decision output, never read from an
async hook — "async neutralizes decision output", above).
**Changing a hook contract means updating its block and its test in the same
change.**

## The sentinel

`.github/workflows/vendor-drift.yml` runs `scripts/vendor_drift.py` weekly
(and on demand). For every `repo` hooks block it makes a blob-less clone and
lists commits since the pin that touched a `watch` path — on the default
branch, or, for each of a block's `pins`, on the branch that line is
released from (OpenCode 1.x on `v1`, 2.x on `dev`). Any such commit
turns the run red and names the vendor, file and commits. It only reads
public repositories and prints; it writes nothing.

A red run is a prompt to read, not proof of breakage: read the commits, fix
the receiver and its test if the contract moved, then move the pin
(`commit`, `checked`) — the same change, so the gate and the sentinel agree.
