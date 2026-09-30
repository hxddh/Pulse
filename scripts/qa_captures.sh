#!/usr/bin/env bash
# Mac-only QA captures drawn by `PulseQA`, and a failure for any PNG missing.
#
#   ./scripts/qa_captures.sh            # both modes
#   ./scripts/qa_captures.sh surfaces   # every surface fixture (tray rows, the
#                                       # header, the notice, the detail page,
#                                       # Settings) in zh/en × light/dark, with
#                                       # a contact sheet and a manifest per pass
#   ./scripts/qa_captures.sh status     # the tray panel and the menu-bar lamp
#                                       # for each status-* fixture, zh·light
#                                       # and en·dark
#
# Writes under zig-out/qa-captures/{surfaces,status}/ — never into the repo.
# Surface fixture names come from `SurfaceFixtures.names`; this script reads
# them from the source so the two cannot drift.
#
# Optional env:
#   PULSE_QA=path                   (a built PulseQA; default: build it)
#   PULSE_QA_OUT=dir                (default zig-out/qa-captures)
#   PULSE_QA_TIMEOUT_SECONDS=N      (per launch; default 60 surfaces, 14 status)
set -euo pipefail

MODE="${1:-all}"
case "$MODE" in
  all|surfaces|status) ;;
  *) echo "usage: $0 [all|surfaces|status]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this script must run on macOS" >&2
  exit 2
fi
# The QA driver is its own executable (`PulseQA`): the shipping app carries no
# fixture, no capture and no QA flag. Built in the debug configuration — it
# reaches the app's internals through `@testable import`.
if [[ -n "${PULSE_QA:-}" ]]; then
  APP="$PULSE_QA"
else
  swift build --package-path "$ROOT/PulseBar" --product PulseQA >&2
  APP="$(swift build --package-path "$ROOT/PulseBar" --product PulseQA --show-bin-path)/PulseQA"
fi
if [[ ! -x "$APP" ]]; then
  echo "error: PulseQA binary not found at $APP" >&2
  exit 2
fi
OUT="${PULSE_QA_OUT:-$ROOT/zig-out/qa-captures}"

quit_pulse() {
  # One Pulse per Mac (SingleInstanceGuard): a running app would keep the
  # driver from starting.
  pkill -x PulseBar >/dev/null 2>&1 || true
  pkill -x PulseQA >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6; do
    if ! pgrep -x PulseQA >/dev/null 2>&1 && ! pgrep -x PulseBar >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
}

# --- surfaces ---------------------------------------------------------------

surfaces() {
  local out="$OUT/surfaces" timeout="${PULSE_QA_TIMEOUT_SECONDS:-60}" status=0
  local names
  names=$(python3 - "$ROOT/PulseBar/Sources/PulseQA/SurfaceFixtures.swift" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
block = re.search(r"static let names = \[(.*?)\]", src, re.S).group(1)
print(" ".join(re.findall(r'"([a-z0-9-]+)"', block)))
PY
)
  if [[ -z "$names" ]]; then
    echo "error: no fixture names found" >&2
    return 1
  fi
  rm -rf "$out"
  mkdir -p "$out"
  for language in zh en; do
    for appearance in light dark; do
      local suffix="$language-$appearance"
      echo "--- surfaces $suffix ---"
      quit_pulse
      "$APP" --capture-surfaces="$out" --language="$language" --appearance="$appearance" &
      local pid=$!
      local deadline=$((SECONDS + timeout))
      while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do
        sleep 0.5
      done
      if kill -0 "$pid" 2>/dev/null; then
        echo "error: surface capture $suffix did not finish in ${timeout}s" >&2
        kill "$pid" 2>/dev/null || true
        status=1
        continue
      fi
      wait "$pid" 2>/dev/null || true
      local manifest="$out/manifest-$suffix.txt"
      if [[ ! -s "$manifest" ]]; then
        echo "error: missing $manifest" >&2
        status=1
        continue
      fi
      cat "$manifest"
      if grep -q '^MISSING ' "$manifest"; then
        echo "error: $suffix has missing captures" >&2
        status=1
      fi
      for name in $names; do
        if [[ ! -s "$out/$name-$suffix.png" ]]; then
          echo "error: missing capture $out/$name-$suffix.png" >&2
          status=1
        fi
      done
      if [[ ! -s "$out/contact-sheet-$suffix.png" ]]; then
        echo "error: missing contact sheet for $suffix" >&2
        status=1
      fi
    done
  done
  return $status
}

# --- status -----------------------------------------------------------------

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

status_captures() {
  local out="$OUT/status" timeout="${PULSE_QA_TIMEOUT_SECONDS:-14}" status=0
  rm -rf "$out"
  mkdir -p "$out"
  for pass in "zh light" "en dark"; do
    local language="${pass% *}" appearance="${pass#* }"
    for fixture in status-waiting status-running status-stalled status-turn; do
      local suffix="$fixture-$language-$appearance"
      local tray="$out/$suffix-tray.png" lamp="$out/$suffix-lamp.png"
      echo "--- status $suffix ---"
      quit_pulse
      "$APP" \
        --tray-fixture="$fixture" \
        --appearance="$appearance" \
        --language="$language" \
        --open-tray-panel \
        --capture-tray-panel="$tray" \
        --capture-status-item="$lamp" &
      local pid=$!
      if ! wait_for_files "$timeout" "$tray" "$lamp"; then
        for f in "$tray" "$lamp"; do
          [[ -s "$f" ]] || echo "error: missing capture $f" >&2
        done
        status=1
      fi
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" 2>/dev/null || true
      quit_pulse
    done
  done
  return $status
}

result=0
if [[ "$MODE" == "all" || "$MODE" == "surfaces" ]]; then
  surfaces || result=1
fi
if [[ "$MODE" == "all" || "$MODE" == "status" ]]; then
  status_captures || result=1
fi
ls -laR "$OUT"
exit $result
