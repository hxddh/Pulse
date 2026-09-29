# Attention Protocol v3

Public contract for raising a Pulse **Waiting** lamp from any agent, IDE, or
shell — without expanding the Claude/Codex hook installer.

**Audience:** bridge authors and Waiting-none agent owners.  
**Runtime path:** `~/Library/Application Support/Pulse/attention.tsv`  
**Remote inbox:** `~/Library/Application Support/Pulse/attention.d/<host>.tsv`  
**Preferred writer:** `pulse-hook` → `PulseBar --hook` (native, no Python).  
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

**v1 and v2 lines stay valid.** Six columns means `host` is empty, which means
this Mac — exactly what every v1 line already meant; seven means `front` is
unknown. Readers accept every header version, so an installed older hook keeps
lighting the lamp after an upgrade (but see the v3 kind changes below).

| Column | Rules |
| --- | --- |
| `agent` | Pulse `AgentID.rawValue` (`claude`, `codex`, `replit`, `cursor`, …) |
| `kind` | Allowlisted token only (below), after alias normalization |
| `unix_ms` | Integer milliseconds since epoch |
| `message` | Human-readable; tab/newline stripped; ≤200 chars |
| `session` | Opaque session key; empty allowed |
| `cwd` | Absolute project path hint; empty allowed |
| `host` | Machine label; **empty means this Mac**. `|`, `/`, tabs and newlines are replaced with `-`; a trailing `.local` is dropped; capped at 32 chars |
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
| `done` | Nothing is owed: clears blocked and your-turn for that session (`session` empty → the whole agent) |

### Lifecycle (stored for diagnostics; never lights anything)

| Kind | Meaning |
| --- | --- |
| `subagent_start` | Subagent began |
| `subagent_stop` | Subagent ended |

Anything else is **rejected** by `pulse-hook` / `PulseBar --hook` (exit 0, no
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

18.0 additions: `elicitation_url_dialog` is a `question`; a PermissionRequest whose `tool_name` is `AskUserQuestion` is written as `question` and never held for a Respond verdict — no allow/deny answers a question.

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
- `done` clears that session (`session` empty → clear all for that agent).
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
| Native `PulseBar --hook` / `pulse-hook` | Preferred (0.61+) |
| Bundled / legacy `pulse_hook.py` | Same wire format + allowlist; still accepted |
| Hand-append matching this header + kinds | Accepted if fields are valid |

Pulse does **not** promise Composer deep links, tray approve/deny, or any path
that infers Waiting from silence. Waiting-none agents never raise harvest
`pending`.

## Versioning

- **v1** was additive only for new allowlisted kinds; **v2** added `host`;
  **v3** added `front` and changed the meaning of `idle_prompt`, `stop` and the
  turn-complete aliases (above) — Pulse 16.0.
- Breaking changes require a new header version and a coexisting reader path.
- Divergent headers historically confused readers — keep this byte-identical
  across Swift and optional Python writers.

## Another machine (v2)

Pulse writes no network code and runs no server. A remote agent becomes visible
by its events reaching this Mac's inbox — by whatever means you already use.

```bash
# On the remote box: raise as usual, but sign the events.
export PULSE_HOST="devbox"
"$HOME/Library/Application Support/Pulse/pulse-hook" claude permission

# On this Mac (or from the remote box's own cron / your own script):
rsync devbox:'~/Library/Application Support/Pulse/attention.tsv' \
  ~/Library/'Application Support'/Pulse/attention.d/devbox.tsv
```

- One file per host. Remote writers never contend for the local lock.
- The **file name is the fallback identity**, so a remote box still running a v1
  hook is shown as itself rather than as this Mac.
- Bounds: at most 16 inbox files, 256 KB read per file.

### What a remote row can and cannot claim

Pulse cannot probe another machine, so a remote row **never** reports a live
process and **never** offers Focus. Its line says *last heard*, not *last
activity*. Once nothing refreshes it inside the TTL it becomes **lost contact**:
the lamp comes down, the row stays, and the reason is stated — because "I
stopped hearing from it" is not "it finished".

Event stamps come from the sender's clock. When one disagrees with arrival past
the point of belief, Pulse measures from arrival and says so on the row, rather
than dropping the event the way it used to.

### Trust

**Anything that can write the inbox can light your lamp.** That is already true
of the local `attention.tsv`; a synced folder widens it to anything with write
access to that folder. The kind allowlist still applies — free text never
becomes a red lamp — but the sender is not authenticated. Point the inbox at a
directory you control.
