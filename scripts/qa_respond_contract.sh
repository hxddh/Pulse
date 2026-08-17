#!/usr/bin/env bash
# P0-0 evidence for 1.1 (Respond): what a vendor permission hook actually
# receives, and whether its reply can carry a decision.
#
# Pulse is already registered on Claude's PermissionRequest event and answers
# nothing. Before writing a single line that *produces* a decision, we need to
# know what the vendor hands us and what it will accept back. Guessing here
# does not cost a wrong tray title — it costs approving something that should
# not have been approved.
#
# This script is deliberately timid:
#   - it never approves anything;
#   - it never edits your global ~/.claude settings;
#   - it writes only inside a scratch directory you can delete;
#   - it redacts captured payload *values*, keeping keys and value kinds.
#
# Usage:
#   scripts/qa_respond_contract.sh            # inspect + set up the capture
#   scripts/qa_respond_contract.sh --report   # print the findings to paste back
#
set -euo pipefail

OUT="${PULSE_RESPOND_OUT:-${TMPDIR:-/tmp}/pulse-respond-contract}"
CAPTURE="$OUT/capture.jsonl"
SHAPE="$OUT/shape.txt"
PROJECT="$OUT/project"
HOOK="$OUT/capture-hook.sh"

mkdir -p "$OUT" "$PROJECT"

say() { printf '%s\n' "$*"; }
hr() { printf -- '--- %s ---\n' "$*"; }

# ---------------------------------------------------------------- report mode
if [ "${1:-}" = "--report" ]; then
  say "Pulse 1.1 respond-contract report"
  say "generated on: $(sw_vers -productName 2>/dev/null || uname -s) $(sw_vers -productVersion 2>/dev/null || uname -r)"
  say ""
  hr "Q1/Q5 payload shape (keys and value kinds only, no values)"
  if [ -s "$SHAPE" ]; then cat "$SHAPE"; else say "(no capture yet — run without --report first)"; fi
  say ""
  hr "captured events"
  if [ -s "$CAPTURE" ]; then say "count: $(wc -l < "$CAPTURE" | tr -d ' ')"; else say "count: 0"; fi
  say ""
  hr "Q2/Q3/Q4 — answer these by hand"
  cat <<'QUESTIONS'
Q2  Did the agent honour anything the hook printed on stdout?
    (the capture hook prints nothing by default; to probe this, edit it
     inside the scratch project only — see the note this script printed)
Q3  When the hook exceeded its timeout, what did the agent do?
    a) showed its own prompt as usual   b) errored   c) hung   d) other
Q4  Does raising "timeout" in the hook entry work? Up to what value?
    And what does a user sitting at the keyboard see while it waits?
QUESTIONS
  say ""
  say "Paste this whole report into docs/plan-respond.md under P0-0."
  exit 0
fi

# --------------------------------------------------------------- inspect only
hr "installed hooks (read-only)"
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  say "settings: $SETTINGS"
  # Names of hook events only. No commands, no paths, no project data.
  /usr/bin/python3 - "$SETTINGS" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception as exc:
    print(f"  unreadable: {type(exc).__name__}")
    raise SystemExit(0)
hooks = data.get("hooks") or {}
if not isinstance(hooks, dict):
    print("  no hooks object")
    raise SystemExit(0)
for event in sorted(hooks):
    entries = hooks[event] or []
    blob = json.dumps(entries)
    pulse = "pulse-hook" in blob or "PulseBar" in blob
    timeouts = sorted({
        h.get("timeout")
        for entry in entries if isinstance(entry, dict)
        for h in (entry.get("hooks") or []) if isinstance(h, dict)
    } - {None})
    print(f"  {event}: entries={len(entries)} pulse={'yes' if pulse else 'no'} timeouts={timeouts or '-'}")
PY
else
  say "  no ~/.claude/settings.json — Claude may not be installed here"
fi

# ------------------------------------------------------------- capture set-up
cat > "$HOOK" <<'HOOKEOF'
#!/usr/bin/env bash
# Capture-only. Reads the hook payload, appends it verbatim to a private
# capture file, prints NOTHING, and exits 0 — exactly what Pulse does today.
set -euo pipefail
OUT_DIR="$(cd "$(dirname "$0")" && pwd)"
payload="$(cat || true)"
printf '%s\n' "$payload" >> "$OUT_DIR/capture.jsonl"
exit 0
HOOKEOF
chmod +x "$HOOK"

mkdir -p "$PROJECT/.claude"
cat > "$PROJECT/.claude/settings.local.json" <<EOF
{
  "hooks": {
    "PermissionRequest": [
      { "hooks": [ { "type": "command", "command": "$HOOK", "timeout": 5 } ] }
    ]
  }
}
EOF

hr "capture is ready"
cat <<EOF
A scratch project has been prepared. Nothing outside it was modified.

  scratch project : $PROJECT
  capture file    : $CAPTURE

Next, in a terminal:

  cd "$PROJECT"
  claude

Then ask it to do something that needs approval — a shell command is the usual
one, e.g. "run 'ls -la' for me". Approve or deny it yourself, as you normally
would; the capture hook only watches.

Repeat two or three times, including once with a **large** input (ask it to
edit a long file) so Q5 gets an answer about truncation.

When done:

  scripts/qa_respond_contract.sh --report

To probe Q2 (does stdout carry a decision?), edit the capture hook and make it
print a candidate reply before exiting — the shapes worth trying are in
docs/plan-respond.md (P0-0 evidence section). Do that **only** in this scratch
project, and only with a command you would be happy to see run.
EOF

# --------------------------------------------------------- shape (if present)
if [ -s "$CAPTURE" ]; then
  /usr/bin/python3 - "$CAPTURE" > "$SHAPE" <<'PY'
import json, sys

def kind(value):
    if isinstance(value, bool): return "bool"
    if isinstance(value, int): return "int"
    if isinstance(value, float): return "float"
    if isinstance(value, str): return f"str(len={len(value)})"
    if isinstance(value, list): return f"list[{len(value)}]"
    if isinstance(value, dict): return "object"
    return "null"

def walk(obj, prefix=""):
    out = []
    if isinstance(obj, dict):
        for key in sorted(obj):
            path = f"{prefix}.{key}" if prefix else key
            out.append(f"{path}: {kind(obj[key])}")
            if isinstance(obj[key], (dict, list)):
                out += walk(obj[key], path)
    elif isinstance(obj, list) and obj:
        out += walk(obj[0], f"{prefix}[]")
    return out

seen = {}
for raw in open(sys.argv[1]):
    raw = raw.strip()
    if not raw:
        continue
    try:
        payload = json.loads(raw)
    except Exception:
        print(f"non-JSON payload, {len(raw)} bytes")
        continue
    for line in walk(payload):
        seen[line.split(":")[0]] = line
for line in sorted(seen.values()):
    print(line)
PY
  hr "payload shape so far"
  cat "$SHAPE"
fi
