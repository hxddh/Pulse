#!/usr/bin/env bash
# Clear Attention bridge Waiting for one agent id (argv) or all Waiting-none.
set -euo pipefail
PULSE="${PULSE_HOME:-$HOME/Library/Application Support/Pulse}"
mkdir -p "$PULSE"
ms=$(($(date +%s) * 1000))
agents=("$@")
if [ ${#agents[@]} -eq 0 ]; then
  agents=(replit devin warpAgent trae antigravity junie zcode)
fi
for agent in "${agents[@]}"; do
  printf '%s\tdone\t%s\t\t\t\n' "$agent" "$ms" >> "$PULSE/attention.tsv"
  echo "Cleared $agent"
done
