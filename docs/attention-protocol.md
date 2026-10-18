# Attention Protocol v8

The contract between each supported agent's hook and Pulse's lamp: one
append-only event log of numbered lines.

**Audience:** anyone touching `PulseHookReceiver`, `EventLog` or the
installer.
**Runtime path:** `~/Library/Application Support/Pulse/events.tsv`
(`PULSE_HOME` moves it). One file; nothing else is read.
**Writers:** `pulse-hook <agent> <event>` (the app's native `--hook`), and
the app's own `dismiss` (a wait set aside in Pulse, or a finished turn
looked at). Both go through `EventLog.append`. Nothing else writes it.
**Swift source of truth** (all in `PulseKit`): `AttentionKind` /
`AttentionRecord` / `AttentionProtocol` (`AttentionProtocol.swift`),
`EventLog` (append, read from a cursor, compact), `PulseHookReceiver`
(reads through each agent's adapter), and the adapters in `Agents/` — one
file per agent, whose `HookContract` is what is installed and what each
event means.

What is installed, how it is removed, and what each vendor event becomes:
[`vendor-formats.md`](vendor-formats.md).

## The file

UTF-8 TSV, one event per line, numbered in the order the append lock was
granted. The first line is the header:

```text
# pulse-events v8 next=<seq> gen=<gen> (seq\tms\tagent\tkind\tevent\tsession\tsub\tcwd\tpid\tfront\tlanding\ttool\terr\ttook\tmessage)
<seq>\t<unix_ms>\t<agent>\t<kind>\t<event>\t<session>\t<sub>\t<cwd>\t<pid>\t<front>\t<landing>\t<tool>\t<err>\t<took>\t<message>
```

- **`gen`** names the log. It is chosen when the log is started — the file
  is created, or a file that is not a v8 log is started over — and every
  compaction keeps it. A reader that finds another `gen` is reading another
  log.
- **`next`** is the `seq` the next line gets when no line in the file has a
  larger one: 1 for an empty log, one past the newest kept line after a
  compaction.
- **Only a v8 log is read.** A file whose first line is not a v8 header (a
  v7 log or any older protocol, or no header) is treated as absent: a read
  finds it empty, and the next writer — the app's `ensureExists` at launch,
  or a hook's append — empties it under its lock and starts a fresh v8 log
  (a new `gen`, numbering from 1). It is never read and never migrated.
- **Append only, numbered under the lock.** A writer opens the file
  `O_APPEND`, takes an exclusive `flock`, gives the line the next `seq` —
  one past the last line's (read from the file's tail), never less than the
  header's `next` — and writes one whole line. A file that does not exist
  (or is empty) gets a header first. A file whose last byte is not a line
  break (a writer died mid-line) gets one before the new line. Mode 0600.
- **Bounded.** An append that would take the file past 1 MiB compacts it
  first, under the same lock, and rewrites it under a header with the same
  `gen` and a new `next`; **every kept line keeps its `seq`**. Per session
  (`SessionKey`: agent + session id, or agent + folder for a session-less
  one — never the agent alone; a session-less `done` / `dismiss` belongs to
  the group of the folder it names, or — naming none — to every session-less
  group of its agent before it), the last 64 lines and every line of the
  last two hours are kept; a session whose newest line is a day old goes
  whole. The lines are replayed through the reader itself (`SessionBook`),
  so its own rules decide the rest: whatever the budget, each session keeps
  the lines a replay rebuilds its own facts from (`SessionBook.Anchors`: its
  first line that raises nothing — its first clock — the prompt its title
  came from, the line that started its turn, its latest prompt that says
  something and the line its vendor name came from) and, while the replay
  holds it blocked, the raise that turned it red with every line after it.
  An answered block is never kept without its answer. Over half a MiB
  the per-session count and the window halve until it fits. The line being
  appended is always kept: an append reports success only when its line is
  in the file. `ignored` lines are bounded like any other.
- **Read from an offset; applied by number.** A reader keeps a cursor: the
  header line it read, the byte after the last complete line it read, the
  log's `gen` and the last `seq` it applied. It reads only what follows the
  offset, under a shared lock, complete lines only. Lines end at `\n` bytes
  alone: a U+2028, NEL or lone `\r` inside a field never splits a record. A
  cursor whose header is not the file's (a compaction rewrote it, or the log
  was started over), or one past the end of the file, reads the whole file
  again. Either way the reader applies **only the lines whose `seq` is past
  the last it applied** — of the same `gen`; of another `gen`, every line
  (the log was started over, its numbering began again). Identity is the
  number, never the text: a kept line is never applied twice, and the same
  text written twice is two lines. A missing file is an empty log; an
  unreadable one is a failed read: the reader keeps what it had and
  retries once, backing off from 5 s to a minute. A read that found no log
  moves nothing.
- **Replayed at launch.** The app reads the whole log and applies every line,
  in order, before its first projection. That projection is the banner
  baseline: a block already in the log gets no banner. Only that one is: a
  launch read that failed leaves the baseline to the replay that lands, and
  every projection after it can notify. Everything the app shows about a
  session — its steps, its title, its turn's clock — is rebuilt by this
  replay and kept nowhere else.

**Every line has exactly fifteen columns**, in the order above, and a `seq`
that is a positive integer. A line with any other count, another `seq`, an
agent or a kind the protocol does not know, is not read. Leave a column
empty when you have nothing for it; the trailing tabs are part of the
record.

| Column | Rules |
| --- | --- |
| `seq` | Positive integer, assigned by the appender under the lock: one past the last line's |
| `ms` | Integer milliseconds since epoch, stamped by the writer |
| `agent` | One of the six `AgentID` raw values: `claude`, `codex`, `cursor`, `pi`, `copilot`, `opencode` (`cursor-agent` / `cursor_agent` read as `cursor`) |
| `kind` | One of the kinds below, spelled exactly as listed |
| `event` | The vendor's own name of the hook event that wrote the line (`PermissionRequest`, `tool_execution_end`, `session.status`); `pulse.dismiss` / `pulse.seen` for the app's own `dismiss`. ≤64 chars. Read by nobody's state — it says where a line came from: the why, the detail page's timeline, Settings' "heard" and the report cite it (only when it is a name: letters, digits, `_ . : -`) |
| `session` | The vendor's session id; empty allowed (not for `tool`, `status`, `working`, `title`) |
| `sub` | The vendor's id of the subagent (child agent) the event came from — Claude's and Codex's `agent_id`, Copilot's `agentId` (each adapter's `subagentKeys`); empty for the main agent. A subagent's line belongs to its session, but it is not the person: see the reader rules |
| `cwd` | Absolute project path; empty allowed |
| `pid` | The agent process the hook ran under: the first ancestor of the hook whose argv matches the agent's catalog process rule. Never the hook's direct parent (usually a `sh -c` that exits with the hook) and never `1` — empty when unknown. The one exception is a module that spawns the hook itself and says its own pid (Pi's extension sends `process.pid`, `AgentSpec.reportsOwnPID`): that pid is taken only when it is the hook's own parent |
| `front` | `1` when the prompt's own window was frontmost as the event was raised, `0` when not, empty when unknown. Only written for blocked kinds, `turn`, `failed` and `idle` |
| `landing` | Where the session can be reached, most specific first, `;`-separated: `tmux:%3`, `tmuxsock:<TMUX socket path>`, `iterm:<ITERM_SESSION_ID>`, `tty:/dev/ttys004`, `term:<TERM_PROGRAM>`, `app:<__CFBundleIdentifier>`; unknown keys are ignored (`architecture.md`, "Landing") |
| `tool` | The tool a `tool` line ran, the tool a `status` line says has started (Pi's `tool_execution_start`), or the tool a block is about (`Bash`, `AskUserQuestion`); empty when the event names none. A tool name only — no column but `kind` says what a line means |
| `err` | `1` when the tool a `tool` line reports failed (Claude's `PostToolUseFailure`, Copilot's `postToolUseFailure`, Pi's `isError`); empty otherwise. Anything but `1` is not a failure |
| `took` | How long the tool a `tool` line reports ran, in integer milliseconds, when the vendor said (Pi's `durationMs`); empty when unknown. Anything but a positive integer is unknown |
| `message` | What is asked, the turn's last words, a `failed` turn's error, the prompt's text on a `working` line, a tool or `status` line's target, the reply's words on a `tool` line that names no tool (Cursor's `afterAgentResponse`: the turn's last words so far), the vendor's name for the session on a `title` line (or a `start`, when the session already has one), or why a line was `ignored`; tabs and every kind of line break (`\n`, `\r`, VT, FF, NEL, U+2028, U+2029) made spaces; ≤200 chars; credentials redacted from the whole value before it is shortened. Last, so free text never shifts a column |

Readers skip blank lines and `#` comments.

## Kinds

| Group | Kind | Meaning |
| --- | --- | --- |
| Blocked (red) | `permission` | A tool / filesystem / network approval is showing |
| | `question` | A clarifying question or requested input is showing |
| | `waiting` | Blocked, reason unknown |
| Your turn (quiet, never red) | `turn` | The turn ended; the agent is idle at its prompt (message = its last words) |
| | `failed` | The turn ended on an error (message = the error): your turn, and the session's last error until the next turn starts |
| | `idle` | It has sat at its prompt a while (Claude's `idle_prompt`, ~60 s after a turn): your turn only if the session was still working or blocked (an Esc on a prompt fires no Stop) or is new to Pulse — never revives a turn already seen |
| Resolved | `done` | The vendor said its prompt closed (OpenCode `permission.replied`, Pi `ui_prompt_end`, Claude `elicitation_complete`): nothing is owed |
| | `dismiss` | Pulse's own: the person set the wait aside (`pulse.dismiss`) or looked at a finished turn (`pulse.seen`). Written by the app alone |
| Lifecycle | `start` | The session started or resumed (message = the vendor's name for it, when it has one — or the prompt a one-shot run was started with, Copilot's `initialPrompt`) |
| | `working` | The user submitted a prompt (message = its text: the title's source) |
| | `stopped` | The person stopped the run at the agent's own prompt (Pi's aborted `agent_settled`, Codex's `Interrupt`, Claude's `PostToolUseFailure` with `is_interrupt`, OpenCode's `MessageAbortedError` / `session.execution.interrupted` by the user, Cursor's aborted `stop`): the turn is over and nothing is owed — no last words, never "your turn" |
| | `title` | The vendor named the session (Pi's `session_info_changed`, OpenCode's `session.updated` / `session.renamed`): message = the name, which is the row's title over the first prompt; empty clears it. No state, and it makes no session |
| | `end` | The session ended |
| Activity | `tool` | A tool ran (or a reply streamed): the session is working, and — when it names its tool — its last step and the answer to a block raised for that tool; when it names none, its message is the reply's words |
| | `status` | Work goes on and no tool finished (a status, a retry, a recoverable error, a compaction, or a tool that started — `tool` names it, `message` its target: what runs now): never a step, never an answer; one that names no tool never starts a turn |
| Heard | `ignored` | The receiver heard an event it did not turn into state: an event Pulse does not install, a payload that is not a JSON object, a blocked event from an agent that cannot report one, activity or a prompt with no session, an event that says nothing Pulse shows, a prompt that does not block (Pi's `custom` view), a request no prompt can show (Claude's `dontAsk`, a `claude -p` run without a permission host — read from the agent process's argv), a notice that may be about another session (Claude's `agent_needs_input`). `message` says which (`PulseHookReceiver.Ignored`) — never the payload's words. The reducer changes no state for it; it goes on its session's timeline and is Settings' "last not used" |

`working`, `done`, `dismiss`, `stopped` and `end` clear the session's
block; `start` does unless the session is working — each only when the
main agent wrote it (a subagent's line clears only its own block). A `tool` or `status` line keeps a
working session from reading stalled — a `status` line that names no tool
only that: in a session that is not working or blocked it moves nothing;
a `tool` line answers a block raised
before it in the same session by the same speaker (a main-agent step never
answers a subagent's block) — unless both name a tool and the names
differ (a parallel tool is not the answer). A `status` line never answers;
for an agent whose own module sends every ask's reply
(`AgentSpec.stepsAnswerBlocks` false: OpenCode) no step answers.

The receiver writes one line for every event of one of the six agents it
hears (exit 0 every time; an agent that is not one of the six, or another
tool running an agent's hooks as its own, writes nothing). State comes only
from what an agent's own adapter read from one of its vendor events
(`vendor-formats.md` has each agent's mapping): the kind words above are not
events of any agent. A blocked event from an agent whose hooks cannot
report a block (`waiting: .none` — Codex, Cursor) is an `ignored` line. That
is the No fake Waiting gate for this channel. The reader takes a kind only
as spelled in the table — no alias, no vendor word, no guess from free text.

## Reader rules

- Every line applies, in `seq` order, to its session (`SessionKey`: agent +
  session, or agent + folder when it names none). `ignored` lines change no
  state and make no session; one that names a session the reader holds goes
  on that session's timeline (its last twelve heard lines, with what each
  did — rebuilt by the replay, kept nowhere else).
- The `event` column is carried, never read for state: a session keeps the
  event that put it in its current state (a re-raise inside the grace keeps
  the first raise's) — the why cites it.
- A blocked line for an agent with `waiting: .none` (Codex, Cursor) is
  ignored, whoever wrote it.
- **A subagent is not the person.** A line with `sub` never answers a
  block the main agent — or another subagent — raised; it never revives a
  turn that has ended (`your turn` and idle stay); its `working` line is
  its own task, not the person's prompt (no title, no latest prompt, no
  turn clock); its `start`, `title`, `stopped` and `end` move nothing. A
  block it raises is the session's block (the work cannot go on), and only
  that subagent's own `tool` (same tool, as below), `done` or end of turn
  answers it — or the main agent's prompt, `done`, `stopped` or `end`;
  never a main-agent `tool`. A main-agent raise of the same kind within
  **20 s** (Claude's main UI `Notification` after the subagent's
  `PermissionRequest`, which names no subagent) is that block said again:
  it stays the subagent's. Inside a live turn its activity is work (it keeps the session
  from reading stalled) and its steps go on the timeline marked as its own.
- `done`, `dismiss`, `working`, `end` clear that session (`session` empty →
  only the agent's session-less entry in the folder it names, or every
  session-less one when it names none; a dismissal always names the folder).
- A `tool` line that names its tool is a step: the session keeps its last
  five (tool, target, time, `err`, `took`, `sub`); a `status` line is not a
  step. A main-agent `tool` line that names no tool and says something is a
  reply: its words are the session's last words until a turn line that
  carries its own. A `status` line that names no tool (a retry, a recoverable
  error, a compaction) keeps a working or blocked session going and starts
  nothing: in an idle, finished or ended session (one already known) it is
  heard and moves nothing. A `status` line that names a tool says that tool runs now, beside
  any other already running (at most eight): while one runs a silence is
  not a stall, and each is finished by the `tool` line of the same tool
  (the same target first) from the same speaker, or by the turn's end. A
  silence is a stall only for an agent whose contract reports a tool's
  start as well as its end (`HookContract.silenceCanStall`); any other
  agent's row states facts only.
- A `stopped` line puts the session at its prompt with nothing owed —
  from working, from a block (no grace: the person was at the prompt) or
  from your turn; one stamped before the block or turn it would end is
  about an earlier one. It carries no last words.
- A `title` line sets the session's name (empty clears it); a `start`
  that carries a name sets it too. The row's title is the name, else the
  first prompt that says something. A `working`
  line starts a new turn (its clock), its text is the latest prompt, and the
  first that says something (not "continue") is the title. A `turn` line's
  message is the last words; a `failed` line's is the turn's error, until
  the next turn starts: a prompt, or a tool after the turn ended (Cursor
  sends no prompt).
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
- `turn` / `failed` clears a blocked wait. Within **20 s** of the raise it
  is **held**, not dropped (the order of a vendor's events is not ours): it
  lands when the grace ends — on the next event or the tick — or at once
  when an answer stamped before it arrives. So a denied prompt (no tool
  runs, the turn ends seconds later) goes out within the grace. A
  session-less turn only clears. A turn never creates a row of its own. A
  turn with `front` = `1` only clears — the user watched it finish.
- A `done` or `dismiss` stamped before the current block or turn began is
  about an earlier one and changes nothing.
- A block raised while no turn was live (at the prompt, or your turn — a
  background subagent's ask after the turn ended) remembers that state:
  answered by its subagent's own line, a `done` or a `dismiss`, the session
  goes back to it, on its own clock — never into a turn nobody started.
- After an `end`, a `turn`, `failed`, `working` or tool-start `status`
  line stamped no later than the end (lines numbered out of order) revives
  nothing.
- A block a `dismiss` cleared is not raised again by its echo: a raise of
  the same kind within **20 s** of the cleared block's raise, with no prompt
  or tool line since the `dismiss`, whose words say nothing new (the same
  ask, or only a generic "needs your permission") is ignored — Claude's
  `Notification` after a dismissed `PermissionRequest` does not turn the
  lamp red or post a banner again. A vendor's own `done` has no echo: the
  same ask after it is a new ask, and is raised.
- A blocked line with `front` = `1` lights the lamp but raises no banner.
- A session whose recorded pid is dead — or now runs another agent, or
  started after the first line that named it (a reused pid) — has ended.

## Versioning

The protocol is v8: fifteen numbered columns (v7's twelve plus `sub`,
`err` and `took`) and the kinds above (v7's plus `stopped` and `title`),
and a log whose header is not v8 is treated as absent (emptied, started
over, never read). A change to the columns or the kinds is a new protocol
version and a major release.
