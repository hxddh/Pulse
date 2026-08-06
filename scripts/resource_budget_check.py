#!/usr/bin/env python3
"""Gate: native fixture selftest stays inside wall-clock and RSS budgets.

    python3 scripts/resource_budget_check.py
    NATIVE_FIXTURE_MAX_SECONDS=20 NATIVE_FIXTURE_MAX_RSS_MB=512 python3 …

Uses `/usr/bin/time -l` on macOS when available; otherwise wall-clock only.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAX_SECONDS = float(os.environ.get("NATIVE_FIXTURE_MAX_SECONDS", "20"))
MAX_RSS_MB = float(os.environ.get("NATIVE_FIXTURE_MAX_RSS_MB", "512"))


def fail(msg: str) -> int:
    print(f"resource budget FAILED: {msg}", file=sys.stderr)
    return 1


def find_binary() -> Path | None:
    packaged = ROOT / "zig-out" / "package" / "Pulse.app" / "Contents" / "MacOS" / "PulseBar"
    if packaged.is_file():
        return packaged
    # Prefer a release build if present.
    for candidate in (ROOT / "PulseBar" / ".build").rglob("PulseBar"):
        if candidate.is_file() and os.access(candidate, os.X_OK) and "PulseBar.dSYM" not in str(candidate):
            return candidate
    return None


def main() -> int:
    if sys.platform != "darwin":
        print("resource budget skipped — macOS only")
        return 0

    binary = find_binary()
    if binary is None:
        # Build a release binary for the gate when package.sh has not run.
        build = subprocess.run(
            ["swift", "build", "-c", "release"],
            cwd=ROOT / "PulseBar",
            capture_output=True,
            text=True,
        )
        if build.returncode != 0:
            return fail(f"swift build failed:\n{build.stderr[-2000:]}")
        show = subprocess.run(
            ["swift", "build", "-c", "release", "--show-bin-path"],
            cwd=ROOT / "PulseBar",
            capture_output=True,
            text=True,
            check=True,
        )
        binary = Path(show.stdout.strip()) / "PulseBar"
    if not binary.is_file():
        return fail(f"PulseBar binary not found at {binary}")

    time_bin = Path("/usr/bin/time")
    cmd = [str(binary), "--native-fixture-test"]
    started = time.monotonic()
    rss_mb = 0.0
    if time_bin.is_file():
        proc = subprocess.run(
            [str(time_bin), "-l", *cmd],
            capture_output=True,
            text=True,
        )
        elapsed = time.monotonic() - started
        combined = proc.stdout + "\n" + proc.stderr
        # macOS time -l: "maximum resident set size" in bytes.
        match = re.search(r"maximum resident set size\s*[:=]?\s*(\d+)", combined, re.I)
        if match:
            rss_mb = int(match.group(1)) / (1024 * 1024)
        # `/usr/bin/time` can exit non-zero when sysctl is blocked (sandbox /
        # restricted environments) even though the child fixture passed.
        fixture_ok = "native fixture PASSED" in combined or (
            proc.returncode == 0 and "native fixture FAILED" not in combined
        )
        if not fixture_ok:
            return fail(f"native-fixture-test exited {proc.returncode}\n{combined[-2000:]}")
    else:
        proc = subprocess.run(cmd, capture_output=True, text=True)
        elapsed = time.monotonic() - started
        combined = proc.stdout + "\n" + proc.stderr
        if proc.returncode != 0 or "native fixture PASSED" not in combined:
            return fail(f"native-fixture-test exited {proc.returncode}\n{combined[-2000:]}")

    if elapsed > MAX_SECONDS:
        return fail(
            f"native fixture took {elapsed:.2f}s "
            f"(limit {MAX_SECONDS:g}s via NATIVE_FIXTURE_MAX_SECONDS)"
        )
    if rss_mb > 0 and rss_mb > MAX_RSS_MB:
        return fail(
            f"native fixture RSS {rss_mb:.1f} MB "
            f"(limit {MAX_RSS_MB:g} MB via NATIVE_FIXTURE_MAX_RSS_MB)"
        )
    rss_note = f" · RSS {rss_mb:.1f} MB" if rss_mb > 0 else ""
    print(f"resource budget OK — {elapsed:.2f}s ≤ {MAX_SECONDS:g}s{rss_note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
