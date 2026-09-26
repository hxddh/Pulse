#!/usr/bin/env python3
"""Scenario → test map for docs/scenarios.md (12.4).

The acceptance scenarios used to live as a 76-row table inside EXPERIENCE.md,
and only seven tests named the scenario they pin. This keeps the map honest:
every test file named in the "证明" column must exist, every scenario ID is
unique, and EXPERIENCE.md no longer carries the table.

    python3 scripts/scenario_map.py          # check (gates.sh runs this)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCENARIOS = ROOT / "docs" / "scenarios.md"
TESTS = ROOT / "PulseBar" / "Tests" / "PulseBarTests"
EXPERIENCE = ROOT / "EXPERIENCE.md"


def main() -> int:
    problems: list[str] = []
    text = SCENARIOS.read_text(encoding="utf-8")
    rows = re.findall(r"^\| ([A-Z]{1,2}) \| (.*)$", text, re.M)
    ids = [row[0] for row in rows]
    if len(ids) != len(set(ids)):
        problems.append("duplicate scenario ids in docs/scenarios.md")
    if len(ids) < 76:
        problems.append(f"docs/scenarios.md lists {len(ids)} scenarios; the spec has 76")
    existing = {p.stem for p in TESTS.glob("*.swift")}
    for sid, rest in rows:
        for name in re.findall(r"`(\w+Tests)`", rest):
            if name not in existing:
                problems.append(f"scenario {sid}: {name}.swift does not exist")
    if re.search(r"^\| [A-Z]{1,2} \| ", EXPERIENCE.read_text(encoding="utf-8"), re.M):
        problems.append("EXPERIENCE.md carries a scenario table again — it lives in docs/scenarios.md")
    if problems:
        for problem in problems:
            print(f"::error::{problem}")
        return 1
    mapped = sum(1 for _, rest in rows if re.search(r"`\w+Tests`", rest))
    print(f"scenarios OK — {len(ids)} scenarios, {mapped} pinned by named tests")
    return 0


if __name__ == "__main__":
    sys.exit(main())
