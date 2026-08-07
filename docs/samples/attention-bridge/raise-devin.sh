#!/usr/bin/env bash
# Sample Attention bridge raise for devin — see docs/attention-bridge.md
set -euo pipefail
PULSE="${PULSE_HOME:-$HOME/Library/Application Support/Pulse}"
mkdir -p "$PULSE"
ms=$(($(date +%s) * 1000))
session="${1:-sample-devin}"
printf '%s\tpermission\t%s\tApprove tool (sample)\t%s\t%s\n' \
  "devin" "$ms" "$session" "${PWD}" >> "$PULSE/attention.tsv"
echo "Wrote devin Waiting → $PULSE/attention.tsv (session=$session)"
