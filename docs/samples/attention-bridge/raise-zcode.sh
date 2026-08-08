#!/usr/bin/env bash
# Sample Attention bridge raise for zcode — see docs/attention-bridge.md
# Prefers native pulse-hook (no Python); falls back to direct TSV append.
set -euo pipefail
PULSE="${PULSE_HOME:-$HOME/Library/Application Support/Pulse}"
mkdir -p "$PULSE"
session="${1:-sample-zcode}"
HOOK="$PULSE/pulse-hook"
if [ -x "$HOOK" ]; then
  echo "{\"notification_type\":\"permission\",\"message\":\"Approve tool (sample)\",\"session_id\":\"$session\",\"cwd\":\"$PWD\"}" \
    | "$HOOK" zcode
  echo "Wrote zcode Waiting via pulse-hook (session=$session)"
  exit 0
fi
ms=$(($(date +%s) * 1000))
printf '%s\tpermission\t%s\tApprove tool (sample)\t%s\t%s\n' \
  "zcode" "$ms" "$session" "${PWD}" >> "$PULSE/attention.tsv"
echo "Wrote zcode Waiting → $PULSE/attention.tsv (session=$session)"
