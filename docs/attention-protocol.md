# Attention Protocol v1

Public contract for raising a Pulse **Waiting** lamp from any agent, IDE, or
shell — without expanding the Claude/Codex hook installer.

**Audience:** bridge authors and Waiting-none agent owners.  
**Runtime path:** `~/Library/Application Support/Pulse/attention.tsv`  
**Preferred writer:** `pulse-hook` → `PulseBar --hook` (native, no Python).  
**Swift source of truth:** `AttentionProtocol` in PulseBar.

Companion:

- Product policy → [`attention-bridge.md`](attention-bridge.md)
- Samples → [`samples/attention-bridge/`](samples/attention-bridge/)
- EXPERIENCE scenario **U** → [`../EXPERIENCE.md`](../EXPERIENCE.md)

## Wire format

UTF-8 TSV, one event per line. Header must be the first line:

```text
# pulse-attention v1 (agent\tkind\tms\tmessage\tsession\tcwd)
<agent>\t<kind>\t<unix_ms>\t<message>\t<session>\t<cwd>
```

| Column | Rules |
| --- | --- |
| `agent` | Pulse `AgentID.rawValue` (`claude`, `codex`, `replit`, `cursor`, …) |
| `kind` | Allowlisted token only (below), after alias normalization |
| `unix_ms` | Integer milliseconds since epoch |
| `message` | Human-readable; tab/newline stripped; ≤200 chars |
| `session` | Opaque session key; empty allowed |
| `cwd` | Absolute project path hint; empty allowed |

Readers skip blank lines, `#` comments, and unknown kinds. Writers rewrite the
header when truncating the file (keep last 80 data lines).

## Kind allowlist

### Waiting (raises / refreshes red)

| Kind | Meaning |
| --- | --- |
| `permission` | Tool / filesystem / network approval |
| `idle_prompt` | Clarifying question / user input |
| `waiting` | Generic Waiting (prefer a more specific kind when known) |

### Clear (ends Waiting for that agent+session)

| Kind | Meaning |
| --- | --- |
| `done` | Explicit clear / turn complete |
| `stop` | Stop / interrupt — clears unless a fresh Waiting is within the 20s grace |

### Lifecycle (stored for diagnostics; never lights Waiting)

| Kind | Meaning |
| --- | --- |
| `subagent_start` | Subagent began |
| `subagent_stop` | Subagent ended |

Anything else is **rejected** by `pulse-hook` / `PulseBar --hook` (exit 0, no
write) and **ignored** by `AttentionReader` (never free-text Waiting). That is
the No fake Waiting gate for this channel.

Common vendor aliases (`request_user_input` → `idle_prompt`,
`exec_approval_request` → `permission`, `agent_turn_complete` → `done`, …) are
normalized before the allowlist check. See `AttentionProtocol.normalizeKind`.

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

Clear:

```bash
"$HOOK" replit done
echo '{"session_id":"sess-1"}' | "$HOOK" replit done
```

## Reader rules (unchanged)

- Same `(agent, session)` — last write wins.
- `done` clears that session (`session` empty → clear all for that agent).
- `stop` clears, but within **20s** does not wipe a fresh `permission` /
  `idle_prompt` / `waiting` (Claude often emits idle then Stop).
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

- **v1** is additive only for new allowlisted kinds.
- Breaking changes require a new header version and a coexisting reader path.
- Divergent headers historically confused readers — keep this byte-identical
  across Swift and optional Python writers.
