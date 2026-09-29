#!/usr/bin/env bash
# Mac-only A/B: Cursor process-only vs protected app data session detail.
#
# Decision (0.54): stays **manual Darwin** — not CI. It needs a live Cursor
# install, real App Support trees, and interactive TCC grants that runners do
# not have. Keep it as a local QA script; Observation Truth fixtures cover the
# automated visual path.
#
# Prerequisites: Pulse 0.50+ installed at /Applications/Pulse.app
#
#   ./scripts/qa_mac_cursor_appdata_ab.sh
#
# Writes PNGs under zig-out/qa-cursor-appdata-ab/ and prints harvest summaries.
# 23.0: app data is one switch (`readProtectedAppData` in settings.json), so
# the B round reads every protected agent, Cursor included.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${PULSE_APP:-/Applications/Pulse.app/Contents/MacOS/PulseBar}"
OUT="${PULSE_QA_OUT:-$ROOT/zig-out/qa-cursor-appdata-ab}"
SETTINGS="${HOME}/Library/Application Support/Pulse/settings.json"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this script must run on the Mac that hosts Pulse" >&2
  exit 2
fi
if [[ ! -x "$APP" ]]; then
  echo "error: Pulse binary not found at $APP" >&2
  exit 2
fi

mkdir -p "$OUT"
version="$(defaults read /Applications/Pulse.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo unknown)"
echo "Pulse $version → $OUT"

quit_pulse() {
  osascript -e 'tell application id "com.pulse.app" to quit' >/dev/null 2>&1 || true
  pkill -x PulseBar >/dev/null 2>&1 || true
  sleep 1.2
  if pgrep -x PulseBar >/dev/null; then
    echo "error: PulseBar still running" >&2
    exit 1
  fi
}

set_app_data() {
  local enabled="$1"
  mkdir -p "$(dirname "$SETTINGS")"
  python3 - "$SETTINGS" "$enabled" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
enabled = sys.argv[2] == "1"
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except (OSError, ValueError):
    data = {}
data["readProtectedAppData"] = enabled
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
path.chmod(0o600)
print(f"settings: protected app data {'ON' if enabled else 'OFF'}")
PY
}

capture_round() {
  local label="$1"
  quit_pulse
  echo "--- harvest ($label) ---"
  "$APP" --harvest-test --harvest-dump 2>&1 | tee "$OUT/${label}-harvest.txt" | head -40
  echo "--- capture tray/support ($label) ---"
  "$APP" \
    --appearance=light \
    --language=zh \
    --open-tray-panel \
    --capture-tray-panel="$OUT/${label}-tray-zh-light.png" \
    --capture-support-health="$OUT/${label}-support-zh-light.png" &
  local pid=$!
  sleep 10
  kill "$pid" >/dev/null 2>&1 || true
  quit_pulse
  ls -lah "$OUT/${label}"-*.png "$OUT/${label}-harvest.txt"
}

assert_harvest_differs() {
  local off="$OUT/A-off-harvest.txt"
  local on="$OUT/B-on-harvest.txt"
  if ! grep -q 'appData=0' "$off"; then
    echo "warn: A-off harvest missing appData=0 marker" >&2
  fi
  if ! grep -q 'appData=1' "$on"; then
    echo "error: B-on harvest did not report the app-data switch on" >&2
    exit 1
  fi
  local a_cursor b_cursor
  a_cursor="$(grep -E 'health cursor=' "$off" || true)"
  b_cursor="$(grep -E 'health cursor=' "$on" || true)"
  echo "A cursor: $a_cursor"
  echo "B cursor: $b_cursor"
  if [[ "$a_cursor" == "$b_cursor" ]]; then
    echo "warn: cursor health lines identical — tray captures remain the A/B source of truth" >&2
  fi
}

echo "== A: app data OFF (process-only baseline) =="
set_app_data 0
capture_round "A-off"

echo "== B: app data ON =="
set_app_data 1
capture_round "B-on"
assert_harvest_differs

echo "== restore app data OFF and relaunch user copy =="
set_app_data 0
quit_pulse
open -a /Applications/Pulse.app
sleep 2
echo "running=$(pgrep -x PulseBar || true)"
echo "done → $OUT"
ls -lah "$OUT"
