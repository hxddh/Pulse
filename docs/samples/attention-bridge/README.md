# Attention bridge samples

Minimal scripts that raise a real Waiting line for Agents whose
`waitingSource` is `.none`. They write Attention Protocol v1 — see
[`docs/attention-protocol.md`](../../attention-protocol.md) and
[`docs/attention-bridge.md`](../../attention-bridge.md).

| Script | Agent id |
| --- | --- |
| `raise.sh` | **any** (generic protocol raise) |
| `raise-replit.sh` | `replit` |
| `raise-devin.sh` | `devin` |
| `raise-warp-agent.sh` | `warpAgent` |
| `raise-trae.sh` | `trae` |
| `raise-antigravity.sh` | `antigravity` |
| `raise-junie.sh` | `junie` |
| `raise-zcode.sh` | `zcode` |
| `clear.sh` | clear one agent (or all listed) |

Usage:

```bash
# Generic — preferred entry for bridge authors
./docs/samples/attention-bridge/raise.sh replit
./docs/samples/attention-bridge/raise.sh cursor sess-42 idle_prompt "Need a model choice"

# Agent-specific samples
./docs/samples/attention-bridge/raise-replit.sh
./docs/samples/attention-bridge/raise-devin.sh sess-42
./docs/samples/attention-bridge/clear.sh replit
```

All scripts **prefer** `~/Library/Application Support/Pulse/pulse-hook`
(native, no Python) and only fall back to a direct TSV append when the launcher
is missing.

These are **samples**, not an installer. Do not expand the Claude/Codex hook
installer to cover these Agents.

In-app: Settings → Waiting signals → **Write sample Waiting** appends one
Attention line for **all seven** Waiting-none Agents (`pulse-sample` session);
**Clear sample Waiting** clears them. Same contract as these scripts.
