#!/usr/bin/env bash
# Generic Attention Protocol v5 raise for one of Pulse's seven agents.
# Prefers native pulse-hook (no Python); falls back to a direct append to
# the event log (events.tsv).
# See docs/attention-protocol.md and docs/attention-bridge.md
#
# Codex and Cursor never report a wait (their hooks cannot say so honestly):
# pulse-hook refuses a blocked kind for them, and so does this fallback.
set -euo pipefail
PULSE="${PULSE_HOME:-$HOME/Library/Application Support/Pulse}"
mkdir -p "$PULSE"
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
if [ -x "$HOOK" ]; then
  echo "{\"message\":\"$message\",\"session_id\":\"$session\",\"cwd\":\"$PWD\"}" \
    | "$HOOK" "$agent" "$kind"
  echo "Wrote $agent $kind via pulse-hook (session=$session)"
  exit 0
fi
ms=$(($(date +%s) * 1000))
log="$PULSE/events.tsv"
if [ ! -s "$log" ]; then
  printf '# pulse-events v5 g%s-%s (agent\tkind\tms\tmessage\tsession\tcwd\tfront\tpid\ttranscript\tlanding\ttool)\n' "$ms" "$$" >> "$log"
fi
# agent kind ms message session cwd front pid transcript landing tool — one
# whole line, appended (the log is append-only).
printf '%s\t%s\t%s\t%s\t%s\t%s\t\t%s\t\t%s\t\n' \
  "$agent" "$kind" "$ms" "$message" "$session" "${PWD}" "$PPID" "${TMUX_PANE:+tmux:$TMUX_PANE}" >> "$log"
echo "Wrote $agent $kind → $log (session=$session)"
