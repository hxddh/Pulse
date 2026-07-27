#!/usr/bin/env python3
"""Gate: the README support matrix must match `AgentID.waitingSource` in code.

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
MODELS = ROOT / "PulseBar" / "Sources" / "PulseBar" / "Models.swift"
README = ROOT / "README.md"

# Display name (as written in README) -> AgentID case name in Swift.
DISPLAY_TO_CASE = {
    "Claude": "claude",
    "Codex": "codex",
    "Cursor": "cursor",
    "Cursor Agent": "cursorAgent",
    "Grok": "grok",
    "Pi": "pi",
    "Amp": "amp",
    "Aider": "aider",
    "Gemini": "gemini",
    "Copilot": "copilot",
    "OpenCode": "opencode",
    "Goose": "goose",
    "OpenHands": "openhands",
    "Cline": "cline",
    "Roo": "roo",
    "Continue": "continue_",
    "Amazon Q": "amazonQ",
    "Cascade": "cascade",
    "Windsurf": "windsurf",
    "Augment": "augment",
    "Zed": "zedAgent",
    "Zed Agent": "zedAgent",
    "Trae": "trae",
    "Warp": "warpAgent",
    "Warp Agent": "warpAgent",
    "Devin": "devin",
    "Kiro": "kiro",
    "Junie": "junie",
    "Kilo": "kilo",
    "Replit": "replit",
    "Droid": "droid",
    "Command Code": "commandCode",
    "Antigravity": "antigravity",
    "Kimi": "kimi",
}


def waiting_sources() -> dict[str, str]:
    """Parse `var waitingSource` into {case name: hooks|harvestPending|none}."""
    text = MODELS.read_text(encoding="utf-8")
    m = re.search(r"var waitingSource: WaitingSource \{(.*?)\n    \}", text, re.S)
    if not m:
        print("FAIL: could not find waitingSource in Models.swift", file=sys.stderr)
        raise SystemExit(1)

    body = m.group(1)
    out: dict[str, str] = {}
    pending_cases: list[str] = []
    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith("//"):
            continue
        if stripped.startswith("case "):
            pending_cases.extend(re.findall(r"\.(\w+)", stripped))
        elif stripped.startswith("return ."):
            source = stripped[len("return ."):].strip()
            for case in pending_cases:
                out[case] = source
            pending_cases = []
        elif stripped:
            # continuation of a multi-line `case` list
            pending_cases.extend(re.findall(r"\.(\w+)", stripped))
    return out


def readme_rows() -> list[tuple[str, str, int]]:
    """(display name, waiting cell, line number) from the support matrix."""
    rows: list[tuple[str, str, int]] = []
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
            rows.append((cells[0], cells[3], n))
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


def main() -> int:
    sources = waiting_sources()
    rows = readme_rows()
    if not rows:
        print("FAIL: no support matrix found in README (expected a '| Agent |' table)", file=sys.stderr)
        return 1

    failures: list[str] = []
    covered: set[str] = set()

    for names_cell, waiting_cell, lineno in rows:
        want = expected_kind(waiting_cell)
        if want == "?":
            failures.append(f"README:{lineno} unreadable waiting cell {waiting_cell!r}")
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
                failures.append(f"README:{lineno} {name}: no waitingSource in Models.swift")
            elif actual != want:
                failures.append(
                    f"README:{lineno} {name}: doc says {want}, code says {actual}"
                )

    missing = sorted(set(sources) - covered - {"cursorAgent"})
    for case in missing:
        failures.append(f"{case}: has a waitingSource but is absent from the README matrix")

    if failures:
        for f in failures:
            print("MISMATCH", f)
        return 1

    print(f"support matrix OK — {len(covered)} agents agree with waitingSource")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
