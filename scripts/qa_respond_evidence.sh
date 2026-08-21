#!/usr/bin/env bash
# Read-only evidence for the two questions Pulse still cannot answer about
# its own most consequential action.
#
#   ③  A verdict was taken by the hook — did the vendor actually honour it?
#   ④  Can the decision carry more than one bit (a message back to the agent)?
#
# `docs/plan-2.0.md` P0-0 was answered from the shipping CLI **binary** for
# Q1–Q5. What was never confirmed on a real machine is what the vendor does
# with what we send, and 2.4 turned that from a two-Mac corner case into the
# everyday path. 2.5 refused to guess at it. This is how it stops being a
# guess.
#
# WHAT THIS DOES NOT DO, by construction:
#   · never approves anything — it only observes and reports
#   · never writes to ~/.claude/settings.json or any Pulse state
#   · never uploads anything, and prints no prompt text, no file contents
#     and no paths from inside your repository
#
# Usage:  scripts/qa_respond_evidence.sh [session-jsonl]
#
# With no argument it picks the most recently modified Claude transcript.
# Run it right after answering one permission request through Pulse.

set -uo pipefail

say() { printf '%s\n' "$*"; }
hr()  { printf '%s\n' "----------------------------------------------------"; }

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

say "qa_respond_evidence — read-only, approves nothing"
hr

# --- 1. Which CLI is installed? P0-0 step 1. -------------------------------
if command -v claude >/dev/null 2>&1; then
  say "claude version: $(claude --version 2>/dev/null | head -1)"
else
  say "claude version: not on PATH — the PermissionRequest hook never fires"
fi

# --- 2. Is Pulse actually registered at the decision point? ----------------
SETTINGS="$CLAUDE_HOME/settings.json"
if [ -f "$SETTINGS" ]; then
  if grep -q 'PermissionRequest' "$SETTINGS" 2>/dev/null; then
    say "PermissionRequest hook: registered"
    # The per-hook timeout decides whether a person has time to answer.
    python3 - "$SETTINGS" <<'PY' 2>/dev/null || say "  (timeout: could not read)"
import json, sys
try:
    hooks = json.load(open(sys.argv[1])).get("hooks", {}).get("PermissionRequest", [])
except Exception:
    raise SystemExit(1)
for entry in hooks:
    for hook in entry.get("hooks", []):
        cmd = hook.get("command", "")
        who = "pulse" if "pulse" in cmd.lower() else "other"
        print(f"  hook={who} timeout={hook.get('timeout', 'default(600)')}s")
PY
  else
    say "PermissionRequest hook: NOT registered — install hooks from Pulse first"
  fi
else
  say "settings.json: absent at $SETTINGS"
fi

# --- 3. The transcript record. Q2 / question ③. ----------------------------
hr
TRANSCRIPT="${1:-}"
if [ -z "$TRANSCRIPT" ]; then
  TRANSCRIPT="$(find "$CLAUDE_HOME/projects" -name '*.jsonl' -type f -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -1)"
fi

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  say "transcript: none found — answer one permission request, then re-run"
  exit 0
fi

say "transcript: $(basename "$TRANSCRIPT")  ($(wc -l < "$TRANSCRIPT" | tr -d ' ') records)"
say ""
say "Looking for the vendor's own record of a hook decision."
say "Keys only — no prompt text, no tool input, no paths are printed."

python3 - "$TRANSCRIPT" <<'PY'
import json, sys
from collections import Counter

WANTED = ("decisionReason", "permissionBehavior", "permissionDecision",
          "hookName", "hookSpecificOutput", "permissionSuggestions")

hits = Counter()
shapes = {}

def walk(node, path=""):
    if isinstance(node, dict):
        for key, value in node.items():
            here = f"{path}.{key}" if path else key
            if key in WANTED:
                hits[here] += 1
                # Record the SHAPE only: keys, and the value when it is a
                # short bare token like "hook" or "allow". Never free text.
                if isinstance(value, dict):
                    shapes.setdefault(here, sorted(value.keys()))
                elif isinstance(value, str) and len(value) <= 24 and " " not in value:
                    shapes.setdefault(here, value)
                else:
                    shapes.setdefault(here, f"<{type(value).__name__}>")
            walk(value, here)
    elif isinstance(node, list):
        for item in node:
            walk(item, path)

for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        walk(json.loads(line))
    except Exception:
        continue

if not hits:
    print("  (nothing) — the transcript carries no hook-decision record.")
    print("  ③ stays blind: Pulse cannot tell 'honoured' from 'ignored'")
    print("     without a different source. Do NOT add a parser on a guess.")
else:
    print("  FOUND — the vendor does record it:")
    for key, count in hits.most_common():
        print(f"    {key}  ×{count}   shape={shapes.get(key)}")
    print("")
    print("  ③ is answerable. A collector for exactly these keys is honest,")
    print("     because this output is the evidence it rests on.")
PY

hr
say "Paste this whole output into docs/plan-2.0.md under P0-0."
say "Nothing was approved, written or uploaded."
