# Attention Protocol v3

Public contract for raising a Pulse **Waiting** lamp from any agent, IDE, or
shell — without expanding the Claude/Codex hook installer.

**Audience:** bridge authors and Waiting-none agent owners.  
**Runtime path:** `~/Library/Application Support/Pulse/attention.tsv`  
**Writers:** `pulse-hook` → `PulseBar --hook` (native), or append a line
yourself.  
**Swift source of truth:** `AttentionProtocol` in PulseBar.

Companion:

- Product policy → [`attention-bridge.md`](attention-bridge.md)
- Samples → [`samples/attention-bridge/`](samples/attention-bridge/)
- EXPERIENCE scenario **U** → [`../EXPERIENCE.md`](../EXPERIENCE.md)

## Wire format

UTF-8 TSV, one event per line. Header must be the first line:

```text
# pulse-attention v3 (agent\tkind\tms\tmessage\tsession\tcwd\thost\tfront)
<agent>\t<kind>\t<unix_ms>\t<message>\t<session>\t<cwd>\t<host>\t<front>
```

**Every line has all eight columns** (since Pulse 23.0). A six-column (v1) or
seven-column (v2) line is not read. Leave `host` and `front` empty when you
have nothing to put there — the trailing tabs are part of the record.

| Column | Rules |
| --- | --- |
| `agent` | Pulse `AgentID.rawValue` (`claude`, `codex`, `replit`, `cursor`, …) |
| `kind` | Allowlisted token only (below), after alias normalization |
| `unix_ms` | Integer milliseconds since epoch |
| `message` | Human-readable; tab/newline stripped; ≤200 chars |
| `session` | Opaque session key; empty allowed |
| `cwd` | Absolute project path hint; empty allowed |
| `host` | Written empty; **the reader ignores it**: every line in `attention.tsv` is this Mac's |
| `front` | v3. `1` when the prompt's own window was the frontmost application as the event was raised, `0` when it was not, **empty when unknown**. Only the local native receiver fills it (parent-chain walk, no new permission). Unknown is never read as "the user is looking" |

Readers skip blank lines, `#` comments, and unknown kinds. Writers rewrite the
header when truncating the file (keep last 80 data lines).

## Kind allowlist

v3 separates what a person can owe an agent: **blocked** (it cannot go on
without you — the red lamp, a banner, a sound), **your turn** (it finished and
is idle at its prompt — a quiet count, never red) and **resolved**.

### Blocked (raises / refreshes the red lamp)

| Kind | Meaning |
| --- | --- |
| `permission` | Tool / filesystem / network approval |
| `question` | A clarifying question or requested input |
| `waiting` | Blocked, reason unknown (prefer a more specific kind when known) |

### Your turn (never red)

| Kind | Meaning |
| --- | --- |
| `turn` | The turn ended and the agent is idle at its prompt. Ends a blocked wait for that session (unless the wait was raised inside the 20 s grace) and marks the session "your turn" until someone looks: a later `done`, a submitted prompt, a Focus from Pulse, or the session moving again. A `turn` with `front` = `1` only clears — the user watched it finish |

### Resolved

| Kind | Meaning |
| --- | --- |
| `done` | Nothing is owed: clears blocked and your-turn for that session (`session` empty → only the agent's session-less entry; since 23.0 it no longer clears the agent's other sessions) |

### Lifecycle (stored for diagnostics; never lights anything)

| Kind | Meaning |
| --- | --- |
| `subagent_start` | Subagent began |
| `subagent_stop` | Subagent ended |

Anything else — including an empty kind (no argv kind, no
`notification_type`, no event name; before 23.0 that was written as
`waiting`) — is **rejected** by `pulse-hook` / `PulseBar --hook` (exit 0, no
write) and **ignored** by `AttentionReader` (never free-text Waiting). That is
the No fake Waiting gate for this channel.

Vendor aliases are normalized before the allowlist check
(`AttentionProtocol.normalizeKind`):

| Tokens | v3 kind |
| --- | --- |
| `permission_prompt`, `exec_approval_request`, `apply_patch_approval_request`, `approval_request`, `pending_approval`, any `…approval…` that is not a response or decision | `permission` |
| `request_user_input`, `user_input_request`, `elicitation_dialog`, `agent_needs_input`, `needs_input`, any `…user_input…` that is not a response | `question` |
| `stop`, `idle_prompt`, `idle`, `agent_turn_complete`, `agent_completed`, `turn_complete`, `task_complete`, `stop_failure` (18.0: Claude's StopFailure) | `turn` |
| `elicitation_complete`, `elicitation_response` (18.0) | `done` |

18.0 additions: `elicitation_url_dialog` is a `question`; a PermissionRequest whose `tool_name` is `AskUserQuestion` is written as `question` — no allow/deny answers a question.

### What v3 changed, and why

- **`idle_prompt` is your turn, not blocked.** Claude's `idle_prompt`
  notification is a 60-second timer that fires after every finished turn
  (anthropics/claude-code #32634, #13922). Until v2 it lit the red lamp, so
  every Claude session that finished its work went red a minute later and
  stayed red. A question now has its own kind.
- **`stop` and Codex's `agent-turn-complete` mark your turn** instead of
  silently clearing. A bridge that used `stop` to mean "clear" should write
  `done`.
- **A line from an older hook that says `idle_prompt` reads as your turn**,
  even where that hook meant a question. The timer is by far the common case;
  the native receiver is the app binary, so upgrading Pulse upgrades it.

## Raise (preferred)

```bash
HOOK="$HOME/Library/Application Support/Pulse/pulse-hook"

# JSON on stdin (kind / message / session / cwd)
echo '{"notification_type":"permission","message":"Approve deploy?","session_id":"sess-1","cwd":"'"$PWD"'"}' \
  | "$HOOK" replit

# argv kind
"$HOOK" junie permission
```

Generic sample: [`samples/attention-bridge/raise.sh`](samples/attention-bridge/raise.sh).

Your turn / clear:

```bash
echo '{"session_id":"sess-1"}' | "$HOOK" replit turn   # finished, over to you
echo '{"session_id":"sess-1"}' | "$HOOK" replit done   # nothing owed
```

## Reader rules

- Same `(agent, session)` — last write wins.
- `done` clears that session (`session` empty → only the agent's
  session-less entry — 23.0; before, it cleared every session of the agent,
  so dismissing one terminal's session-less wait put out the others).
- A blocked hook entry that names no session never attaches to a session
  row; it is its own row in its folder, and its `done` names no session.
- A blocked hook entry goes out when that session's own activity event
  (PreToolUse / UserPromptSubmit, stamped after the raise) arrives: the ask
  was answered in the vendor's prompt.
- `turn` clears a blocked wait, but within **20s** does not wipe a fresh
  `permission` / `question` / `waiting` (the order of a vendor's events is not
  ours); then it marks the session your turn. A session-less `turn` only
  clears. A `turn` never creates a row of its own.
- A blocked line with `front` = `1` lights the lamp but raises no banner and
  no sound.
- Entries older than **30 minutes** expire.
- Named session with no matching sibling → **new** Waiting row (0.60); never
  smear onto a brother session. Empty-session process rows may adopt.

## Compatibility

| Writer | Status |
| --- | --- |
| Native `PulseBar --hook` / `pulse-hook` | Preferred (0.61+); writes and exits at once, never holds |
| Hand-append matching this header + kinds | Accepted if all eight fields are valid |

Pulse does **not** promise Composer deep links, tray approve/deny, or any path
that infers Waiting from silence. Waiting-none agents never raise harvest
`pending`.

## Versioning

- **v1** was additive only for new allowlisted kinds; **v2** added `host`;
  **v3** added `front` and changed the meaning of `idle_prompt`, `stop` and the
  turn-complete aliases (above) — Pulse 16.0.
- 23.0 stopped reading v1/v2 (short) lines: every record has eight columns.
- Divergent headers historically confused readers — keep this byte-identical
  across writers.

## Another machine (removed in 22.0)

v2 added a remote inbox, `attention.d/<host>.tsv`, filled by the user's own
sync tool, and rows for waits raised on other machines ("last heard", "lost
contact"). 22.0 removed it: Pulse is a lamp for this Mac. The `host` column
stays in the format, written empty, and is ignored. Files a
sync tool still drops into `attention.d/` are not read (Pulse leaves the
directory alone).
