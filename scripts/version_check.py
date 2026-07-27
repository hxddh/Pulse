#!/usr/bin/env python3
"""Version gate: one product version, everywhere.

`PulseBar/Sources/PulseBar/Models.swift` → `PulseVersion.semver` is the truth.
Everything else that carries a version string must agree with it:

  - app.zon                → .version
  - src/version.zig        → semver + major/minor/patch
  - CHANGELOG.md           → newest `## x.y.z` heading
  - README.md              → the `**版本：`x.y.z`**` badge

Run: python3 scripts/version_check.py [--fix]
Exit 1 on any mismatch (with --fix, rewrites the followers and exits 0).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODELS = ROOT / "PulseBar" / "Sources" / "PulseBar" / "Models.swift"
APP_ZON = ROOT / "app.zon"
VERSION_ZIG = ROOT / "src" / "version.zig"
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
    (APP_ZON, r'\.version = "([^"]+)"', "app.zon .version"),
    (VERSION_ZIG, r'pub const semver: \[\]const u8 = "([^"]+)"', "src/version.zig semver"),
    (CHANGELOG, r"(?m)^## (\d+\.\d+\.\d+)", "CHANGELOG newest heading"),
    (README, r"\*\*版本：`([^`]+)`\*\*", "README version badge"),
]


def fix_version_zig_parts(want: str) -> None:
    major, minor, patch = want.split(".")
    text = VERSION_ZIG.read_text(encoding="utf-8")
    text = re.sub(r"pub const major: u32 = \d+;", f"pub const major: u32 = {major};", text)
    text = re.sub(r"pub const minor: u32 = \d+;", f"pub const minor: u32 = {minor};", text)
    text = re.sub(r"pub const patch: u32 = \d+;", f"pub const patch: u32 = {patch};", text)
    VERSION_ZIG.write_text(text, encoding="utf-8")


def check_version_zig_parts(want: str) -> tuple[bool, str]:
    text = VERSION_ZIG.read_text(encoding="utf-8")
    parts = []
    for name in ("major", "minor", "patch"):
        m = re.search(rf"pub const {name}: u32 = (\d+);", text)
        parts.append(m.group(1) if m else "?")
    found = ".".join(parts)
    return found == want, found


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

    if VERSION_ZIG.exists():
        ok, found = check_version_zig_parts(want)
        if not ok:
            if do_fix:
                fix_version_zig_parts(want)
                print(f"fixed   src/version.zig parts: {found} → {want}")
            else:
                failures.append(f"src/version.zig major/minor/patch: {found} (want {want})")

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
