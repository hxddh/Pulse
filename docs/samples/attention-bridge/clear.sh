#!/usr/bin/env bash
# Clear one session's wait (Attention Protocol v5 `done`), appended to the
# event log. See docs/attention-protocol.md.
# usage: clear.sh <agent> [session]
set -euo pipefail
PULSE="${PULSE_HOME:-$HOME/Library/Application Support/Pulse}"
mkdir -p "$PULSE"
agent="${1:?usage: clear.sh <agent> [session]}"
session="${2:-sample-$agent}"
ms=$(($(date +%s) * 1000))
log="$PULSE/events.tsv"
if [ ! -s "$log" ]; then
  printf '# pulse-events v5 g%s-%s (agent\tkind\tms\tmessage\tsession\tcwd\tfront\tpid\ttranscript\tlanding\ttool)\n' "$ms" "$$" >> "$log"
fi
# agent kind ms message session cwd front pid transcript landing tool
printf '%s\tdone\t%s\t\t%s\t\t\t\t\t\t\n' "$agent" "$ms" "$session" >> "$log"
echo "Cleared $agent $session"
