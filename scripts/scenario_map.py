#!/usr/bin/env python3
"""Scenario → test map for docs/scenarios.md.

The acceptance scenarios used to live as a table inside EXPERIENCE.md. This
keeps the map honest: every test suite named in the "证明" column must be a
declared test type (the tests are grouped by component, so a suite is a
type, not a file), every method named in parentheses after it must exist in
that type, every scenario ID is unique, and EXPERIENCE.md no longer carries
the table.

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
# A floor, so a row cannot vanish unnoticed; it follows the spec down when a
# release removes scenarios with the features they specified.
MIN_SCENARIOS = 74


def test_types() -> dict[str, set[str]]:
    """Test type name → the functions declared in its body."""
    types: dict[str, set[str]] = {}
    for path in sorted(TESTS.glob("*.swift")):
        text = path.read_text(encoding="utf-8")
        for match in re.finditer(r"^(?:final class|struct) (\w+)[^\n]*\{\n(.*?)^\}", text, re.M | re.S):
            types[match.group(1)] = set(re.findall(r"\bfunc (\w+)", match.group(2)))
    return types


def main() -> int:
    problems: list[str] = []
    text = SCENARIOS.read_text(encoding="utf-8")
    rows = re.findall(r"^\| ([A-Z]{1,2}) \| (.*)$", text, re.M)
    ids = [row[0] for row in rows]
    if len(ids) != len(set(ids)):
        problems.append("duplicate scenario ids in docs/scenarios.md")
    if len(ids) < MIN_SCENARIOS:
        problems.append(f"docs/scenarios.md lists {len(ids)} scenarios; the spec has {MIN_SCENARIOS}")
    types = test_types()
    for sid, rest in rows:
        for name, methods in re.findall(r"`(\w+Tests)`(?:[（(]([^）)]*)[）)])?", rest):
            if name not in types:
                problems.append(f"scenario {sid}: no test type {name}")
                continue
            for method in re.findall(r"\b([a-z]\w{5,})\b", methods or ""):
                if method not in types[name]:
                    problems.append(f"scenario {sid}: {name} has no {method}")
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
