#!/usr/bin/env bash
# Mac-only Observation Truth fixture captures for Pulse 0.51+.
#
#   ./scripts/qa_observation_truth.sh
#
# Writes PNGs under zig-out/qa-observation-truth/ for status-* tray fixtures.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${PULSE_APP:-/Applications/Pulse.app/Contents/MacOS/PulseBar}"
OUT="${PULSE_QA_OUT:-$ROOT/zig-out/qa-observation-truth}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this script must run on macOS" >&2
  exit 2
fi
if [[ ! -x "$APP" ]]; then
  echo "error: Pulse binary not found at $APP" >&2
  exit 2
fi

mkdir -p "$OUT"
echo "Observation Truth captures → $OUT"

quit_pulse() {
  osascript -e 'tell application id "com.pulse.app" to quit' >/dev/null 2>&1 || true
  pkill -x PulseBar >/dev/null 2>&1 || true
  sleep 1.2
}

capture_fixture() {
  local fixture="$1"
  quit_pulse
  echo "--- fixture $fixture ---"
  "$APP" \
    --tray-fixture="$fixture" \
    --appearance=light \
    --language=zh \
    --open-tray-panel \
    --capture-tray-panel="$OUT/${fixture}-tray-zh-light.png" \
    --capture-status-item="$OUT/${fixture}-lamp-zh-light.png" &
  local pid=$!
  sleep 9
  kill "$pid" >/dev/null 2>&1 || true
  quit_pulse
  ls -lah "$OUT/${fixture}"-*.png
}

for fixture in status-waiting status-running status-stalled; do
  capture_fixture "$fixture"
done

echo "done → $OUT"
ls -lah "$OUT"
