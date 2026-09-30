#!/usr/bin/env bash
# Clear one session's wait (Attention Protocol v5 `done`) through the native
# pulse-hook, which appends under the event log's lock.
# See docs/attention-protocol.md.
# usage: clear.sh <agent> [session]
set -euo pipefail
PULSE="${PULSE_HOME:-$HOME/Library/Application Support/Pulse}"
agent="${1:?usage: clear.sh <agent> [session]}"
session="${2:-sample-$agent}"
HOOK="$PULSE/pulse-hook"
if [ ! -x "$HOOK" ]; then
  echo "no launcher at $HOOK — open Pulse once (it writes it), then try again" >&2
  exit 1
fi
echo "{\"session_id\":\"$session\",\"cwd\":\"$PWD\"}" | "$HOOK" "$agent" done
echo "Cleared $agent $session"
