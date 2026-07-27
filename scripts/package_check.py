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

    # Two locations are defensible, and which one works depends on how the
    # resource bundle is resolved:
    #
    #   Contents/Resources/  — where an app bundle normally keeps resources, and
    #                          where PulseResources looks first.
    #   <app root>/          — where SwiftPM's generated `Bundle.module` accessor
    #                          for an *executable* target looks, and the reason
    #                          0.21–0.23.0 crashed: package.sh used the first,
    #                          the accessor only ever checked the second.
    #
    # Accept either, so this gate does not quietly encode one resolution
    # strategy as the only correct one. `--selftest` is what proves the app can
    # actually reach them.
    candidates = [resources / BUNDLE_NAME, app / BUNDLE_NAME]
    found = [c for c in candidates if c.is_dir()]
    if not found:
        problems.append(
            f"{BUNDLE_NAME} is in neither Contents/Resources/ nor the app root — "
            "resource lookup will fail and the app cannot show its icons"
        )
    for bundle in found:
        # A SwiftPM resource bundle is flat. Adding Contents/ flips CFBundle to
        # the modern layout, so it stops reading the root and looks for
        # Contents/Info.plist instead.
        stray = bundle / "Contents"
        if stray.exists():
            problems.append(
                f"{bundle.name} at {bundle.parent.name}/ has a Contents/ directory — "
                "a SwiftPM resource bundle is flat, and CFBundle will stop reading "
                "the root once it sees this"
            )

        if not (bundle / "Info.plist").is_file():
            problems.append(
                f"{bundle.name} at {bundle.parent.name}/ has no Info.plist — a "
                "directory without one may not open as a bundle at all"
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
    where = ", ".join(str(b.relative_to(app)) for b in found)
    print(f"package OK — {app.name} {version or '?'} · {icons} agent icons")
    print(f"  resource bundle at: {where} (flat, Info.plist present)")
    print("  structure only — run `PulseBar --selftest` to prove it resolves")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
