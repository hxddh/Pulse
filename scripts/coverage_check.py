#!/usr/bin/env python3
"""Coverage gate: every surface AgentID must have a native harvest descriptor.

Until 0.99 this gate read `src/activity_scan.py` and counted `emit_row("...")`
strings — it measured the *legacy Python* collector, which had not been the
runtime path since 0.48 and has now been deleted. It therefore could not have
noticed a native adapter losing its roots. It now reads the Swift descriptor
table that the product actually walks, plus `AgentID.harvestSource` for the
evidence tier.

Run: python3 scripts/coverage_check.py
Exit 1 on a missing descriptor.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / "PulseBar" / "Sources" / "PulseBar" / "NativeActivityHarvest.swift"
MODELS = ROOT / "PulseBar" / "Sources" / "PulseBar" / "Models.swift"

# AgentID raw values that must have a descriptor in NativeActivityHarvest.
# cursor_agent is a transport alias of cursor and has no descriptor of its own.
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
    "zcode",
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


def swift_case_to_raw(name: str) -> str:
    """`.commandCode` → `command_code`, matching the AgentID raw values."""
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower().rstrip("_")


def harvest_tiers() -> dict[str, str]:
    """`AgentID.harvestSource` → {raw id: structuredSession|bestEffortCache}."""
    text = MODELS.read_text(encoding="utf-8")
    block = re.search(
        r"var harvestSource: HarvestSource \{(.*?)\n    \}", text, re.S
    )
    if not block:
        return {}
    tiers: dict[str, str] = {}
    pending: list[str] = []
    for line in block.group(1).splitlines():
        line = line.strip()
        if line.startswith("//"):
            continue
        if line.startswith("return ."):
            tier = re.search(r"return \.(\w+)", line).group(1)
            for case in pending:
                tiers[swift_case_to_raw(case)] = tier
            pending = []
        elif line.startswith("case ") or line.startswith("."):
            # A case list wraps across lines; continuation lines start with the
            # next `.member` rather than repeating `case`.
            pending += re.findall(r"\.(\w+)", line)
    return tiers


def main() -> int:
    native = NATIVE.read_text(encoding="utf-8")
    block = re.search(r"private static func descriptors\(.*?\n    \}", native, re.S)
    if not block:
        print("MISSING NativeActivityHarvest.descriptors()")
        return 1
    wired = {swift_case_to_raw(m) for m in re.findall(r"d\(\s*\.(\w+)\s*,", block.group(0))}
    missing = sorted(EXPECTED - wired)
    print(f"native descriptors: {len(wired & EXPECTED)}/{len(EXPECTED)}")
    if missing:
        print("MISSING native harvest descriptor:", ", ".join(missing))
        return 1

    tiers = harvest_tiers()
    missing_contracts = sorted(EXPECTED - tiers.keys())
    extra_contracts = sorted(tiers.keys() - EXPECTED - {"cursor_agent"})
    if missing_contracts or extra_contracts:
        print(
            "harvest contract mismatch:",
            f"missing={','.join(missing_contracts) or '-'}",
            f"extra={','.join(extra_contracts) or '-'}",
        )
        return 1
    session_count = sum(
        tiers[name] == "structuredSession" for name in EXPECTED
    )
    cache_count = sum(tiers[name] == "bestEffortCache" for name in EXPECTED)
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
    # 0.99.2: `lsof` exits 1 when any named PID is gone while still printing
    # every process it did resolve. Gating the output on `status == 0` threw
    # those answers away and armed a five-minute backoff — the same damage the
    # 0.99.1 field-selection bug did, one gate further down.
    if "workingDirectories(from:" not in probe or "shouldBackOff(" not in probe:
        print(
            "ProcessProbe must read lsof output independently of its exit status; "
            "keep workingDirectories(from:) and shouldBackOff()"
        )
        return 1
    if re.search(r"lsof[\s\S]{0,400}?status == 0", probe):
        print("lsof output must not be gated on a zero exit status")
        return 1
    terminal_focus_source = (
        ROOT / "PulseBar/Sources/PulseBar/TerminalFocus.swift"
    ).read_text(encoding="utf-8")
    # 0.55: Terminal/iTerm tab Focus may use osascript only after explicit
    # Shortcuts opt-in, and only inside focusTTY on a user click — never during
    # scan. Advertise path must still gate on allowTTYAutomation.
    if "allowTTYAutomation" not in terminal_focus_source:
        print("TerminalFocus must gate TTY advertising on allowTTYAutomation")
        return 1
    if "focusTTY" in terminal_focus_source and (
        "/usr/bin/osascript" in terminal_focus_source
        or "tell application" in terminal_focus_source
    ):
        if "allowTTYAutomation" not in terminal_focus_source:
            print("TTY AppleScript must stay behind Automation opt-in")
            return 1
    elif "/usr/bin/osascript" in terminal_focus_source or "tell application" in terminal_focus_source:
        print(
            "Pulse must not request Automation through AppleScript outside "
            "opt-in Terminal/iTerm tab Focus"
        )
        return 1
    for label, path in {
        "TerminalFocus": ROOT / "PulseBar/Sources/PulseBar/TerminalFocus.swift",
        "InstallTruth": ROOT / "PulseBar/Sources/PulseBar/InstallTruth.swift",
        "SingleInstanceGuard": ROOT / "PulseBar/Sources/PulseBar/SingleInstanceGuard.swift",
    }.items():
        source = path.read_text(encoding="utf-8")
        # Broad cross-app enumeration is forbidden. Narrow bundle-id lookups on
        # an explicit user click (host IDE / Warp activate) and a LaunchServices
        # lookup scoped to Pulse's own bundle are allowed.
        if re.search(r"NSWorkspace\.shared\.runningApplications\b", source):
            print(f"{label} must not enumerate every running app")
            return 1
        if "runningApplications" in source and not re.search(
            r"runningApplications\s*\(withBundleIdentifier:",
            source,
        ):
            print(f"{label} must not enumerate other apps during normal runtime")
            return 1
    print("OK — every surface AgentID has a native harvest descriptor")
    return 0


if __name__ == "__main__":
    sys.exit(main())
