#!/usr/bin/env python3
"""Verify a packaged Pulse.app can actually find its resources.

The other gates read source. This one reads the *build output*, because the
bug it exists to catch never appears in source: 0.21 through 0.23.0 all shipped
a DMG that crashed on launch, while every test passed and every gate was green.

What went wrong: SwiftPM builds a *flat* resource bundle — Info.plist and the
resource directories at the root, no Contents/. package.sh then created
`PulseBar_PulseBar.bundle/Contents/Resources/` and copied a second set of
resources in. CFBundle treats any directory containing Contents/ as a modern
bundle, so it stopped reading the root and looked for Contents/Info.plist,
which was never written. Bundle(url:) returns nil for a directory it cannot
read as a bundle, and the compiler-generated `Bundle.module` accessor ends in
fatalError() — so the app died the moment it drew its menu bar icon.

Run against a built app:

    python3 scripts/package_check.py zig-out/package/Pulse.app
"""
from __future__ import annotations

import plistlib
import sys
from pathlib import Path

BUNDLE_NAME = "PulseBar_PulseBar.bundle"

# Resources the app asks Bundle.module for by name. Paths are relative to the
# resource bundle root, which is where a flat SwiftPM bundle keeps them.
REQUIRED_IN_BUNDLE = [
    "activity_scan.py",
    "pulse_hook.py",
    "install_hooks.py",
    "Brand/pulse-mark.png",
    "Brand/pulse-idle.png",
    "Brand/pulse-running.png",
    "Brand/pulse-waiting.png",
    "AgentIcons/claude.png",
    "AgentIcons/codex.png",
]

# Resources reached through Bundle.main.resourceURL — the fallback path that
# does not involve CFBundle at all.
REQUIRED_IN_APP = [
    "activity_scan.py",
    "pulse_hook.py",
    "install_hooks.py",
    "Brand/pulse-mark.png",
    "AgentIcons/claude.png",
]


def fail(problems: list[str]) -> int:
    print("package check FAILED", file=sys.stderr)
    for p in problems:
        print(f"  · {p}", file=sys.stderr)
    return 1


def main(argv: list[str]) -> int:
    app = Path(argv[1] if len(argv) > 1 else "zig-out/package/Pulse.app")
    if not app.is_dir():
        return fail([f"{app} does not exist — run PulseBar/Scripts/package.sh first"])

    problems: list[str] = []
    contents = app / "Contents"
    resources = contents / "Resources"

    if not (contents / "MacOS" / "PulseBar").is_file():
        problems.append("Contents/MacOS/PulseBar is missing")

    app_plist = contents / "Info.plist"
    version = None
    if not app_plist.is_file():
        problems.append("Contents/Info.plist is missing")
    else:
        info = plistlib.loads(app_plist.read_bytes())
        version = info.get("CFBundleShortVersionString")
        if not version:
            problems.append("Contents/Info.plist has no CFBundleShortVersionString")
        if info.get("CFBundleExecutable") != "PulseBar":
            problems.append("Contents/Info.plist CFBundleExecutable is not PulseBar")

    bundle = resources / BUNDLE_NAME
    if not bundle.is_dir():
        problems.append(
            f"Contents/Resources/{BUNDLE_NAME} is missing — Bundle.module will "
            "fatalError() on first resource lookup, i.e. the app crashes on launch"
        )
    else:
        # The bug. A Contents/ directory inside a flat SwiftPM bundle flips
        # CFBundle to the modern layout and hides everything at the root.
        stray = bundle / "Contents"
        if stray.exists():
            problems.append(
                f"{BUNDLE_NAME}/Contents/ exists — CFBundle will read this as a "
                "modern bundle, ignore the flat resources at the root, and fail "
                "to open the bundle (this is the 0.21–0.23.0 launch crash)"
            )

        if not (bundle / "Info.plist").is_file():
            problems.append(
                f"{BUNDLE_NAME}/Info.plist is missing — a directory without one is "
                "not a bundle, so Bundle(url:) returns nil and Bundle.module traps"
            )

        for rel in REQUIRED_IN_BUNDLE:
            if not (bundle / rel).is_file():
                problems.append(f"{BUNDLE_NAME}/{rel} is missing")

    for rel in REQUIRED_IN_APP:
        if not (resources / rel).is_file():
            problems.append(f"Contents/Resources/{rel} is missing")

    if problems:
        return fail(problems)

    icons = len(list((resources / "AgentIcons").glob("*.png")))
    print(f"package OK — {app.name} {version or '?'} · {icons} agent icons")
    print(f"  resource bundle: flat layout, Info.plist present, no stray Contents/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
