"""The agent roster as the gates see it: parsed from AgentCatalog.swift.

One reader, so no gate keeps its own hand-written copy of the roster — a copy
is exactly what used to fall behind when an agent was added.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "PulseBar" / "Sources" / "PulseBar" / "AgentCatalog.swift"


@dataclass
class Agent:
    case: str          # Swift case name, e.g. commandCode
    raw: str           # raw value, e.g. command_code
    display: str
    waiting: str       # hooks | harvestPending | none
    harvest: str       # structuredSession | bestEffortCache
    respond_reach: str # hookSite | none
    has_collector: bool


def text() -> str:
    return CATALOG.read_text(encoding="utf-8")


def cases() -> list[tuple[str, str]]:
    """(case name, raw value) in declaration order."""
    block = re.search(r"enum AgentID[^{]*\{(.*?)\n\n", text(), re.S)
    if not block:
        raise SystemExit("agent_roster: enum AgentID not found in AgentCatalog.swift")
    out: list[tuple[str, str]] = []
    for line in block.group(1).splitlines():
        line = line.strip()
        if not line.startswith("case "):
            continue
        for part in line[len("case "):].split(","):
            part = part.strip()
            if not part:
                continue
            m = re.match(r'(\w+)\s*=\s*"([^"]+)"', part)
            out.append((m.group(1), m.group(2)) if m else (part, part.rstrip("_")))
    return out


def agents() -> list[Agent]:
    raw_of = dict(cases())
    body = text()
    starts = [m.start() for m in re.finditer(r"\n        AgentSpec\(\n", body)]
    out: list[Agent] = []
    for i, start in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else len(body)
        chunk = body[start:end]

        def field(name: str) -> str:
            m = re.search(rf"\n            {name}: ([^\n]*)", chunk)
            if not m:
                raise SystemExit(f"agent_roster: spec field {name} missing near {chunk[:80]!r}")
            return m.group(1).rstrip(",").strip()

        case = field("id").lstrip(".")
        out.append(Agent(
            case=case,
            raw=raw_of[case],
            display=field("displayName").strip('"'),
            waiting=field("waiting").lstrip("."),
            harvest=field("harvest").lstrip("."),
            respond_reach=field("respondReach").lstrip("."),
            has_collector=not field("harvestRoots").startswith("[]"),
        ))
    return out
