#!/usr/bin/env python3
"""Gate: nothing in the UI may freeze the system appearance into a constant.

0.27.1 shipped a panel that rendered light grey with black text on a dark
desktop. The cause was one line:

    static let surface = Color(nsColor: .windowBackgroundColor)

A Swift `static let` is a global initialised once, on first touch. Whatever
appearance happened to be current when the panel first drew got baked in for
the lifetime of the process, and no amount of switching to dark mode after
that could move it. The app had no dark mode at all, and every test passed,
because nothing here renders.

The rule this gate enforces is narrow and mechanical, which is the only kind
worth automating: **an appearance-dependent value may not be stored in a
`static let` / `let` constant.** Read it inside a `body`, or use a token the
renderer resolves per frame (`Material`, `.primary`, `.secondary`, a
`Color` asset). Both of those are re-evaluated against the view's own
appearance every time it draws, which is the property that was missing.

    python3 scripts/appearance_check.py

Exit 1 on a violation, naming the file and line.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "PulseBar" / "Sources" / "PulseBar"

# `static let x = Color(nsColor: …)` and friends: a constant binding whose
# value is read out of the appearance-dependent NSColor catalogue.
FROZEN = re.compile(
    r"^\s*(?:public\s+|private\s+|fileprivate\s+|internal\s+)?"
    r"(?:static\s+)?let\s+\w+[^=\n]*=\s*"
    r"(?:Color\s*\(\s*nsColor\s*:|NSColor\s*\.|Color\s*\(\s*NSColor)"
)

# A template image in an NSStatusBarButton must be resolved by the menu bar's
# own effective appearance. AppKit documents `nil` as the standard adaptive
# rendering path. A fixed content tint also recolors the title and can become
# black-on-black when the menu bar and app resolve different appearances.
FORCED_STATUS_TINT = re.compile(r"\bbutton\.contentTintColor\s*=\s*(\S.*)$")

# Deliberate exceptions, each with a reason. A lamp colour is a brand value
# that must NOT flip with the system theme — red means "needs you" on every
# desktop — so those are fixed on purpose.
ALLOW_SUFFIX = "// appearance-fixed:"


def main() -> int:
    problems: list[str] = []
    scanned = 0
    for path in sorted(SOURCES.rglob("*.swift")):
        scanned += 1
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if ALLOW_SUFFIX in line:
                continue
            if FROZEN.match(line):
                rel = path.relative_to(ROOT)
                problems.append(f"  · {rel}:{n}  {line.strip()}")
            tint_match = FORCED_STATUS_TINT.search(line)
            if (
                path.name == "StatusPanelController.swift"
                and tint_match
                and not tint_match.group(1).startswith("nil")
            ):
                rel = path.relative_to(ROOT)
                problems.append(
                    f"  · {rel}:{n}  forced status-item tint: {line.strip()}"
                )

    # The tray's keyboard target must not use the default blue focus ring. An
    # NSPanel clips that ring at its rounded bounds, leaving what looks like a
    # random blue divider below the Header. Keyboard navigation remains active;
    # only the visual effect is suppressed.
    tray = SOURCES / "PulseApp.swift"
    tray_source = tray.read_text(encoding="utf-8")
    if ".focusable()" in tray_source and ".focusEffectDisabled()" not in tray_source:
        problems.append(
            "  · PulseBar/Sources/PulseBar/PulseApp.swift  "
            "focusable tray is missing .focusEffectDisabled()"
        )

    # The menu-bar lamp is the product's fastest signal. It must remain a
    # full-colour image, and all four user-facing states need an explicit
    # colour mapping. XCTest renders these in light, dark and high-contrast
    # appearances; this source gate still protects package builds on machines
    # whose local XCTest overlay is unavailable.
    brand = (SOURCES / "PulseBrand.swift").read_text(encoding="utf-8")
    lamp_contract = [
        "image.isTemplate = false",
        "case .waiting: return .systemRed",
        "case .running: return .systemGreen",
        "case .stalled, .error: return .systemOrange",
        "case .idle: return .systemGray",
    ]
    for fragment in lamp_contract:
        if fragment not in brand:
            problems.append(
                "  · PulseBar/Sources/PulseBar/PulseBrand.swift  "
                f"missing four-state lamp contract: {fragment}"
            )

    if problems:
        print("appearance contract violation:", file=sys.stderr)
        for p in problems:
            print(p, file=sys.stderr)
        print(
            "\nDo not freeze an appearance-dependent value into a `let`, and\n"
            "leave NSStatusBarButton.contentTintColor nil so the menu bar can\n"
            "resolve template images against its own effective appearance.\n"
            "Read other dynamic colours in `body`, or use Material / .primary / .secondary.\n"
            f"If it is meant to be fixed on every theme, append `{ALLOW_SUFFIX} why`.",
            file=sys.stderr,
        )
        return 1

    print(f"appearance OK — {scanned} sources, no colour frozen into a constant")
    return 0


if __name__ == "__main__":
    sys.exit(main())
