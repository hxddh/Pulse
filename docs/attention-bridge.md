# Optional attention bridge (Droid / Kimi / others)

Pulse’s **installed** hooks cover Claude Code and Codex only. That is intentional — we do not ship a 20-agent hook installer.

Agents that already raise Waiting via harvest `skill=pending` (Droid, Kimi, Cursor, …) do not need this file. Use the bridge when you want **hooks-grade** Waiting (permission / input) from a tool that can run a shell on wait.

## File

```
~/Library/Application Support/Pulse/attention.tsv
```

Columns (tab-separated):

```
agent   kind   ms   message   session   cwd
```

| Column | Notes |
| --- | --- |
| `agent` | Pulse id: `droid`, `kimi`, `claude`, … |
| `kind` | `permission`, `idle_prompt` / `waiting`, `done`, `stop` |
| `ms` | Unix epoch milliseconds |
| `message` | Short reason (no tabs/newlines) |
| `session` | Optional session id for row match / dismiss |
| `cwd` | Optional project path |

Pulse holds an exclusive flock while rewriting the file. Prefer appending via `pulse_hook.py` (shipped inside the app) so locking stays correct:

```bash
# From agent hook / skill — kind + optional JSON on stdin
echo '{"notification_type":"permission","message":"Approve shell","session_id":"abc"}' \
  | /path/to/Pulse.app/Contents/Resources/pulse_hook.py droid

# Or argv kind
…/pulse_hook.py kimi permission
```

Clear a wait (same as tray Dismiss):

```bash
# agent-wide: clears every session of that agent
…/pulse_hook.py droid done

# one session only — the session id must come in via stdin JSON,
# the argv form cannot express it
echo '{"session_id":"abc123"}' | …/pulse_hook.py droid done
```

## Minimal shell append (no Python)

Only if you cannot call `pulse_hook.py`. Race-prone; keep lines short:

```bash
PULSE="$HOME/Library/Application Support/Pulse"
mkdir -p "$PULSE"
ms=$(($(date +%s)*1000))
printf 'droid\tpermission\t%s\tApprove tool\tsess1\t%s\n' "$ms" "$PWD" >> "$PULSE/attention.tsv"
```

## Product rules

- Do **not** expand Preferences → Install hooks to cover every agent.
- Bridge rows show wait signal tag **`hooks`** (same TSV path as Claude/Codex).
- Harvest `pending` remains the default for Droid/Kimi when no TSV line is present.
