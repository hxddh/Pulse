#!/usr/bin/env python3
"""Print one version's section from CHANGELOG.md.

Used as the GitHub Release body, so release notes and the changelog can never
tell different stories.

Run: python3 scripts/changelog_section.py 0.22.0
Exit 1 when that version has no section — a release without notes is a bug.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHANGELOG = ROOT / "CHANGELOG.md"


def section(version: str) -> str | None:
    lines = CHANGELOG.read_text(encoding="utf-8").splitlines()
    start: int | None = None
    for i, line in enumerate(lines):
        m = re.match(r"^## (\d+\.\d+\.\d+)", line)
        if not m:
            continue
        if start is None and m.group(1) == version:
            start = i
            continue
        if start is not None:
            return "\n".join(lines[start:i]).strip()
    if start is not None:
        return "\n".join(lines[start:]).strip()
    return None


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: changelog_section.py <version>", file=sys.stderr)
        return 2
    body = section(argv[0])
    if body is None:
        print(f"no '## {argv[0]}' section in CHANGELOG.md", file=sys.stderr)
        return 1
    print(body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
