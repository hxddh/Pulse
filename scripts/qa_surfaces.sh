#!/usr/bin/env bash
# 15.0 · Witness — render every surface fixture (tray rows, the cards under a
# row, the Why card, the self-check) in zh/en × light/dark and fail if any PNG
# is missing.
#
#   ./scripts/qa_surfaces.sh
#
# Writes PNGs, one contact sheet per language/appearance and a manifest per
# pass under zig-out/qa-surfaces/. Fixture names come from
# `SurfaceFixtures.names`; this script reads them from the source so the two
# cannot drift.
#
# Optional env:
#   PULSE_QA_OUT=dir                (default zig-out/qa-surfaces)
#   PULSE_QA_TIMEOUT_SECONDS=N      (default 60)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "${PULSE_APP:-}" ]]; then
  APP="$PULSE_APP"
elif [[ -x "$ROOT/zig-out/package/Pulse.app/Contents/MacOS/PulseBar" ]]; then
  APP="$ROOT/zig-out/package/Pulse.app/Contents/MacOS/PulseBar"
else
  APP="/Applications/Pulse.app/Contents/MacOS/PulseBar"
fi
OUT="${PULSE_QA_OUT:-$ROOT/zig-out/qa-surfaces}"
TIMEOUT_SECONDS="${PULSE_QA_TIMEOUT_SECONDS:-60}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this script must run on macOS" >&2
  exit 2
fi
if [[ ! -x "$APP" ]]; then
  echo "error: Pulse binary not found at $APP" >&2
  exit 2
fi

NAMES=$(python3 - "$ROOT/PulseBar/Sources/PulseBar/SurfaceFixtures.swift" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
block = re.search(r"static let names = \[(.*?)\]", src, re.S).group(1)
print(" ".join(re.findall(r'"([a-z0-9-]+)"', block)))
PY
)
if [[ -z "$NAMES" ]]; then
  echo "error: no fixture names found" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
status=0
for language in zh en; do
  for appearance in light dark; do
    suffix="$language-$appearance"
    echo "--- surfaces $suffix ---"
    pkill -x PulseBar >/dev/null 2>&1 || true
    "$APP" --capture-surfaces="$OUT" --language="$language" --appearance="$appearance" &
    pid=$!
    deadline=$((SECONDS + TIMEOUT_SECONDS))
    while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do
      sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "error: surface capture $suffix did not finish in ${TIMEOUT_SECONDS}s" >&2
      kill "$pid" 2>/dev/null || true
      status=1
      continue
    fi
    wait "$pid" 2>/dev/null || true
    manifest="$OUT/manifest-$suffix.txt"
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
    for name in $NAMES; do
      png="$OUT/$name-$suffix.png"
      if [[ ! -s "$png" ]]; then
        echo "error: missing capture $png" >&2
        status=1
      fi
    done
    if [[ ! -s "$OUT/contact-sheet-$suffix.png" ]]; then
      echo "error: missing contact sheet for $suffix" >&2
      status=1
    fi
  done
done
ls -la "$OUT"
exit $status
