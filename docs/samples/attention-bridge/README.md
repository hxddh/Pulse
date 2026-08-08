# Attention bridge samples

Minimal scripts that raise a real Waiting line for Agents whose
`waitingSource` is `.none`. They write the same TSV Pulse already reads —
see [`docs/attention-bridge.md`](../../attention-bridge.md).

| Script | Agent id |
| --- | --- |
| `raise-replit.sh` | `replit` |
| `raise-devin.sh` | `devin` |
| `raise-warp-agent.sh` | `warpAgent` |
| `raise-trae.sh` | `trae` |
| `raise-antigravity.sh` | `antigravity` |
| `raise-junie.sh` | `junie` |
| `clear.sh` | clear one agent (or all listed) |

Usage:

```bash
./docs/samples/attention-bridge/raise-replit.sh
# optional session id:
./docs/samples/attention-bridge/raise-devin.sh sess-42
./docs/samples/attention-bridge/clear.sh replit
```

These are **samples**, not an installer. Do not expand the Claude/Codex hook
installer to cover these Agents.

In-app: Settings → Waiting signals → **Write sample Waiting** appends one
Attention line for **all six** Waiting-none Agents (`pulse-sample` session);
**Clear sample Waiting** clears them. Same contract as these scripts.
