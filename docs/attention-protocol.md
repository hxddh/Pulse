# Attention Protocol v4

The contract between each supported agent's hook and Pulse's lamp (24.0).

**Audience:** anyone touching `PulseHookReceiver`, the installer, or a script
that writes `attention.tsv`.
**Runtime path:** `~/Library/Application Support/Pulse/attention.tsv`
**Writers:** `pulse-hook <agent> <event>` → `PulseBar --hook` (native), or a
line appended by hand.
**Swift source of truth:** `AttentionProtocol` / `AttentionRecord` (PulseCore),
`PulseHookReceiver` (the per-agent adapters), `HookContract` in
`AgentCatalog.swift` (what is installed).

Companion:

- Product policy → [`attention-bridge.md`](attention-bridge.md)
- Where each vendor's hook contract was read → [`vendor-formats.json`](vendor-formats.json) (`hooks` block per agent)
- Samples → [`samples/attention-bridge/`](samples/attention-bridge/)

## Wire format

UTF-8 TSV, one event per line. Header first:

```text
# pulse-attention v4 (agent\tkind\tms\tmessage\tsession\tcwd\tfront\tpid\ttranscript\tlanding)
<agent>\t<kind>\t<unix_ms>\t<message>\t<session>\t<cwd>\t<front>\t<pid>\t<transcript>\t<landing>
```

**Every line has all ten columns.** A v3 (eight-column) line is not read — no
compatibility. Leave a column empty when you have nothing for it; the trailing
tabs are part of the record.

| Column | Rules |
| --- | --- |
| `agent` | One of the seven `AgentID` raw values: `claude`, `codex`, `cursor`, `pi`, `gemini`, `copilot`, `opencode` (`cursor-agent` / `cursor_agent` read as `cursor`) |
| `kind` | An allowlisted kind (below) |
| `unix_ms` | Integer milliseconds since epoch |
| `message` | What is asked, or the turn's last words; tab/newline stripped; ≤200 chars; credentials redacted |
| `session` | The vendor's session id; empty allowed |
| `cwd` | Absolute project path; empty allowed |
| `front` | `1` when the prompt's own window was frontmost as the event was raised, `0` when not, empty when unknown. Only written for open kinds |
| `pid` | The agent process the hook ran under: the first ancestor of the hook whose argv matches the agent's catalog process rule, else the hook's direct parent. Empty/0 unknown |
| `transcript` | The vendor's transcript path when its hook names one |
| `landing` | Where the session can be reached, most specific first, `;`-separated: `tmux:%3`, `tmuxsock:<TMUX socket path>`, `iterm:<ITERM_SESSION_ID>`, `tty:/dev/ttys004`, `term:<TERM_PROGRAM>`, `app:<__CFBundleIdentifier>`; unknown keys are ignored (`docs/landing-hosts.md`) |

Readers skip blank lines, `#` comments, and unknown kinds. Writers rewrite the
header when compacting the file (keep the last 80 data lines, and every open
one).

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
| | `working` | The user submitted a prompt |
| | `end` | The session ended |

`start`, `working` and `end` clear the session's entry exactly like `done`.
Tool activity (a tool ran, a reply streamed) is **not** an attention line: it
goes to the per-session activity spool (`activity.d/`), which keeps a working
session from reading stalled and ends a hook wait stamped before it.

Anything else — including an empty kind — is **rejected** by `pulse-hook`
(exit 0, no write) and **ignored** by `AttentionReader`. A blocked kind for an
agent whose hooks cannot report a block (`waiting: .none` — Codex, Cursor) is
also rejected. That is the No fake Waiting gate for this channel.

Bridge words normalized before the allowlist check
(`AttentionProtocol.normalizeKind`): `permission_prompt`, `approval_request`
→ `permission`; `elicitation_dialog`, `elicitation_url_dialog`,
`agent_needs_input` → `question`; `stop`, `agent-turn-complete`,
`turn_complete`, `task_complete`, `stop_failure` → `turn`; `idle`,
`idle_prompt` → `idle`; `elicitation_complete`, `elicitation_response` → `done`;
`session_start` → `start`; `prompt` → `working`; `session_end` → `end`.
There is no free-text guessing: a word containing "approval" is not a
permission.

## Per-agent mapping (what `pulse-hook <agent> <event>` writes)

Every installed command is `pulse-hook <agent> <vendor event name>`; the
payload is the vendor's JSON on stdin (Codex `notify`: the last argument). Only
observe-only events are installed; `HookContract.gatingEvents` lists the ones
that never are.

| Agent | Vendor event | Pulse |
| --- | --- | --- |
| **Claude** (`~/.claude/settings.json`, every entry `async: true`) | `SessionStart` | `start` |
| | `UserPromptSubmit` | `working` (+ spool) |
| | `PostToolUse` | activity (spool only) |
| | `PermissionRequest` | `permission` — ask = `tool_name: command/file_path/url`; `AskUserQuestion` → `question` |
| | `Notification` `permission_prompt` | `permission` |
| | `Notification` `elicitation_dialog` / `elicitation_url_dialog` / `agent_needs_input` | `question` |
| | `Notification` `idle_prompt` | `idle` |
| | `Notification` `elicitation_complete` / `elicitation_response` | `done` |
| | `Stop`, `StopFailure` | `turn` (message = `last_assistant_message`) |
| | `SessionEnd` | `end` |
| **Codex** (`~/.codex/hooks.json` + `notify`) — never blocked | `SessionStart` / `UserPromptSubmit` / `Stop` / `SessionEnd` | `start` / `working` / `turn` / `end` |
| | `PostToolUse` (async) | activity (spool only; the stall rule's evidence) |
| | `notify` `agent-turn-complete` | `turn` (session = `thread-id`) |
| | `PermissionRequest` | never installed; ignored if seen (fires before Codex's own auto-review) |
| **Gemini CLI** (`~/.gemini/settings.json` `hooks`) | `SessionStart` / `SessionEnd` | `start` / `end` |
| | `BeforeAgent` | `working` (exit 0, no output: never blocks) |
| | `AfterTool` | activity (the tool ran: answers a `ToolPermission`) |
| | `AfterAgent` | `turn` |
| | `Notification` `notification_type: ToolPermission` | `permission` (ask = `message`) |
| **Copilot CLI** (`~/.copilot/hooks/pulse.json`) | `sessionStart` / `sessionEnd` | `start` / `end` |
| | `userPromptSubmitted` | `working` |
| | `postToolUse` / `postToolUseFailure` | activity (the tool ran: answers a `permission_prompt`) |
| | `agentStop` | `turn` |
| | `notification` `permission_prompt` / `elicitation_dialog` | `permission` / `question` |
| | `notification` `agent_idle` / `agent_completed` / `shell_completed` | ignored (background subagents and shells, not the session's turn) |
| | `errorOccurred` | `turn` when `recoverable: false`, else activity |
| **OpenCode** (plugin `~/.config/opencode/plugins/pulse.js`; payload as the last argument; a subagent's child session is dropped, its asks sent under the root session) | `session.created` | `start` |
| | `session.status` `busy` / `retry` | activity |
| | `permission.asked` | `permission` (ask = `permission: patterns`) |
| | `question.asked` | `question` (ask = first question) |
| | `permission.replied` / `question.replied` / `question.rejected` | `done` |
| | `session.idle`, `session.error` | `turn` |
| | `session.deleted` | `end` |
| **Cursor** (`~/.cursor/hooks.json`) — never blocked | `sessionStart` / `sessionEnd` | `start` / `end` |
| | `afterAgentResponse` | activity |
| | `stop` | `turn` (session = `conversation_id`, cwd = `workspace_roots[0]`) |
| **Pi** (extension `~/.pi/agent/extensions/pulse.js`; payload as the last argument) | `session_start` / `session_shutdown` (not on `reload`) | `start` / `end` |
| | `agent_start` | `working` |
| | `tool_execution_end` | activity |
| | `ui_prompt_start` `kind: confirm` / other kinds | `permission` / `question` (ask = `title`) |
| | `ui_prompt_end` | `done` |
| | `agent_settled` | `turn` |

## Reader rules

- Same `(agent, session)` — last write wins.
- A blocked line for an agent with `waiting: .none` (Codex, Cursor) is
  ignored, whoever wrote it.
- `done`, `start`, `working`, `end` clear that session (`session` empty →
  only the agent's session-less entry).
- A blocked entry that names no session never attaches to a session row; it
  is its own row in its folder.
- A blocked entry goes out when that session's own activity event, stamped
  after the raise, arrives: the ask was answered in the vendor's prompt. When
  the raise names its tool (`Bash: npm test`) and the activity names one, only
  the same tool answers it — a parallel tool finishing does not.
- A re-raise of the same kind within **20 s** is the same block (Claude's
  `PermissionRequest`, then its `Notification`): it keeps the first ask and
  clock.
- `turn` clears a blocked wait. Within **20 s** of the raise it is **held**,
  not dropped (the order of a vendor's events is not ours): it lands when the
  grace ends — on the next event or the tick — or at once when an answer
  stamped before it arrives. So a denied prompt (no tool runs, the turn ends
  seconds later) goes out within the grace. A session-less `turn` only
  clears. A `turn` never creates a row of its own. A `turn` with `front` = `1`
  only clears — the user watched it finish.
- A `done` stamped before the current block or turn began is about an
  earlier one and changes nothing.
- A blocked line with `front` = `1` lights the lamp but raises no banner.
- Entries older than **30 minutes** expire.

## Raise by hand

```bash
HOOK="$HOME/Library/Application Support/Pulse/pulse-hook"
echo '{"message":"Approve deploy?","session_id":"sess-1","cwd":"'"$PWD"'"}' | "$HOOK" gemini permission
echo '{"session_id":"sess-1"}' | "$HOOK" gemini done
```

## Versioning

- v1–v3: see git history. v3 (16.0) split blocked / your turn / resolved.
- **v4 (24.0)**: drops the ignored `host` column; adds `pid`, `transcript`,
  `landing`; adds `start` / `working` / `end`; removes the free-text approval
  and user-input heuristics. v3 lines are not read.
