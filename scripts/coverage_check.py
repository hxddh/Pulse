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


def swift_file(name: str) -> Path:
    """A Swift file by name, in whichever target holds it (12.3 split them)."""
    hits = sorted((ROOT / "PulseBar" / "Sources").glob(f"*/{name}"))
    if len(hits) != 1:
        raise SystemExit(f"coverage_check: expected one {name}, found {len(hits)}")
    return hits[0]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import agent_roster  # noqa: E402

ROSTER = agent_roster.agents()
CATALOG_TEXT = agent_roster.text()

# Every AgentID must have native harvest roots. cursor_agent is a transport
# alias of cursor and deliberately has none of its own. The set is derived
# from the catalog — a hand-kept copy here was one more place an added agent
# had to be remembered.
EXPECTED = {agent.raw for agent in ROSTER} - {"cursor_agent"}


def harvest_tiers() -> dict[str, str]:
    """`AgentSpec.harvest` → {raw id: structuredSession|bestEffortCache}."""
    return {agent.raw: agent.harvest for agent in ROSTER}


def main() -> int:
    native = swift_file("NativeActivityHarvest.swift").read_text(encoding="utf-8")
    if "AgentCatalog.all" not in native or "harvestRoots" not in native:
        print("NativeActivityHarvest.descriptors() must be built from AgentCatalog")
        return 1
    wired = {agent.raw for agent in ROSTER if agent.has_collector}
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

    known = {agent.raw for agent in ROSTER} - {"cursor_agent"}
    probe = swift_file("ProcessProbe.swift").read_text(encoding="utf-8")
    print(f"probe rules: {CATALOG_TEXT.count('process: AgentProcessRule(')} · AgentID cases: {len(known) + 1}")
    if '"worker start"' not in CATALOG_TEXT or '"--worker-dir"' not in CATALOG_TEXT:
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
    # 1.1: an agent may only claim `respondReach == .hookSite` when Pulse is
    # actually registered at that agent's permission decision point. Reach is a
    # statement about an installed hook, not a capability — and a capability
    # claim nobody installed is exactly the shape of bug this project keeps
    # having to undo.
    respond = swift_file("RespondContract.swift").read_text(encoding="utf-8")
    installer = swift_file("HooksInstaller.swift").read_text(encoding="utf-8")
    reaching = [agent.raw for agent in ROSTER if agent.respond_reach == "hookSite"]
    for name in reaching:
        raw = name
        if '"PermissionRequest"' not in installer or f'agent: "{raw}", kind: "permission"' not in installer:
            print(
                f"{raw} claims respondReach .hookSite but no PermissionRequest hook installs it"
            )
            return 1
    print(f"respond reach: {len(reaching)} at the decision point ({','.join(sorted(reaching)) or '-'})")

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
