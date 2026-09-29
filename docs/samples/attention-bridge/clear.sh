#!/usr/bin/env bash
# Clear one session's attention (Attention Protocol v4 `done`).
# usage: clear.sh <agent> [session]
set -euo pipefail
PULSE="${PULSE_HOME:-$HOME/Library/Application Support/Pulse}"
mkdir -p "$PULSE"
agent="${1:?usage: clear.sh <agent> [session]}"
session="${2:-sample-$agent}"
ms=$(($(date +%s) * 1000))
# agent kind ms message session cwd front pid transcript landing
printf '%s\tdone\t%s\t\t%s\t\t\t\t\t\n' "$agent" "$ms" "$session" >> "$PULSE/attention.tsv"
echo "Cleared $agent $session"
