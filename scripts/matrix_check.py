#!/usr/bin/env python3
"""Gate: the README support matrix must match AgentID capabilities in code.

The README table is hand-maintained and silently drifted from the enum. Since
that table is what tells users whether an agent can ever show "needs you", a
wrong row is a broken promise, not a typo.

Run: python3 scripts/matrix_check.py
Exit 1 when the doc and the code disagree.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
README = ROOT / "README.md"
sys.path.insert(0, str(Path(__file__).resolve().parent))
import agent_roster  # noqa: E402

ROSTER = agent_roster.agents()

# Display name (as written in README) -> AgentID case name in Swift. The
# catalog's display names, plus the short forms the README table uses.
DISPLAY_TO_CASE = {agent.display: agent.case for agent in ROSTER}
DISPLAY_TO_CASE.update({"Zed": "zedAgent", "Warp": "warpAgent"})


def case_sources(property_name: str) -> dict[str, str]:
    """{case name: value} for a roster field, read from AgentCatalog.swift."""
    field = {"waitingSource": "waiting", "harvestSource": "harvest"}[property_name]
    return {agent.case: getattr(agent, field) for agent in ROSTER}


def readme_rows() -> list[tuple[str, str, str, int]]:
    """(display name, harvest cell, waiting cell, line number)."""
    rows: list[tuple[str, str, str, int]] = []
    in_table = False
    for n, line in enumerate(README.read_text(encoding="utf-8").splitlines(), start=1):
        if line.startswith("| Agent |"):
            in_table = True
            continue
        if in_table:
            if not line.startswith("|"):
                break
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) < 4 or set(cells[0]) <= set("- "):
                continue
            rows.append((cells[0], cells[2], cells[3], n))
    return rows


def expected_kind(cell: str) -> str:
    """Map a README waiting cell to hooks / harvestPending / none."""
    low = cell.lower()
    if "none" in low:
        return "none"
    if "hooks" in low:
        return "hooks"
    if "pending" in low:
        return "harvestPending"
    return "?"


def expected_harvest(cell: str) -> str:
    low = cell.lower()
    if "structured" in low or "结构化" in low:
        return "structuredSession"
    if "best" in low or "尽力" in low:
        return "bestEffortCache"
    return "?"


def main() -> int:
    sources = case_sources("waitingSource")
    harvest_sources = case_sources("harvestSource")
    rows = readme_rows()
    if not rows:
        print("FAIL: no support matrix found in README (expected a '| Agent |' table)", file=sys.stderr)
        return 1

    failures: list[str] = []
    covered: set[str] = set()

    for names_cell, harvest_cell, waiting_cell, lineno in rows:
        want = expected_kind(waiting_cell)
        want_harvest = expected_harvest(harvest_cell)
        if want == "?":
            failures.append(f"README:{lineno} unreadable waiting cell {waiting_cell!r}")
            continue
        if want_harvest == "?":
            failures.append(f"README:{lineno} unreadable harvest cell {harvest_cell!r}")
            continue
        for raw in names_cell.split("/"):
            name = raw.strip().rstrip("*").strip()
            if not name:
                continue
            case = DISPLAY_TO_CASE.get(name)
            if case is None:
                failures.append(f"README:{lineno} unknown agent name {name!r}")
                continue
            covered.add(case)
            actual = sources.get(case)
            if actual is None:
                failures.append(f"README:{lineno} {name}: no waitingSource in AgentCatalog.swift")
            elif actual != want:
                failures.append(
                    f"README:{lineno} {name}: doc says {want}, code says {actual}"
                )
            actual_harvest = harvest_sources.get(case)
            if actual_harvest is None:
                failures.append(f"README:{lineno} {name}: no harvestSource in AgentCatalog.swift")
            elif actual_harvest != want_harvest:
                failures.append(
                    f"README:{lineno} {name}: harvest doc says {want_harvest}, "
                    f"code says {actual_harvest}"
                )

    missing = sorted((set(sources) | set(harvest_sources)) - covered - {"cursorAgent"})
    for case in missing:
        failures.append(f"{case}: has a waitingSource but is absent from the README matrix")

    if failures:
        for f in failures:
            print("MISMATCH", f)
        return 1

    # Contract Honesty (0.70): fleet-count prose must not lag AgentID growth.
    experience = (ROOT / "EXPERIENCE.md").read_text(encoding="utf-8")
    if "32 个用户可见 Agent" not in experience:
        print("FAIL: EXPERIENCE.md Support Health must say 32 visible Agents", file=sys.stderr)
        return 1
    if "| Y |" not in experience or "Contract Honesty" not in experience:
        print("FAIL: EXPERIENCE.md missing scenario Y (Contract Honesty)", file=sys.stderr)
        return 1
    obs = (ROOT / "docs" / "observability-matrix.md").read_text(encoding="utf-8")
    if "all 32 surfaces" not in obs:
        print("FAIL: observability-matrix.md must say all 32 surfaces", file=sys.stderr)
        return 1
    if "static var waitingNoneAgents" not in agent_roster.text():
        print("FAIL: AgentCatalog.swift missing AgentID.waitingNoneAgents truth source", file=sys.stderr)
        return 1

    print(f"support matrix OK — {len(covered)} agents agree with harvestSource + waitingSource")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
