#!/usr/bin/env python3
"""Version gate: one product version, everywhere.

`PulseBar/Sources/PulseBar/Models.swift` → `PulseVersion.semver` is the truth.
Everything else that carries a version string must agree with it:

  - CHANGELOG.md           → newest `## x.y.z` heading
  - README.md              → the `**版本：`x.y.z`**` badge

(The legacy Zig shell carried two more copies; that tree was removed in 0.22.)

Run: python3 scripts/version_check.py [--fix]
Exit 1 on any mismatch (with --fix, rewrites the followers and exits 0).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODELS = ROOT / "PulseBar" / "Sources" / "PulseBar" / "Models.swift"
CHANGELOG = ROOT / "CHANGELOG.md"
README = ROOT / "README.md"

SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def truth() -> str:
    m = re.search(r'static let semver = "([^"]+)"', MODELS.read_text(encoding="utf-8"))
    if not m:
        print(f"FAIL: no PulseVersion.semver in {MODELS.relative_to(ROOT)}", file=sys.stderr)
        raise SystemExit(1)
    v = m.group(1)
    if not SEMVER_RE.match(v):
        print(f"FAIL: PulseVersion.semver {v!r} is not MAJOR.MINOR.PATCH", file=sys.stderr)
        raise SystemExit(1)
    return v


def check(path: Path, pattern: str, want: str) -> tuple[bool, str]:
    """Return (ok, found). `pattern` must capture the version in group 1."""
    if not path.exists():
        return True, want  # optional follower
    m = re.search(pattern, path.read_text(encoding="utf-8"))
    if not m:
        return False, "<not found>"
    return m.group(1) == want, m.group(1)


def fix(path: Path, pattern: str, want: str) -> None:
    if not path.exists():
        return
    text = path.read_text(encoding="utf-8")
    new = re.sub(pattern, lambda m: m.group(0).replace(m.group(1), want), text, count=1)
    if new != text:
        path.write_text(new, encoding="utf-8")


FOLLOWERS: list[tuple[Path, str, str]] = [
    (CHANGELOG, r"(?m)^## (\d+\.\d+\.\d+)", "CHANGELOG newest heading"),
    (README, r"\*\*版本：`([^`]+)`\*\*", "README version badge"),
]


def main(argv: list[str]) -> int:
    do_fix = "--fix" in argv
    want = truth()
    failures: list[str] = []

    for path, pattern, label in FOLLOWERS:
        ok, found = check(path, pattern, want)
        if ok:
            continue
        if do_fix and found != "<not found>":
            fix(path, pattern, want)
            print(f"fixed   {label}: {found} → {want}")
            continue
        failures.append(f"{label}: {found} (want {want})")

    if failures:
        print(f"version truth: {want}")
        for f in failures:
            print("MISMATCH", f)
        print("run: python3 scripts/version_check.py --fix", file=sys.stderr)
        return 1

    print(f"version OK — {want} everywhere")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
