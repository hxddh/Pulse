# Attention Protocol v5

The contract between each supported agent's hook and Pulse's lamp: one
append-only event log.

**Audience:** anyone touching `PulseHookReceiver`, `EventLog`, the installer,
or a script that writes the event log.
**Runtime path:** `~/Library/Application Support/Pulse/events.tsv`
(`PULSE_HOME` moves it). One file; nothing else is read.
**Writers:** `pulse-hook <agent> <event>` → `PulseBar --hook` (native), the
app's own `done` for a dismissal, or a line appended by an integrator.
**Swift source of truth:** `AttentionProtocol` / `AttentionRecord` (PulseCore),
`EventLog` (PulseHarvest: append, read from a cursor, compact),
`PulseHookReceiver` (the per-agent adapters), `HookContract` in
`AgentCatalog.swift` (what is installed).

Companion:

- Product policy → [`attention-bridge.md`](attention-bridge.md)
- Where each vendor's hook contract was read → [`vendor-formats.json`](vendor-formats.json) (`hooks` block per agent)
- Samples → [`samples/attention-bridge/`](samples/attention-bridge/)

## The file

UTF-8 TSV, one event per line, in the order the hooks wrote them. The first
line is a header naming the protocol and the file's **generation**:

```text
# pulse-events v5 <generation> (agent\tkind\tms\tmessage\tsession\tcwd\tfront\tpid\t-\tlanding\ttool)
<agent>\t<kind>\t<unix_ms>\t<message>\t<session>\t<cwd>\t<front>\t<pid>\t\t<landing>\t<tool>
```

- **Append only.** A writer opens the file `O_APPEND`, takes an exclusive
  `flock`, and writes one whole line. A file that does not exist (or is
  empty) gets a header with a new generation first. A file whose last byte
  is not a line break (a writer died mid-line) gets one before the new line.
  Mode 0600.
- **Bounded.** An append that would take the file past 1 MiB compacts it
  first, under the same lock, and writes a **new generation** header: per
  session (`agent|session`, or `agent|hook:<folder>` for a session-less one —
  never the agent alone; a session-less `done` belongs to the group of the
  folder it names, or — naming none — to every session-less group of its
  agent), the last 64 lines and every line of the last two hours are kept; a
  session whose newest line is a day old goes whole; whatever the budget,
  each session keeps what a replay rebuilds its own facts from — its first
  line that is not a block (its first clock), the prompt its title came from
  (the first `working` line that says something) and its latest prompt (the
  turn's clock); and an **open block** (a `permission` / `question` /
  `waiting` no later line in its session answers; a `status` line answers
  nothing) is kept with every line after it. An answered block is never kept
  without its answer. Over half a MiB the
  per-session count and the window halve until it fits. The line being
  appended is always kept: an append reports success only when its line is
  in the file.
- **Read from an offset.** A reader keeps a cursor (the header line and the
  byte after the last complete line it applied) and reads only what follows,
  under a shared lock, complete lines only. Lines end at `\n` bytes alone: a
  U+2028, NEL or lone `\r` inside a field never splits a record. A cursor
  from another generation, or past the end of the file, reads the whole file
  again; the lines already applied are matched to it **by position**, never
  by text alone. A rewrite keeps lines in order, and what was not applied
  (the line being appended, anything written since, anything the reader had
  not reached) comes after what was: the last line applied is the anchor —
  its copy is the last one whose earlier lines all fit, in order, among the
  lines applied before it — and every line after it is new, even one whose
  text matches a line applied earlier. When the rewrite kept no copy of it,
  each line takes the next applied line with the same text, and a line with
  no match left is new (the same text written twice is applied twice). A
  line is applied once: a read that began before the reader's cursor moved
  (another read landed first) applies only the lines past the cursor, and
  one from a generation the reader has left applies nothing. A missing file is an empty log; an
  unreadable one is a failed read: the reader keeps what it had and retries
  once, backing off from 5 s to a minute.
- **Replayed at launch.** The app reads the whole log and applies every line,
  in order, before its first projection. That projection is the banner
  baseline: a block already in the log gets no banner. Only that one is: a
  launch read that failed leaves the baseline to the replay that lands, and
  every projection after it can notify. Everything the app shows about a
  session — its steps, its title, its turn's clock — is rebuilt by this
  replay and kept nowhere else.
- A v4 `attention.tsv` and the `activity.d/` spool are deleted at launch,
  never read.

**Every line has all eleven columns.** A v4 (ten-column) or older line is not
read — no compatibility. Leave a column empty when you have nothing for it;
the trailing tabs are part of the record.

| Column | Rules |
| --- | --- |
| `agent` | One of the seven `AgentID` raw values: `claude`, `codex`, `cursor`, `pi`, `gemini`, `copilot`, `opencode` (`cursor-agent` / `cursor_agent` read as `cursor`) |
| `kind` | An allowlisted kind (below) |
| `unix_ms` | Integer milliseconds since epoch, stamped by the writer |
| `message` | What is asked, the turn's last words (or its error, when `tool` is `error`), the prompt's text on a `working` line, or a tool line's target; tabs and every kind of line break (`\n`, `\r`, VT, FF, NEL, U+2028, U+2029) made spaces; ≤200 chars; credentials redacted from the whole value before it is shortened |
| `session` | The vendor's session id; empty allowed (not for `tool` and `working`) |
| `cwd` | Absolute project path; empty allowed |
| `front` | `1` when the prompt's own window was frontmost as the event was raised, `0` when not, empty when unknown. Only written for blocked kinds, `turn` and `idle` |
| `pid` | The agent process the hook ran under: the first ancestor of the hook whose argv matches the agent's catalog process rule. Never the hook's direct parent (usually a `sh -c` that exits with the hook) and never `1` — empty when unknown |
| (reserved) | Written empty, never read. It once named a transcript file; Pulse reads no vendor file |
| `landing` | Where the session can be reached, most specific first, `;`-separated: `tmux:%3`, `tmuxsock:<TMUX socket path>`, `iterm:<ITERM_SESSION_ID>`, `tty:/dev/ttys004`, `term:<TERM_PROGRAM>`, `app:<__CFBundleIdentifier>`; unknown keys are ignored (`docs/landing-hosts.md`) |
| `tool` | The tool a `tool` line ran, or the tool a block is about (`Bash`, `AskUserQuestion`); on a `turn` line, `error` when the turn ended on an error; on a `tool` line, `status` when the event says only that work goes on (a status, a retry, a recoverable error) — never a step, never an answer; empty when the event names none |

Readers skip blank lines, `#` comments, and unknown kinds.

## Kinds

| Group | Kind | Meaning |
| --- | --- | --- |
| Blocked (red) | `permission` | A tool / filesystem / network approval is showing |
| | `question` | A clarifying question or requested input is showing |
| | `waiting` | Blocked, reason unknown |
| Your turn (quiet, never red) | `turn` | The turn ended; the agent is idle at its prompt |
| | `idle` | It has sat at its prompt a while (Claude's `idle_prompt`, ~60 s after a turn): your turn only if the session was still working or blocked (an Esc on a prompt fires no Stop) or is new to Pulse — never revives a turn already seen |
| Resolved | `done` | Nothing is owed any more |
| Lifecycle | `start` | The session started or resumed |
| | `working` | The user submitted a prompt (message = its text: the title's source) |
| | `end` | The session ended |
| Activity | `tool` | A tool ran (or a reply streamed): the session is working, and — when it names its tool — its last step. Never a wait. With tool = `status`: work goes on, no tool ran — not a step, and it answers no block |

`working` and `end` clear the session's block like `done`; `start` does
unless the session is working. A `tool` line keeps a working session from
reading stalled and answers a block raised before it in the same session —
unless both name a tool and the names differ (a parallel tool is not the
answer), or it is a `status` line.

Anything else — including an empty kind — is **rejected** by `pulse-hook`
(exit 0, no write) and **ignored** by the reader. A blocked kind for an agent
whose hooks cannot report a block (`waiting: .none` — Codex, Cursor) is also
rejected. That is the No fake Waiting gate for this channel.

Bridge words normalized before the allowlist check
(`AttentionProtocol.normalizeKind`): `permission_prompt`, `approval_request`
→ `permission`; `elicitation_dialog`, `elicitation_url_dialog`,
`agent_needs_input` → `question`; `stop`, `agent-turn-complete`,
`turn_complete`, `task_complete`, `stop_failure` → `turn`; `idle`,
`idle_prompt` → `idle`; `elicitation_complete`, `elicitation_response` → `done`;
`session_start` → `start`; `prompt` → `working`; `session_end` → `end`;
`activity` → `tool`. There is no free-text guessing: a word containing
"approval" is not a permission.

## Per-agent mapping (what `pulse-hook <agent> <event>` writes)

Every installed command is `pulse-hook <agent> <vendor event name>`; the
payload is the vendor's JSON on stdin (the two modules: the last argument).
A payload that does not parse as JSON — cut off at the 1 MiB stdin bound,
or broken — writes nothing; plain text on stdin is read only for a protocol
word (below), as its message, never for a vendor's event.
Only observe-only events are installed; `HookContract.gatingEvents` lists the
ones that never are, and an event Pulse does not install is not read.

| Agent | Vendor event | Pulse |
| --- | --- | --- |
| **Claude** (`~/.claude/settings.json`, every entry `async: true`) | `SessionStart` | `start` |
| | `UserPromptSubmit` | `working` (message = `prompt`) |
| | `PostToolUse`, `PostToolUseFailure` | `tool` (tool = `tool_name`, message = its target) |
| | `PermissionRequest` | `permission` — ask = `tool_name: command/file_path/url`, tool = `tool_name`; `AskUserQuestion` → `question`, ask = `tool_input.questions[0].question`; `ExitPlanMode` → ask = the plan's first line |
| | `Notification` `permission_prompt` | `permission` |
| | `Notification` `elicitation_dialog` / `elicitation_url_dialog` / `agent_needs_input` | `question` |
| | `Notification` `idle_prompt` | `idle` |
| | `Notification` `elicitation_complete` / `elicitation_response` | `done` |
| | `Stop` | `turn` (message = `last_assistant_message`) |
| | `StopFailure` | `turn`, tool = `error` (message = `last_assistant_message`, else `error_details`, else `error`) |
| | `SessionEnd` | `end` |
| **Codex** (`~/.codex/hooks.json` only; `config.toml` is never touched) — never blocked | `SessionStart` / `UserPromptSubmit` / `Stop` / `SessionEnd` | `start` / `working` (message = `prompt`) / `turn` (message = `last_assistant_message`) / `end` |
| | `PostToolUse` (async) | `tool` (the stall rule's evidence; tool = `tool_name`, message = its target) |
| | `PermissionRequest` | never installed, not read (fires before Codex's own auto-review) |
| **Gemini CLI** (`~/.gemini/settings.json` `hooks`) | `SessionStart` / `SessionEnd` | `start` / `end` |
| | `BeforeAgent` | `working` (message = `prompt`; exit 0, no output: never blocks) |
| | `AfterTool` | `tool` (the tool ran: answers a `ToolPermission`) |
| | `AfterAgent` | `turn` (message = `prompt_response`) |
| | `Notification` `notification_type: ToolPermission` | `permission` (ask = `message`) |
| **Copilot CLI** (`~/.copilot/hooks/pulse.json`) | `sessionStart` / `sessionEnd` | `start` / `end` |
| | `userPromptSubmitted` | `working` (message = `prompt`) |
| | `postToolUse` / `postToolUseFailure` | `tool` (the tool ran: answers a `permission_prompt`; tool = `toolName`, message = the command or path in `toolArgs`, a JSON string) |
| | `agentStop` | `turn` |
| | `notification` `permission_prompt` / `elicitation_dialog` | `permission` / `question` |
| | `notification` `agent_idle` / `agent_completed` / `shell_completed` | ignored (background subagents and shells, not the session's turn) |
| | `errorOccurred` | `turn`, tool = `error`, message = `error.message` when `recoverable: false`; else `tool`, tool = `status` |
| **OpenCode** (plugin `~/.config/opencode/plugins/pulse.js`; payload as the last argument; a subagent's child session is dropped, its asks sent under the root session) | `session.created` | `start` |
| | `session.status` `busy` / `retry` | `tool`, tool = `status` |
| | `permission.asked` | `permission` (ask = `permission: patterns`) |
| | `question.asked` | `question` (ask = first question) |
| | `permission.replied` / `question.replied` / `question.rejected` | `done` |
| | `session.idle` | `turn` |
| | `session.error` | `turn`, tool = `error` (message = the error's message, forwarded by the plugin) |
| | `session.deleted` | `end` |
| **Cursor** (`~/.cursor/hooks.json`) — never blocked | `sessionStart` / `sessionEnd` | `start` / `end` |
| | `afterAgentResponse` | `tool` (no tool name) |
| | `stop` | `turn` (session = `conversation_id`, cwd = `workspace_roots[0]`) |
| **Pi** (extension `~/.pi/agent/extensions/pulse.js`; payload as the last argument) | `session_start` / `session_shutdown` (not on `reload`) | `start` / `end` |
| | `agent_start` | `working` |
| | `tool_execution_end` | `tool` (tool = the tool's name, message = one argument, forwarded by the extension — sliced at 2000 characters only to bound the argv; the receiver redacts the whole value before it shortens it) |
| | `ui_prompt_start` `kind: confirm` / other kinds | `permission` / `question` (ask = `title`; never the event's `reason` — the extension sends a reason only with `session_shutdown`) |
| | `ui_prompt_end` | `done` |
| | `agent_settled` | `turn` |

## Reader rules

- Every line applies, in file order, to its session (`agent|session`, or
  `agent|hook:<folder>` when it names none).
- A blocked line for an agent with `waiting: .none` (Codex, Cursor) is
  ignored, whoever wrote it.
- `done`, `working`, `end` clear that session (`session` empty → only the
  agent's session-less entry in the folder it names, or every session-less
  one when it names none; a dismissal always names the folder).
- A `tool` line that names its tool is a step: the session keeps its last
  five (tool, target, time); a `status` line is not a step. A `working`
  line starts a new turn (its clock), its text is the latest prompt, and the
  first that says something (not "continue") is the title. A `turn` line's
  message is the last words — or, with tool = `error`, the turn's error,
  until the next turn starts: a prompt, or a `tool` line after the turn
  ended (OpenCode's plugin sends no prompt).
- A blocked entry that names no session never attaches to a session row; it
  is its own row in its folder.
- A blocked entry goes out when a `tool` line (or a prompt) of that session,
  stamped after the raise, arrives: the ask was answered in the vendor's
  prompt. When the block names its tool (the `tool` column, else the
  `Tool: target` ask) and the tool line names one, only the same tool
  answers it — a parallel tool finishing does not. A `status` line never
  answers it.
- A re-raise of the same kind within **20 s** is the same block (Claude's
  `PermissionRequest`, then its `Notification`): it keeps the first clock and
  the more specific ask — a command, a path or a question beats a bare tool
  name or a vendor's generic "needs your permission"; on a tie the first.
- `turn` clears a blocked wait. Within **20 s** of the raise it is **held**,
  not dropped (the order of a vendor's events is not ours): it lands when the
  grace ends — on the next event or the tick — or at once when an answer
  stamped before it arrives. So a denied prompt (no tool runs, the turn ends
  seconds later) goes out within the grace. A session-less `turn` only
  clears. A `turn` never creates a row of its own. A `turn` with `front` = `1`
  only clears — the user watched it finish.
- A `done` stamped before the current block or turn began is about an
  earlier one and changes nothing.
- A block a `done` cleared (a dismissal in Pulse, a vendor's "resolved") is
  not raised again by its echo: a raise of the same kind within **20 s** of
  the cleared block's raise, with no prompt or tool line since the `done`,
  whose words say nothing new (the same ask, or only a generic "needs your
  permission") is ignored — Claude's `Notification` after a dismissed
  `PermissionRequest` does not turn the lamp red or post a banner again.
- A blocked line with `front` = `1` lights the lamp but raises no banner.
- A session whose recorded pid is dead — or now runs another agent, or
  started after the first line that named it (a reused pid) — has ended.

## Raise by hand

```bash
HOOK="$HOME/Library/Application Support/Pulse/pulse-hook"
echo '{"message":"Approve deploy?","session_id":"sess-1","cwd":"'"$PWD"'"}' | "$HOOK" gemini permission
echo '{"session_id":"sess-1"}' | "$HOOK" gemini done
```

## Versioning

- v1–v4: see git history. v3 split blocked / your turn / resolved; v4 added
  `pid`, a transcript column, `landing` and the lifecycle kinds.
- **v5**: one append-only event log (`events.tsv`) replaces `attention.tsv`
  and the per-session activity spool; a generation in the header; an
  eleventh column, `tool`; a `tool` kind for activity. v4 lines are not read
  and the v4 files are deleted at launch. The ninth column is reserved —
  written empty, never read — so a live log keeps its format (no new
  protocol version, no log deleted); `tool` = `error` on a `turn` line marks
  a failed turn, and `tool` = `status` on a `tool` line marks work that is
  not a tool (a reader that does not know it reads a tool named `status`).
