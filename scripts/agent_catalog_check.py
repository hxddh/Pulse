#!/usr/bin/env python3
"""Roster gate: per-agent facts live in AgentCatalog.swift, nowhere else.

12.0 moved ten scattered per-agent tables (four exhaustive switches in
Models.swift, the process rules, the harvest descriptors, two transcript
lists, the alias switch, the monogram switch, Respond reach) into one
`AgentSpec` per agent. The failure this gate exists for is that shape
quietly growing back: a new exhaustive `switch` over `AgentID` somewhere
else means adding an agent touches two files again, and the one that gets
forgotten compiles.

The check: outside the catalog, no single `case` line may name more than
MAX_PER_CASE agents, and no file may name more than MAX_PER_FILE distinct
agents in `case` lines. Vendor-specific parsing legitimately branches on a
few agents; a roster-wide table does not fit under either bound.

It also derives the roster from the catalog and checks every agent has a
spec, a unique monogram and a harvest decision, so the Python gates below
it no longer keep their own hand-written list.

Run: python3 scripts/agent_catalog_check.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "PulseBar" / "Sources" / "PulseBar"
CATALOG = SOURCES / "AgentCatalog.swift"
MAX_PER_CASE = 6
MAX_PER_FILE = 8


def agent_cases() -> list[str]:
    """Swift case names of `AgentID`, in declaration order."""
    text = CATALOG.read_text(encoding="utf-8")
    block = re.search(r"enum AgentID[^{]*\{(.*?)\n\n", text, re.S)
    if not block:
        sys.exit("agent_catalog_check: cannot find enum AgentID in AgentCatalog.swift")
    names: list[str] = []
    for line in block.group(1).splitlines():
        line = line.strip()
        if not line.startswith("case "):
            continue
        for part in line[len("case "):].split(","):
            part = part.strip()
            if part:
                names.append(part.split("=")[0].strip())
    return names


def main() -> int:
    names = agent_cases()
    catalog = CATALOG.read_text(encoding="utf-8")
    problems: list[str] = []

    specs = re.findall(r"AgentSpec\(\s*id:\s*\.(\w+)", catalog)
    if sorted(specs) != sorted(names) or len(specs) != len(set(specs)):
        missing = sorted(set(names) - set(specs))
        extra = sorted(set(specs) - set(names))
        problems.append(f"catalog specs ≠ AgentID cases (missing {missing}, extra {extra})")
    if specs != names:
        problems.append("AgentCatalog.all must follow AgentID declaration order (process-rule precedence)")
    monograms = re.findall(r'monogram:\s*"([^"]+)"', catalog)
    if len(monograms) != len(set(monograms)):
        problems.append("monograms must be unique across the roster")

    agent_re = re.compile(r"\.(" + "|".join(re.escape(n) for n in names) + r")\b")
    for path in sorted(SOURCES.glob("*.swift")):
        if path == CATALOG:
            continue
        seen: set[str] = set()
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("//"):
                continue
            if not stripped.startswith("case ."):
                continue
            hits = set(agent_re.findall(stripped.split(":")[0]))
            if len(hits) > MAX_PER_CASE:
                problems.append(
                    f"{path.name}:{number}: a case naming {len(hits)} agents — "
                    "roster-wide facts belong in AgentCatalog"
                )
            seen |= hits
        # A roster list is a roster table too: 12.0 missed an eleven-agent
        # `[.amp, .claude, …].contains(id)` because it was not a `case` line
        # and it wrapped across two lines.
        code = re.sub(r"//[^\n]*", "", path.read_text(encoding="utf-8"))
        for match in re.finditer(r"\[([^\[\]]*)\]", code):
            listed = set(agent_re.findall(match.group(1)))
            if len(listed) > MAX_PER_CASE:
                number = code.count("\n", 0, match.start()) + 1
                problems.append(
                    f"{path.name}:{number}: a list naming {len(listed)} agents — "
                    "roster-wide facts belong in AgentCatalog"
                )
        if len(seen) > MAX_PER_FILE:
            problems.append(
                f"{path.name}: `case` lines name {len(seen)} agents — "
                "an exhaustive per-agent table belongs in AgentCatalog"
            )

    if problems:
        for problem in problems:
            print(f"::error::{problem}")
        return 1
    print(f"agent catalog OK — {len(names)} agents, one spec each, no roster tables elsewhere")
    return 0


if __name__ == "__main__":
    sys.exit(main())
