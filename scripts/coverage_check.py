#!/usr/bin/env python3
"""Coverage gate: every surface agent id must have a harvest emitter wired in main().

Run: python3 scripts/coverage_check.py
Exit 1 on missing emitter.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCAN = ROOT / "src" / "activity_scan.py"
MODELS = ROOT / "PulseBar" / "Sources" / "PulseBar" / "Models.swift"

# AgentID raw values that must appear as emit / emit_row first arg in main().
# cursor_agent merges into cursor at scan time — harvest emits "cursor".
EXPECTED = {
    "claude",
    "codex",
    "cursor",
    "grok",
    "pi",
    "amp",
    "aider",
    "gemini",
    "copilot",
    "opencode",
    "goose",
    "openhands",
    "cline",
    "roo",
    "continue",
    "amazon_q",
    "cascade",
    "windsurf",  # optional path when no cascade
    "augment",
    "zed_agent",
    "trae",
    "warp_agent",
    "kilo",
    "devin",
    "kiro",
    "junie",
    "replit",
    "droid",
    "command_code",
    "kimi",
    "antigravity",
}


def main() -> int:
    text = SCAN.read_text(encoding="utf-8")
    wired = set(re.findall(r'emit(?:_row)?\(\s*"([a-z0-9_]+)"', text))
    # Explicit loop wiring: (("grok", grok_activity), ("pi", pi_activity))
    wired |= set(re.findall(r'\(\s*"(grok|pi)"\s*,\s*\w+_activity', text))
    missing = sorted(EXPECTED - wired)
    print(f"emitters wired: {len(wired & EXPECTED)}/{len(EXPECTED)}")
    if missing:
        print("MISSING harvest wiring:", ", ".join(missing))
        return 1
    probe = (ROOT / "PulseBar/Sources/PulseBar/ProcessProbe.swift").read_text(encoding="utf-8")
    probe_ids = set(re.findall(r"id:\s*\.(\w+)", probe))
    print(f"probe rules: {len(probe_ids)}")
    print("OK — all expected harvest emitters present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
