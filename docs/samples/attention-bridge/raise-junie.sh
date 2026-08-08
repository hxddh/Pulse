#!/usr/bin/env bash
# Sample Attention bridge raise for junie — see docs/attention-bridge.md
# Prefers native pulse-hook (no Python); falls back to direct TSV append.
set -euo pipefail
PULSE="${PULSE_HOME:-$HOME/Library/Application Support/Pulse}"
mkdir -p "$PULSE"
session="${1:-sample-junie}"
HOOK="$PULSE/pulse-hook"
if [ -x "$HOOK" ]; then
  echo "{\"notification_type\":\"permission\",\"message\":\"Approve tool (sample)\",\"session_id\":\"$session\",\"cwd\":\"$PWD\"}" \
    | "$HOOK" junie
  echo "Wrote junie Waiting via pulse-hook (session=$session)"
  exit 0
fi
ms=$(($(date +%s) * 1000))
printf '%s\tpermission\t%s\tApprove tool (sample)\t%s\t%s\n' \
  "junie" "$ms" "$session" "${PWD}" >> "$PULSE/attention.tsv"
echo "Wrote junie Waiting → $PULSE/attention.tsv (session=$session)"
