#!/usr/bin/env python3
"""Hold the app target's concurrency warnings to a baseline that only goes down.

12.3 turned on complete concurrency checking for the PulseBar app target.
PulseCore already builds with -warnings-as-errors; the app does not yet, so
this is the ratchet in between: CI builds the app target from scratch, pipes
the compiler output here, and this fails if the number of distinct warnings
in the app-side targets (everything but PulseCore, which is already
warning-free and builds with -warnings-as-errors) grew. When it shrinks, lower the baseline in the same
change so it cannot grow back.

    swift build --target PulseBar 2>&1 | python3 scripts/concurrency_ratchet.py
"""
import json
import pathlib
import re
import sys

BASELINE = pathlib.Path(__file__).with_name("concurrency_baseline.json")
WARNING = re.compile(r"^(?P<file>/\S*/Sources/(?!PulseCore/)[^:]+\.swift):(?P<line>\d+):(?P<col>\d+): warning: (?P<msg>.*)$")


def main() -> int:
    log = sys.stdin.read()
    seen = set()
    for line in log.splitlines():
        match = WARNING.match(line.strip())
        if match:
            name = pathlib.Path(match["file"]).name
            seen.add((name, match["line"], match["col"], match["msg"]))
    if "Compiling" not in log and "Build complete" not in log and not seen:
        print("::error::no compiler output on stdin — was the build piped in?")
        return 1
    if re.search(r": error: ", log):
        print("::error::the build failed; the warning count means nothing")
        return 1
    count = len(seen)
    baseline = json.loads(BASELINE.read_text())["PulseBar"]
    by_file = {}
    for name, *_ in seen:
        by_file[name] = by_file.get(name, 0) + 1
    for name, n in sorted(by_file.items(), key=lambda kv: -kv[1])[:15]:
        print(f"  {n:4d}  {name}")
    print(f"App-side concurrency warnings: {count} (baseline {baseline})")
    for item in sorted(seen)[:400]:
        print("  " + ":".join(item))
    if count > baseline:
        print(f"::error::app-target concurrency warnings grew from {baseline} to {count}")
        return 1
    if count < baseline:
        print(f"::notice::down to {count} — lower scripts/concurrency_baseline.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
