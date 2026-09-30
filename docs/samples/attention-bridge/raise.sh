#!/usr/bin/env bash
# Generic Attention Protocol v5 raise for one of Pulse's seven agents,
# through the native pulse-hook — the one writer that appends under the
# event log's lock (a plain `>>` can interleave with a hook writing at the
# same moment, and macOS ships no flock(1)). No launcher, no write.
# See docs/attention-protocol.md and docs/attention-bridge.md
#
# Codex and Cursor never report a wait (their hooks cannot say so honestly):
# pulse-hook refuses a blocked kind for them, and so does this script.
set -euo pipefail
PULSE="${PULSE_HOME:-$HOME/Library/Application Support/Pulse}"
agent="${1:?usage: raise.sh <claude|gemini|copilot|opencode|pi> [session] [kind] [message]}"
session="${2:-sample-$agent}"
kind="${3:-permission}"
message="${4:-Approve tool (sample)}"
case "$agent" in
  codex|cursor)
    case "$kind" in permission|question|waiting)
      echo "$agent never reports a wait — refusing a fake one" >&2; exit 1;;
    esac;;
esac
HOOK="$PULSE/pulse-hook"
if [ ! -x "$HOOK" ]; then
  echo "no launcher at $HOOK — open Pulse once (it writes it), then try again" >&2
  exit 1
fi
echo "{\"message\":\"$message\",\"session_id\":\"$session\",\"cwd\":\"$PWD\"}" \
  | "$HOOK" "$agent" "$kind"
echo "Wrote $agent $kind via pulse-hook (session=$session)"
