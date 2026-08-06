#!/usr/bin/env bash
# Mac-only A/B: Cursor process-only vs App Data session detail.
#
# Prerequisites: Pulse 0.50+ installed at /Applications/Pulse.app
#
#   ./scripts/qa_mac_cursor_appdata_ab.sh
#
# Writes PNGs under zig-out/qa-cursor-appdata-ab/ and prints harvest summaries.
# Does not enable global App Data — only the Cursor agent scope.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${PULSE_APP:-/Applications/Pulse.app/Contents/MacOS/PulseBar}"
OUT="${PULSE_QA_OUT:-$ROOT/zig-out/qa-cursor-appdata-ab}"
SETTINGS="${HOME}/Library/Application Support/Pulse/settings.txt"
POLICY_VERSION=2

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

ensure_settings() {
  mkdir -p "$(dirname "$SETTINGS")"
  if [[ ! -f "$SETTINGS" ]]; then
    cat >"$SETTINGS" <<EOF
auto=1
notify=0
notifyWaiting=1
quiet=0
quietStartMin=1320
quietEndMin=480
lang=auto
login=0
updates=1
appData=0
appDataAgents=
appDataPolicyVersion=${POLICY_VERSION}
hotkey=cmd_shift_p
hotkeyEnabled=0
grouping=project
waitSound=0
stallMin=20
snoozeMin=10
mute=
EOF
  fi
}

set_cursor_appdata() {
  local enabled="$1"
  ensure_settings
  python3 - "$SETTINGS" "$enabled" "$POLICY_VERSION" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
enabled = sys.argv[2] == "1"
policy = sys.argv[3]
text = path.read_text(encoding="utf-8")
lines = []
seen_agents = False
seen_all = False
seen_policy = False
for raw in text.splitlines():
    if raw.startswith("appDataAgents="):
        lines.append("appDataAgents=cursor" if enabled else "appDataAgents=")
        seen_agents = True
    elif raw.startswith("appData="):
        # Keep global off — scoped Cursor grant is the A/B under test.
        lines.append("appData=0")
        seen_all = True
    elif raw.startswith("appDataPolicyVersion="):
        lines.append(f"appDataPolicyVersion={policy}")
        seen_policy = True
    else:
        lines.append(raw)
if not seen_agents:
    lines.append("appDataAgents=cursor" if enabled else "appDataAgents=")
if not seen_all:
    lines.append("appData=0")
if not seen_policy:
    lines.append(f"appDataPolicyVersion={policy}")
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"settings: Cursor App Data {'ON' if enabled else 'OFF'}")
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
  if ! grep -q 'appData=0 agents=none' "$off" && ! grep -q 'agents=none' "$off"; then
    echo "warn: A-off harvest missing agents=none marker" >&2
  fi
  if ! grep -Eq 'appData=0 agents=cursor|agents=cursor' "$on"; then
    echo "error: B-on harvest did not report scoped Cursor App Data grant" >&2
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

echo "== A: Cursor App Data OFF (process-only baseline) =="
set_cursor_appdata 0
capture_round "A-off"

echo "== B: Cursor App Data ON (scoped) =="
set_cursor_appdata 1
capture_round "B-on"
assert_harvest_differs

echo "== restore App Data OFF and relaunch user copy =="
set_cursor_appdata 0
quit_pulse
open -a /Applications/Pulse.app
sleep 2
echo "running=$(pgrep -x PulseBar || true)"
echo "done → $OUT"
ls -lah "$OUT"
