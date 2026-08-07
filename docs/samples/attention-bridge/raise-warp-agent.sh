#!/usr/bin/env bash
# Sample Attention bridge raise for warpAgent — see docs/attention-bridge.md
set -euo pipefail
PULSE="${PULSE_HOME:-$HOME/Library/Application Support/Pulse}"
mkdir -p "$PULSE"
ms=$(($(date +%s) * 1000))
session="${1:-sample-warpAgent}"
printf '%s\tpermission\t%s\tApprove tool (sample)\t%s\t%s\n' \
  "warpAgent" "$ms" "$session" "${PWD}" >> "$PULSE/attention.tsv"
echo "Wrote warpAgent Waiting → $PULSE/attention.tsv (session=$session)"
