#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="PulseBar"
BUNDLE_ID="com.pulse.app"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/zig-out/package/Pulse.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/PulseBar"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
"$ROOT_DIR/PulseBar/Scripts/package.sh"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
