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


def swift_agent_ids() -> set[str]:
    """Raw values of `AgentID` — the surface list the gate must keep up with."""
    text = MODELS.read_text(encoding="utf-8")
    block = re.search(r"enum AgentID[^{]*\{(.*?)\n\n", text, re.S)
    if not block:
        return set()
    ids: set[str] = set()
    for line in block.group(1).splitlines():
        line = line.strip()
        if not line.startswith("case "):
            continue
        for part in line[len("case "):].split(","):
            part = part.strip()
            if not part:
                continue
            m = re.match(r'\w+\s*=\s*"([a-z0-9_]+)"', part)
            ids.add(m.group(1) if m else part.rstrip("_"))
    return ids


def main() -> int:
    text = SCAN.read_text(encoding="utf-8")
    wired = set(re.findall(r'emit(?:_row|_all)?\(\s*"([a-z0-9_]+)"', text))
    # Table wiring: ("codex", codex_activities), ("grok", grok_activity)
    wired |= set(re.findall(r'\(\s*"([a-z0-9_]+)"\s*,\s*\w+_activit(?:y|ies)\s*\)', text))
    missing = sorted(EXPECTED - wired)
    print(f"emitters wired: {len(wired & EXPECTED)}/{len(EXPECTED)}")
    if missing:
        print("MISSING harvest wiring:", ", ".join(missing))
        return 1

    contract_block = re.search(r"HARVEST_CONTRACTS\s*=\s*\{(.*?)\n\}", text, re.S)
    if not contract_block:
        print("MISSING HARVEST_CONTRACTS")
        return 1
    contracts = {
        name: tier
        for name, tier in re.findall(
            r'"([a-z0-9_]+)"\s*:\s*(EVIDENCE_SESSION|EVIDENCE_CACHE)',
            contract_block.group(1),
        )
    }
    missing_contracts = sorted(EXPECTED - contracts.keys())
    extra_contracts = sorted(contracts.keys() - EXPECTED)
    if missing_contracts or extra_contracts:
        print(
            "harvest contract mismatch:",
            f"missing={','.join(missing_contracts) or '-'}",
            f"extra={','.join(extra_contracts) or '-'}",
        )
        return 1
    session_count = sum(value == "EVIDENCE_SESSION" for value in contracts.values())
    cache_count = sum(value == "EVIDENCE_CACHE" for value in contracts.values())
    print(f"collector evidence: {session_count} session · {cache_count} cache")

    # A new AgentID must be added to EXPECTED too, or the gate silently shrinks.
    # cursor_agent merges into cursor at scan time, so it never emits its own id.
    known = swift_agent_ids() - {"cursor_agent"}
    ungated = sorted(known - EXPECTED)
    if ungated:
        print("AgentID missing from this gate's EXPECTED set:", ", ".join(ungated))
        return 1

    probe = (ROOT / "PulseBar/Sources/PulseBar/ProcessProbe.swift").read_text(encoding="utf-8")
    probe_ids = set(re.findall(r"id:\s*\.(\w+)", probe))
    print(f"probe rules: {len(probe_ids)} · AgentID cases: {len(known) + 1}")
    if '"worker start"' not in probe or '"--worker-dir"' not in probe:
        print(
            "Cursor private-worker daemon must be denied; it is infrastructure, not an active session"
        )
        return 1
    terminal_focus_source = (
        ROOT / "PulseBar/Sources/PulseBar/TerminalFocus.swift"
    ).read_text(encoding="utf-8")
    if "/usr/bin/osascript" in terminal_focus_source or "tell application" in terminal_focus_source:
        print(
            "Pulse must not request Automation through AppleScript; tray reveal "
            "fails quietly and Terminal/iTerm focus is not advertised"
        )
        return 1
    print("OK — all expected harvest emitters present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
