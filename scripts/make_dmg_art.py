#!/usr/bin/env python3
"""Draw the DMG window: its background and the layout that goes with it.

The volume opens to Pulse.app on the left, an arrow, and the /Applications
link on the right, under the Live Lamp (the app icon's ring and running
dot, from `make_brand.py`). Unnotarized builds also carry
"首次打开必读 · Read Me First.txt", placed below the row; its file name is the
instruction, so the picture carries no text (no font is rasterised here, and
Finder draws the item labels itself).

This file is the single source of the window geometry:

    PulseBar/Packaging/DMG/background.png       640 × 400 pt @1x
    PulseBar/Packaging/DMG/background@2x.png    @2x (dmgbuild joins the pair
                                                into one HiDPI TIFF with tiffutil)
    PulseBar/Packaging/DMG/layout.json          window size, icon size and the
                                                item positions settings.py reads

Positions are Finder icon centres in points from the window's top-left.
A notarized build has no guide and opens a shorter window
(`compact_height`): Finder anchors the background at the top-left, so the
lower band is simply cut off — nothing is drawn there.

    python3 scripts/make_dmg_art.py [--check]

`--check` regenerates in memory and fails if a committed file differs
(images by decoded pixels, ±1 per channel). Output is deterministic.
"""
from __future__ import annotations

import argparse
import json
import math
import struct
import sys
import zlib
from pathlib import Path

import make_brand as brand

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = Path("PulseBar/Packaging/DMG")

# --- geometry (points) --------------------------------------------------------

WIDTH, HEIGHT = 640, 400
COMPACT_HEIGHT = 290          # notarized: the row and its labels, no guide
ICON_SIZE = 128
TEXT_SIZE = 13
ROW_Y = 160
APP_X, APPS_X = 170, 470
GUIDE_POS = (320, 306)
GUIDE_NAME = "首次打开必读 · Read Me First.txt"

LAMP_CENTRE = (320.0, 56.0)
LAMP_UNIT = 2.8               # Lamp.draw's 16-unit square → 44.8 pt

# The arrow: a rounded shaft and two rounded strokes for the head, between
# the icons' edges (icon half-width 64 → 234 … 406).
ARROW_HALF = 2.5              # stroke radius
ARROW_X0, ARROW_X1 = 262.0, 378.0
ARROW_HEAD = 15.0             # head stroke length along each axis

BG_TOP = (0xFB, 0xFB, 0xFD)
BG_BOTTOM = (0xF0, 0xF1, 0xF4)
ARROW_COLOR = (0xC4, 0xC7, 0xCE)
RING_COLOR = (0x3A, 0x3D, 0x44)
DOT_COLOR = brand.DOT_COLOR   # running green — never red: red means blocked

SUB = 8  # sub-rows per pixel row


# --- spans --------------------------------------------------------------------


def polygon_span(pts, y):
    """A convex polygon's extent along the line at height y."""
    xs = []
    n = len(pts)
    for i in range(n):
        (x1, y1), (x2, y2) = pts[i], pts[(i + 1) % n]
        if y1 == y2 or not (min(y1, y2) <= y <= max(y1, y2)):
            continue
        xs.append(x1 + (y - y1) * (x2 - x1) / (y2 - y1))
    return [(min(xs), max(xs))] if len(xs) >= 2 else []


def capsule_spans(p0, p1, r, y):
    """A stroked segment with round caps — convex, so one interval."""
    (x0, y0), (x1, y1) = p0, p1
    dx, dy = x1 - x0, y1 - y0
    length = math.hypot(dx, dy)
    nx, ny = -dy / length * r, dx / length * r
    rect = [(x0 + nx, y0 + ny), (x1 + nx, y1 + ny), (x1 - nx, y1 - ny), (x0 - nx, y0 - ny)]
    parts = polygon_span(rect, y) + brand.circle_spans(x0, r, y - y0) + brand.circle_spans(x1, r, y - y1)
    if not parts:
        return []
    return [(min(a for a, _ in parts), max(b for _, b in parts))]


def union(spans):
    out = []
    for a, b in sorted(spans):
        if out and a <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], b))
        else:
            out.append((a, b))
    return out


def arrow_spans(y):
    tip = (ARROW_X1, float(ROW_Y))
    return union(
        capsule_spans((ARROW_X0, ROW_Y), tip, ARROW_HALF, y)
        + capsule_spans(tip, (ARROW_X1 - ARROW_HEAD, ROW_Y - ARROW_HEAD), ARROW_HALF, y)
        + capsule_spans(tip, (ARROW_X1 - ARROW_HEAD, ROW_Y + ARROW_HEAD), ARROW_HALF, y)
    )


def ring_spans(y):
    cx, cy = LAMP_CENTRE
    u = LAMP_UNIT
    return brand.ring_spans(cx, brand.RING_OUTER * u, brand.RING_INNER * u, y - cy)


def dot_spans(y):
    cx, cy = LAMP_CENTRE
    return brand.circle_spans(cx, brand.DOT_RADIUS * LAMP_UNIT, y - cy)


# Each shape with its colour and vertical extent (points), painted in order.
SHAPES = [
    (arrow_spans, ARROW_COLOR, (ROW_Y - ARROW_HEAD - ARROW_HALF, ROW_Y + ARROW_HEAD + ARROW_HALF)),
    (ring_spans, RING_COLOR, (LAMP_CENTRE[1] - brand.RING_OUTER * LAMP_UNIT,
                              LAMP_CENTRE[1] + brand.RING_OUTER * LAMP_UNIT)),
    (dot_spans, DOT_COLOR, (LAMP_CENTRE[1] - brand.DOT_RADIUS * LAMP_UNIT,
                            LAMP_CENTRE[1] + brand.DOT_RADIUS * LAMP_UNIT)),
]


# --- rasteriser ---------------------------------------------------------------


def coverage_row(width, scale, py, span_fn):
    """One pixel row's covered fraction per pixel, exact in x, SUB rows in y."""
    acc = [0.0] * width
    diff = [0] * (width + 1)
    for j in range(SUB):
        y = (py + (j + 0.5) / SUB) / scale
        for a, b in span_fn(y):
            a, b = max(a * scale, 0.0), min(b * scale, float(width))
            if b <= a:
                continue
            ia, ib = int(a), int(b)
            if ia == ib:
                acc[ia] += b - a
                continue
            acc[ia] += ia + 1 - a
            diff[ia + 1] += 1
            diff[ib] -= 1
            if ib < width:
                acc[ib] += b - ib
    out, run = [], 0
    for x in range(width):
        run += diff[x]
        out.append((acc[x] + run) / SUB)
    return out


def render(scale):
    """Opaque RGBA rows of the background at `scale` (1 or 2)."""
    w, h = WIDTH * scale, HEIGHT * scale
    rows = []
    for py in range(h):
        t = (py + 0.5) / h
        bg = [top + (bot - top) * t for top, bot in zip(BG_TOP, BG_BOTTOM)]
        y_pt = (py + 0.5) / scale
        live = [(fn, col) for fn, col, (y0, y1) in SHAPES if y0 - 1 <= y_pt <= y1 + 1]
        if not live:
            rows.append(bytes((round(bg[0]), round(bg[1]), round(bg[2]), 255)) * w)
            continue
        px = [list(bg) for _ in range(w)]
        for fn, col in live:
            cov = coverage_row(w, scale, py, fn)
            for x, c in enumerate(cov):
                if c <= 0.0:
                    continue
                c = min(c, 1.0)
                p = px[x]
                p[0] += (col[0] - p[0]) * c
                p[1] += (col[1] - p[1]) * c
                p[2] += (col[2] - p[2]) * c
        row = bytearray()
        for r, g, b in px:
            row += bytes((round(r), round(g), round(b), 255))
        rows.append(bytes(row))
    return rows


def encode_png(rows, width, dpi) -> bytes:
    raw = b"".join(b"\0" + r for r in rows)
    ppm = round(dpi / 0.0254)
    return (
        b"\x89PNG\r\n\x1a\n"
        + brand.png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, len(rows), 8, 6, 0, 0, 0))
        + brand.png_chunk(b"sRGB", b"\0")
        + brand.png_chunk(b"pHYs", struct.pack(">IIB", ppm, ppm, 1))
        + brand.png_chunk(b"IDAT", zlib.compress(raw, 9))
        + brand.png_chunk(b"IEND", b"")
    )


def layout_json() -> bytes:
    doc = {
        "_generated_by": "scripts/make_dmg_art.py — edit the script, not this file",
        "window": {"width": WIDTH, "height": HEIGHT, "compact_height": COMPACT_HEIGHT},
        "icon_size": ICON_SIZE,
        "text_size": TEXT_SIZE,
        "guide_name": GUIDE_NAME,
        "positions": {
            "Pulse.app": [APP_X, ROW_Y],
            "Applications": [APPS_X, ROW_Y],
            "guide": list(GUIDE_POS),
        },
    }
    return (json.dumps(doc, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()


def build():
    files, pixels = {}, {}
    for name, scale in (("background.png", 1), ("background@2x.png", 2)):
        rows = render(scale)
        path = OUT_DIR / name
        files[path] = encode_png(rows, WIDTH * scale, 72 * scale)
        pixels[path] = (WIDTH * scale, HEIGHT * scale, b"".join(rows))
    files[OUT_DIR / "layout.json"] = layout_json()
    return files, pixels


def differs(path: Path, want: bytes, view) -> str | None:
    disk = ROOT / path
    if not disk.exists():
        return "missing"
    have = disk.read_bytes()
    if have == want:
        return None
    if view is None:
        return "differs"
    try:
        w, h, got = brand.decode_png(have)
    except (ValueError, zlib.error, IndexError, struct.error) as e:
        return f"unreadable ({e})"
    return None if (w, h) == view[:2] and brand.close(got, view[2]) else "pixels differ"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if a committed file differs")
    args = ap.parse_args()
    files, pixels = build()
    if args.check:
        drifted = [(p, why) for p, b in sorted(files.items()) if (why := differs(p, b, pixels.get(p)))]
        if drifted:
            print("DMG art differs from its generator:", file=sys.stderr)
            for p, why in drifted:
                print(f"  · {p} — {why}", file=sys.stderr)
            print("run: python3 scripts/make_dmg_art.py", file=sys.stderr)
            return 1
        print(f"DMG art OK — {len(files)} files match scripts/make_dmg_art.py")
        return 0
    for p, b in sorted(files.items()):
        out = ROOT / p
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(b)
        print(f"wrote {p} ({len(b)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
