#!/usr/bin/env bash
# Mac-only Observation Truth fixture captures for Pulse 0.51+.
#
#   ./scripts/qa_observation_truth.sh
#
# Writes PNGs under zig-out/qa-observation-truth/ for status-* tray fixtures.
# Fails if any expected PNG is missing (CI-friendly).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "${PULSE_APP:-}" ]]; then
  APP="$PULSE_APP"
elif [[ -x "$ROOT/zig-out/package/Pulse.app/Contents/MacOS/PulseBar" ]]; then
  APP="$ROOT/zig-out/package/Pulse.app/Contents/MacOS/PulseBar"
else
  APP="/Applications/Pulse.app/Contents/MacOS/PulseBar"
fi
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
echo "Observation Truth captures → $OUT (app=$APP)"

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
  wait "$pid" 2>/dev/null || true
  quit_pulse
  for f in "$OUT/${fixture}-tray-zh-light.png" "$OUT/${fixture}-lamp-zh-light.png"; do
    if [[ ! -s "$f" ]]; then
      echo "error: missing capture $f" >&2
      exit 1
    fi
  done
  ls -lah "$OUT/${fixture}"-*.png
}

for fixture in status-waiting status-running status-stalled; do
  capture_fixture "$fixture"
done

echo "done → $OUT"
ls -lah "$OUT"
