#!/usr/bin/env bash
# Generic Attention Protocol v1 raise — any agent id.
# Prefers native pulse-hook (no Python); falls back to direct TSV append.
# See docs/attention-protocol.md and docs/attention-bridge.md
set -euo pipefail
PULSE="${PULSE_HOME:-$HOME/Library/Application Support/Pulse}"
mkdir -p "$PULSE"
agent="${1:?usage: raise.sh <agent_id> [session] [kind] [message]}"
session="${2:-sample-$agent}"
kind="${3:-permission}"
message="${4:-Approve tool (sample)}"
HOOK="$PULSE/pulse-hook"
if [ -x "$HOOK" ]; then
  echo "{\"notification_type\":\"$kind\",\"message\":\"$message\",\"session_id\":\"$session\",\"cwd\":\"$PWD\"}" \
    | "$HOOK" "$agent"
  echo "Wrote $agent Waiting via pulse-hook (session=$session kind=$kind)"
  exit 0
fi
ms=$(($(date +%s) * 1000))
header='# pulse-attention v1 (agent\tkind\tms\tmessage\tsession\tcwd)'
tsv="$PULSE/attention.tsv"
if [ ! -f "$tsv" ] || ! grep -q 'pulse-attention v1' "$tsv" 2>/dev/null; then
  printf '%s\n' "$header" > "$tsv.tmp"
  if [ -f "$tsv" ]; then
    grep -v '^#' "$tsv" >> "$tsv.tmp" || true
  fi
  mv "$tsv.tmp" "$tsv"
fi
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$agent" "$kind" "$ms" "$message" "$session" "${PWD}" >> "$tsv"
echo "Wrote $agent Waiting → $tsv (session=$session kind=$kind)"
