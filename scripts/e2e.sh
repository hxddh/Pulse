#!/usr/bin/env bash
# The real path, end to end, on macOS — after PulseBar/Scripts/package.sh:
#
#   1. a throwaway home: every agent's vendor folder, nothing else;
#   2. the real installer writes every hook there (`PulseQA --install-hooks`,
#      the same `HooksInstaller` the app runs) and points the launcher at the
#      packaged app;
#   3. recorded payloads (PulseBar/Tests/Fixtures/hooks) go through the
#      installed `pulse-hook` launcher, which execs the packaged
#      `PulseBar --hook` — stdin for the hooks, the last argument for the
#      Pi extension and the OpenCode plugin, as they send them;
#   4. after each step `PulseQA --dump-snapshot` replays that home's log
#      the way `ScanEngine` does and the tray is checked: a permission turns
#      the lamp red with one banner, the answer turns it back to running and
#      withdraws the banner, the end leaves no live row — for Claude (stdin)
#      and Pi (argv);
#   5. every fixture, through the same launcher into a second log, becomes
#      the line expected.json says.
#
#   ./scripts/e2e.sh
#
# Optional env:
#   PULSE_APP=path   the packaged app (default zig-out/package/Pulse.app)
#   PULSE_QA=path    a built PulseQA (default: build it, debug)
#
# Home: Pulse reads its own folder from PULSE_HOME (`EventLog.directory`,
# the hook and the snapshot both honour it) and the installer's home from
# `HooksInstaller.homeOverride` (the flag). HOME and CFFIXED_USER_HOME —
# what Foundation's home directory honours on macOS; HOME alone is not —
# are set to the throwaway home too, so nothing else (the debug log) lands
# in the real one. Nothing outside the temp folder is written; no network.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this script must run on macOS" >&2
  exit 2
fi
APP="${PULSE_APP:-$ROOT/zig-out/package/Pulse.app}"
RUNNER="$APP/Contents/MacOS/PulseBar"
if [[ ! -x "$RUNNER" ]]; then
  echo "error: no packaged app at $APP — run ./PulseBar/Scripts/package.sh first" >&2
  exit 2
fi
if [[ -n "${PULSE_QA:-}" ]]; then
  QA="$PULSE_QA"
else
  swift build --package-path "$ROOT/PulseBar" --product PulseQA >&2
  QA="$(swift build --package-path "$ROOT/PulseBar" --product PulseQA --show-bin-path)/PulseQA"
fi
[[ -x "$QA" ]] || { echo "error: PulseQA not found at $QA" >&2; exit 2; }

FIXTURES="$ROOT/PulseBar/Tests/Fixtures/hooks"
EXPECTED="$FIXTURES/expected.json"
CHECK=(python3 -I "$ROOT/scripts/e2e_assert.py")

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pulse-e2e.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
TEST_HOME="$WORK/home"
SUPPORT="$TEST_HOME/Library/Application Support/Pulse"
mkdir -p "$TEST_HOME"/{.claude,.codex,.cursor,.pi/agent,.copilot,.config/opencode}
export HOME="$TEST_HOME" CFFIXED_USER_HOME="$TEST_HOME" PULSE_HOME="$SUPPORT"

# Run with a deadline: macOS has no `timeout`. A hook must never hang.
deadline() {
  local seconds="$1"
  shift
  perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$seconds" "$@"
}

failures=0
fail() {
  echo "e2e FAIL $*"
  failures=$((failures + 1))
}

# --- 1–2 · install ------------------------------------------------------------

echo "--- install into $TEST_HOME"
deadline 30 "$QA" --install-hooks="$TEST_HOME" --runner="$RUNNER" || fail "the installer reported a failure"
LAUNCHER="$SUPPORT/pulse-hook"
[[ -x "$LAUNCHER" ]] || { echo "e2e FAIL no launcher at $LAUNCHER"; exit 1; }
[[ "$(cat "$SUPPORT/hook-runner.path")" == "$RUNNER" ]] || fail "hook-runner.path does not name the packaged app"
[[ -s "$SUPPORT/hook-installs.json" ]] || fail "no install ledger in the throwaway home"
for config in .claude/settings.json .codex/hooks.json .cursor/hooks.json .pi/agent/extensions/pulse.js \
              .copilot/hooks/pulse.json .config/opencode/plugins/pulse.js; do
  if ! grep -q "pulse-hook" "$TEST_HOME/$config" 2>/dev/null; then
    fail "$config does not run pulse-hook"
  fi
done
# The launcher is Pulse's own file, written on this Mac: it carries no
# quarantine, so Gatekeeper never stands between an agent and its hook.
if xattr -p com.apple.quarantine "$LAUNCHER" >/dev/null 2>&1; then
  fail "the launcher is quarantined"
fi
if xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1; then
  echo "note: $APP is quarantined (a downloaded build); the launcher still has to run it"
fi
# The launcher with no runner it can find exits 0 and writes nothing (its
# fallback is /Applications/Pulse.app: skipped on a Mac that has one).
if [[ ! -x /Applications/Pulse.app/Contents/MacOS/PulseBar ]]; then
  mv "$SUPPORT/hook-runner.path" "$WORK/runner.path"
  echo '{"session_id":"none"}' | deadline 10 env HOME="$WORK/nowhere" "$LAUNCHER" claude Stop \
    || fail "the launcher without a runner did not exit 0"
  mv "$WORK/runner.path" "$SUPPORT/hook-runner.path"
  [[ ! -e "$SUPPORT/events.tsv" ]] || fail "the launcher without a runner wrote a line"
fi

# --- 3–4 · the tray, step by step ---------------------------------------------

LOG="$SUPPORT/events.tsv"

# send <agent> <event[@variant]>: one recorded payload through the launcher,
# then exactly one new line, the one expected.json names.
send() {
  local agent="$1" name="$2" file payload before expected
  file="$FIXTURES/$agent/$name.json"
  [[ -f "$file" ]] || { fail "no fixture $agent/$name"; return; }
  before="$("${CHECK[@]}" count "$LOG")"
  expected="$("${CHECK[@]}" expected "$EXPECTED" "$agent/$name")"
  case "$agent" in
    pi|opencode)
      payload="$(cat "$file")"
      deadline 10 "$LAUNCHER" "$agent" "${name%%@*}" "$payload" </dev/null || fail "$agent/$name: the launcher failed" ;;
    *)
      deadline 10 "$LAUNCHER" "$agent" "${name%%@*}" <"$file" || fail "$agent/$name: the launcher failed" ;;
  esac
  "${CHECK[@]}" line "$LOG" "$before" "$expected" || fail "$agent/$name"
  # Lines a millisecond apart: an answer is later than the block it answers.
  sleep 0.02
}

snapshot() {
  local phase="$1" agent="$2" out="$WORK/snapshot-$2-$1.json"
  deadline 30 "$QA" --dump-snapshot="$out" >/dev/null || { fail "dump-snapshot ($agent $phase)"; return; }
  "${CHECK[@]}" snapshot "$out" "$phase" "$agent" || { fail "$agent $phase"; cat "$out"; }
}

echo "--- claude, through stdin"
send claude SessionStart
send claude UserPromptSubmit
send claude PostToolUse
send claude PermissionRequest
snapshot blocked claude
send claude PostToolUse
snapshot answered claude
send claude Stop
send claude SessionEnd
snapshot ended claude

echo "--- pi, through the last argument"
send pi session_start
send pi agent_start
send pi tool_execution_start
send pi ui_prompt_start
snapshot blocked pi
send pi ui_prompt_end
send pi tool_execution_end
snapshot answered pi
send pi agent_settled
send pi session_shutdown
snapshot ended pi

# --- 5 · every fixture --------------------------------------------------------

echo "--- every recorded payload, through the packaged app"
export PULSE_HOME="$WORK/all"
mkdir -p "$PULSE_HOME"
LOG="$PULSE_HOME/events.tsv"
count=0
for dir in "$FIXTURES"/*/; do
  agent="$(basename "$dir")"
  for file in "$dir"*.json; do
    send "$agent" "$(basename "$file" .json)"
    count=$((count + 1))
  done
done
echo "sent $count payloads"

if (( failures > 0 )); then
  echo "e2e FAILED — $failures failure(s)"
  exit 1
fi
echo "e2e OK"
