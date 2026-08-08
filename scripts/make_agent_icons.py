#!/usr/bin/env python3
"""Generate the agent marks Pulse draws for tools that have no bundled logo.

Ten of the thirty-two agents fell back to a two-letter monogram, so a tray with
Droid and Command Code in it showed "Dr" and "CC" beside real brand marks —
different weight, different shape language, visibly unfinished.

These are **Pulse's own glyphs, not the vendors' trademarks.** They are drawn
here rather than copied so that the file you are reading is the source: no
binary arrives in the repository without the code that produced it, and a
change to a mark is a diff you can read.

The app loads them as template images, so only the alpha channel is used — the
rasteriser below therefore computes coverage and writes black pixels with that
coverage as alpha. Coordinates are in the same 24×24 space as the bundled
Simple Icons SVGs; output is 64×64 PNG to match, which is 2× the 16pt the row
draws at. No `.svg` is written: the loader prefers the PNG, and an SVG that
merely wrapped it would render blank if the PNG ever went missing — an
invisible icon is worse than the monogram fallback.

    python3 scripts/make_agent_icons.py [--check]

`--check` regenerates into memory and fails if anything on disk differs, so the
committed art cannot drift away from this description of it.
"""
from __future__ import annotations

import argparse
import re
import struct
import sys
import zlib
from pathlib import Path

ICON_DIR = Path("PulseBar/Sources/PulseBar/Resources/AgentIcons")
VIEW = 24.0
SIZE = 64
SUPERSAMPLE = 4

# --- geometry helpers, all in the 24×24 space -------------------------------


def circle(cx, cy, r):
    return lambda x, y: (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def ring(cx, cy, outer, inner):
    return lambda x, y: inner * inner < (x - cx) ** 2 + (y - cy) ** 2 <= outer * outer


def rect(x0, y0, x1, y1):
    return lambda x, y: x0 <= x <= x1 and y0 <= y <= y1


def rounded(x0, y0, x1, y1, r):
    def inside(x, y):
        if not (x0 <= x <= x1 and y0 <= y <= y1):
            return False
        cx = min(max(x, x0 + r), x1 - r)
        cy = min(max(y, y0 + r), y1 - r)
        return (x - cx) ** 2 + (y - cy) ** 2 <= r * r or (x0 + r <= x <= x1 - r) or (y0 + r <= y <= y1 - r)

    return inside


def polygon(points):
    def inside(x, y):
        hit = False
        n = len(points)
        for i in range(n):
            xi, yi = points[i]
            xj, yj = points[(i - 1) % n]
            if (yi > y) != (yj > y):
                cross = (xj - xi) * (y - yi) / (yj - yi) + xi
                if x < cross:
                    hit = not hit
        return hit

    return inside


def union(*shapes):
    return lambda x, y: any(s(x, y) for s in shapes)


def without(base, *holes):
    return lambda x, y: base(x, y) and not any(h(x, y) for h in holes)


def bar(x0, y0, x1, y1, weight):
    """A thick line segment, drawn as a capsule."""
    def inside(x, y):
        dx, dy = x1 - x0, y1 - y0
        span = dx * dx + dy * dy
        t = 0.0 if span == 0 else max(0.0, min(1.0, ((x - x0) * dx + (y - y0) * dy) / span))
        px, py = x0 + t * dx, y0 + t * dy
        return (x - px) ** 2 + (y - py) ** 2 <= (weight / 2) ** 2

    return inside


# --- the marks --------------------------------------------------------------
#
# Each is chosen to be unmistakable at 16pt and unlike every other silhouette
# in the roster — that is the whole job of a row icon.

ICONS = {
    # A sail on a mast, over the board.
    "windsurf": union(
        polygon([(11.0, 2.5), (20.5, 17.0), (11.0, 17.0)]),
        bar(10.2, 2.5, 10.2, 18.5, 1.7),
        bar(3.0, 20.8, 21.0, 20.8, 1.7),
    ),
    # A solid hexagon.
    "devin": polygon([(12, 2.5), (20, 7.2), (20, 16.8), (12, 21.5), (4, 16.8), (4, 7.2)]),
    # A hollow diamond.
    "kiro": without(
        polygon([(12, 2.5), (21.5, 12), (12, 21.5), (2.5, 12)]),
        polygon([(12, 7.5), (16.5, 12), (12, 16.5), (7.5, 12)]),
    ),
    # A hook, like the tail of a J.
    "junie": union(
        bar(16.0, 3.0, 16.0, 14.0, 3.0),
        without(ring(11.0, 14.0, 6.5, 3.5), rect(11.0, 6.0, 24.0, 14.0)),
    ),
    # Three bars, stepping down.
    "kilo": union(
        bar(4.0, 6.5, 20.0, 6.5, 3.0),
        bar(4.0, 12.0, 15.0, 12.0, 3.0),
        bar(4.0, 17.5, 10.0, 17.5, 3.0),
    ),
    # Three offset tiles.
    "replit": union(
        rect(4.0, 3.5, 12.0, 10.0),
        rect(12.0, 10.0, 20.0, 16.5),
        rect(4.0, 16.5, 12.0, 20.5),
    ),
    # A head with an antenna.
    "droid": union(
        bar(12.0, 2.0, 12.0, 6.0, 1.4),
        without(
            rounded(4.5, 6.0, 19.5, 19.0, 4.0),
            circle(9.0, 12.0, 1.8),
            circle(15.0, 12.0, 1.8),
        ),
    ),
    # A shell prompt: chevron and caret line.
    "command_code": union(
        bar(5.0, 6.0, 11.0, 12.0, 2.6),
        bar(11.0, 12.0, 5.0, 18.0, 2.6),
        bar(13.0, 18.0, 20.0, 18.0, 2.6),
    ),
    # An arrow rising out of a bowl — leaving the well, not orbiting it.
    "antigravity": union(
        without(ring(12, 11.5, 9.5, 7.4), rect(0.0, 0.0, 24.0, 11.5)),
        bar(12.0, 19.5, 12.0, 9.5, 2.6),
        polygon([(12, 2.8), (17.6, 10.0), (6.4, 10.0)]),
    ),
    # A crescent.
    "kimi": without(circle(12, 12, 9.5), circle(15.8, 9.6, 8.4)),
    # A bold Z zig-zag — Z.ai ZCode ADE.
    "zcode": union(
        bar(5.0, 5.0, 19.0, 5.0, 2.8),
        bar(19.0, 5.0, 5.0, 19.0, 2.8),
        bar(5.0, 19.0, 19.0, 19.0, 2.8),
    ),
}


# --- rasteriser and PNG writer ----------------------------------------------


def coverage(shape, px, py):
    """Fraction of the pixel covered, by supersampling."""
    hits = 0
    step = 1.0 / SUPERSAMPLE
    scale = VIEW / SIZE
    for sy in range(SUPERSAMPLE):
        for sx in range(SUPERSAMPLE):
            x = (px + (sx + 0.5) * step) * scale
            y = (py + (sy + 0.5) * step) * scale
            if shape(x, y):
                hits += 1
    return hits / (SUPERSAMPLE * SUPERSAMPLE)


def render(shape) -> bytes:
    rows = []
    for py in range(SIZE):
        row = bytearray([0])  # filter type 0
        for px in range(SIZE):
            a = int(round(coverage(shape, px, py) * 255))
            row += bytes((0, 0, 0, a))
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(tag: bytes, payload: bytes) -> bytes:
        body = tag + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def roster(root: Path) -> list[str]:
    """Asset names for every `AgentID`, which is the raw value in every case."""
    text = (root / "PulseBar/Sources/PulseBar/Models.swift").read_text(encoding="utf-8")
    block = re.search(r"enum AgentID[^{]*\{(.*?)\n\n", text, re.S)
    names = []
    for line in block.group(1).splitlines() if block else []:
        line = line.strip()
        if not line.startswith("case "):
            continue
        for part in line[len("case "):].split(","):
            part = part.strip()
            if not part:
                continue
            m = re.match(r'\w+\s*=\s*"([a-z0-9_]+)"', part)
            names.append(m.group(1) if m else part.rstrip("_"))
    return names


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if the committed art differs")
    args = ap.parse_args()

    root = Path(__file__).resolve().parent.parent
    out = root / ICON_DIR
    out.mkdir(parents=True, exist_ok=True)

    drifted = []
    for name, shape in sorted(ICONS.items()):
        png = render(shape)
        png_path = out / f"{name}.png"
        if args.check:
            if not png_path.exists() or png_path.read_bytes() != png:
                drifted.append(png_path.name)
        else:
            png_path.write_bytes(png)

    if not args.check:
        print(f"wrote {len(ICONS)} marks to {ICON_DIR}")
        return 0

    if drifted:
        print("agent icons differ from their generator:", file=sys.stderr)
        for d in drifted:
            print(f"  · {d}", file=sys.stderr)
        print("run: python3 scripts/make_agent_icons.py", file=sys.stderr)
        return 1

    # The reason this gate exists at all: an agent added without a mark falls
    # back to a two-letter monogram, which looks like a placeholder next to
    # every real icon — and nothing fails until someone opens the tray.
    ids = roster(root)
    bare = [n for n in ids if not (out / f"{n}.png").exists()]
    if bare:
        print("AgentID with no icon (would render as a monogram):", file=sys.stderr)
        for n in bare:
            print(f"  · {n}", file=sys.stderr)
        print("add art, or a shape to ICONS in this file", file=sys.stderr)
        return 1

    print(f"agent icons OK — {len(ids)} agents, all with art; {len(ICONS)} of them generated here")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
