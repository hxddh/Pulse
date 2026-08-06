#!/usr/bin/env bash
# Mac-only Observation Truth fixture captures for Pulse 0.51+.
#
#   ./scripts/qa_observation_truth.sh
#
# Writes PNGs under zig-out/qa-observation-truth/ for status-* tray fixtures.
# Fails if any expected PNG is missing (CI-friendly).
#
# Optional env:
#   PULSE_QA_APPEARANCE=light|dark   (default light)
#   PULSE_QA_LANGUAGE=zh|en         (default zh)
#   PULSE_QA_TIMEOUT_SECONDS=N      (default 14)
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
APPEARANCE="${PULSE_QA_APPEARANCE:-light}"
LANGUAGE="${PULSE_QA_LANGUAGE:-zh}"
TIMEOUT_SECONDS="${PULSE_QA_TIMEOUT_SECONDS:-14}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this script must run on macOS" >&2
  exit 2
fi
if [[ ! -x "$APP" ]]; then
  echo "error: Pulse binary not found at $APP" >&2
  exit 2
fi

mkdir -p "$OUT"
echo "Observation Truth captures → $OUT (app=$APP appearance=$APPEARANCE language=$LANGUAGE)"

quit_pulse() {
  osascript -e 'tell application id "com.pulse.app" to quit' >/dev/null 2>&1 || true
  pkill -x PulseBar >/dev/null 2>&1 || true
  # Brief settle; avoid a fixed multi-second sleep on the happy path.
  for _ in 1 2 3 4 5 6; do
    if ! pgrep -x PulseBar >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
}

wait_for_files() {
  local timeout="$1"
  shift
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    local missing=0
    for f in "$@"; do
      if [[ ! -s "$f" ]]; then
        missing=1
        break
      fi
    done
    if [[ "$missing" -eq 0 ]]; then
      return 0
    fi
    sleep 0.35
  done
  return 1
}

capture_fixture() {
  local fixture="$1"
  local suffix="${fixture}-${LANGUAGE}-${APPEARANCE}"
  local tray="$OUT/${suffix}-tray.png"
  local lamp="$OUT/${suffix}-lamp.png"
  # Keep legacy filenames for CI artifact expectations (zh/light).
  if [[ "$LANGUAGE" == "zh" && "$APPEARANCE" == "light" ]]; then
    tray="$OUT/${fixture}-tray-zh-light.png"
    lamp="$OUT/${fixture}-lamp-zh-light.png"
  fi

  quit_pulse
  rm -f "$tray" "$lamp"
  echo "--- fixture $fixture ---"
  "$APP" \
    --tray-fixture="$fixture" \
    --appearance="$APPEARANCE" \
    --language="$LANGUAGE" \
    --open-tray-panel \
    --capture-tray-panel="$tray" \
    --capture-status-item="$lamp" &
  local pid=$!

  if ! wait_for_files "$TIMEOUT_SECONDS" "$tray" "$lamp"; then
    echo "error: timed out waiting for captures of $fixture" >&2
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true
    quit_pulse
    for f in "$tray" "$lamp"; do
      if [[ ! -s "$f" ]]; then
        echo "error: missing capture $f" >&2
      fi
    done
    exit 1
  fi

  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" 2>/dev/null || true
  quit_pulse
  ls -lah "$tray" "$lamp"
}

for fixture in status-waiting status-running status-stalled; do
  capture_fixture "$fixture"
done

echo "done → $OUT"
ls -lah "$OUT"
