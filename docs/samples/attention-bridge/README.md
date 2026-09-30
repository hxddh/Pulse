# Attention bridge samples

Two minimal scripts that append Attention Protocol v5 lines to the event
log, `events.tsv`, for one of Pulse's seven agents — see
[`docs/attention-protocol.md`](../../attention-protocol.md) and
[`docs/attention-bridge.md`](../../attention-bridge.md). The installed hooks
do this for real; these are for trying the tray by hand.

| Script | What it writes |
| --- | --- |
| `raise.sh <agent> [session] [kind] [message]` | one line of the given kind (default `permission`) |
| `clear.sh <agent> [session]` | a `done` for that session |

```bash
./docs/samples/attention-bridge/raise.sh claude
./docs/samples/attention-bridge/raise.sh gemini sess-42 question "Which database?"
./docs/samples/attention-bridge/clear.sh gemini sess-42
```

Both write through `~/Library/Application Support/Pulse/pulse-hook` (the
native launcher Pulse writes at launch), which appends one whole line under
the event log's exclusive lock — a plain `>>` could interleave with a hook
writing at the same moment, and macOS ships no `flock(1)`. Without the
launcher they write nothing. Codex and Cursor never report a wait: a blocked
kind for them is refused, by `pulse-hook` and by the script.
