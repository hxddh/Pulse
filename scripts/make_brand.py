#!/usr/bin/env python3
"""Draw Pulse's brand: the app icon ("Live Lamp") and the empty-tray mark.

The app icon *is* the running lamp — the same ring and centre dot the menu
bar draws (`Lamp.draw` in `PulseApp/PulseTheme.swift`, a 16-unit square:
ring rect (2.5, 2.5, 11, 11) stroked 1.6 inward, dot rect (6, 6, 4, 4)) —
in light grey and green on a dark macOS squircle. No red: red means blocked.

This file is the single source of the geometry. Like
`make_agent_icons.py`, no binary arrives without the code that drew it:

    PulseBar/Packaging/Brand/pulse-icon.svg        the icon, as a vector source
    PulseBar/Packaging/Brand/pulse-mark.svg        the template mark
    PulseBar/Packaging/Pulse.icon/                 Icon Composer layers + icon.json
    PulseBar/Packaging/AppIcon.icns                legacy icon (CFBundleIconFile)
    PulseBar/Sources/PulseApp/Resources/Brand/pulse-mark{,@2x}.png   template, 32 / 64 px

`Pulse.icon/icon.json` follows the Icon Composer bundle layout as far as it
is known here; its schema is UNVERIFIED — open it in Icon Composer (or run
`xcrun actool`) on macOS 26 before relying on it, and let Icon Composer
rewrite it if it disagrees.

The rasteriser is exact in x and supersampled in y: each pixel row is cut
into SUB sub-rows, every shape is an analytic span per sub-row (circles by
sqrt, the squircle's corners by a superellipse), and a span's horizontal
overlap with each pixel is computed exactly. Output is deterministic.

The AppIcon.icns is packed here as iconutil packs it: ARGB (icns RLE) for
the 16 / 32 px `ic04` / `ic05`, PNG for every other size.

    python3 scripts/make_brand.py [--check]

`--check` regenerates in memory and fails if a committed file differs. Text
files are compared byte for byte; images by their decoded pixels (±1 per
channel), because zlib builds may compress the same pixels differently.
"""
from __future__ import annotations

import argparse
import json
import math
import struct
import sys
import time
import zlib
from itertools import accumulate
from pathlib import Path

# --- geometry: the one description of the brand ------------------------------

CANVAS = 1024.0

# The macOS icon body (Big Sur grid): an 824 square at 100, corner ≈185.
BODY_ORIGIN = 100.0
BODY_SIZE = 824.0
BODY_RADIUS = 185.0
# Continuous corner: instead of a quarter circle of radius r, each corner is
# a quarter superellipse that starts 1.528 r along each edge (Apple's
# continuous-corner extent). Its exponent is chosen so the curve crosses the
# 45° diagonal where the circular corner would — same visual weight, but the
# curvature eases in from zero at the straight edge (G2) instead of jumping.
CORNER_EXTENT = 1.528 * BODY_RADIUS
CORNER_EXPONENT = math.log(2) / -math.log(1 - BODY_RADIUS * (1 - math.sqrt(0.5)) / CORNER_EXTENT)

GRADIENT_TOP = (0x2A, 0x2E, 0x35)
GRADIENT_BOTTOM = (0x12, 0x14, 0x18)
RING_COLOR = (0xF2, 0xF2, 0xF5)
DOT_COLOR = (0x34, 0xC7, 0x59)  # running green

# The lamp, in Lamp.draw's 16-unit square.
LAMP_VIEW = 16.0
LAMP_CENTRE = 8.0
RING_OUTER = 5.5               # circle rect (2.5, 2.5, 11, 11)
RING_STROKE = 1.6              # stroked inside the rect
RING_INNER = RING_OUTER - RING_STROKE
DOT_RADIUS = 2.0               # dot rect (6, 6, 4, 4)

# On the icon the lamp unit is 52 px, centred on the canvas.
ICON_UNIT = 52.0
ICON_CENTRE = CANVAS / 2

SUB = 16  # sub-rows per pixel row

ROOT = Path(__file__).resolve().parent.parent
BRAND_DIR = Path("PulseBar/Packaging/Brand")
ICON_BUNDLE = Path("PulseBar/Packaging/Pulse.icon")
ICNS_PATH = Path("PulseBar/Packaging/AppIcon.icns")
MARK_DIR = Path("PulseBar/Sources/PulseApp/Resources/Brand")
MARK_SIZES = {"pulse-mark.png": 32, "pulse-mark@2x.png": 64}

# OSType → pixel size, in the order iconutil writes them. ic11..ic14 and
# ic10 are the @2x variants: ic11 = 16@2x (32 px), ic12 = 32@2x (64 px),
# ic13 = 128@2x (256 px), ic14 = 256@2x (512 px), ic10 = 512@2x (1024 px).
ICNS_TYPES = [
    (b"ic12", 64), (b"ic07", 128), (b"ic13", 256), (b"ic08", 256), (b"ic04", 16),
    (b"ic14", 512), (b"ic09", 512), (b"ic05", 32), (b"ic10", 1024), (b"ic11", 32),
]
ARGB_TYPES = {b"ic04", b"ic05"}


# --- spans: a shape's extent along one horizontal line -----------------------


def circle_spans(cx, r, dy):
    if abs(dy) >= r:
        return []
    h = math.sqrt(r * r - dy * dy)
    return [(cx - h, cx + h)]


def ring_spans(cx, outer, inner, dy):
    if abs(dy) >= outer:
        return []
    ho = math.sqrt(outer * outer - dy * dy)
    if abs(dy) >= inner:
        return [(cx - ho, cx + ho)]
    hi = math.sqrt(inner * inner - dy * dy)
    return [(cx - ho, cx - hi), (cx + hi, cx + ho)]


def body_spans(y):
    """The squircle's span at canvas height y."""
    y0, y1 = BODY_ORIGIN, BODY_ORIGIN + BODY_SIZE
    if y <= y0 or y >= y1:
        return []
    ext, n = CORNER_EXTENT, CORNER_EXPONENT
    if y < y0 + ext:
        t = (y0 + ext - y) / ext
    elif y > y1 - ext:
        t = (y - (y1 - ext)) / ext
    else:
        return [(y0, y1)]
    inset = ext - ext * (1 - t ** n) ** (1 / n)
    return [(y0 + inset, y1 - inset)]


# --- rasteriser --------------------------------------------------------------


def coverage_rows(size, view, span_fn):
    """Per pixel row, the covered fraction of each pixel.

    `span_fn(y)` gives the spans at view-space height y (in view units).
    """
    scale = size / view
    rows = []
    for py in range(size):
        acc = [0.0] * size
        diff = [0] * (size + 1)
        for j in range(SUB):
            y = (py + (j + 0.5) / SUB) / scale
            for a, b in span_fn(y):
                a, b = max(a * scale, 0.0), min(b * scale, float(size))
                if b <= a:
                    continue
                ia, ib = int(a), int(b)
                if ia == ib:
                    acc[ia] += b - a
                    continue
                acc[ia] += ia + 1 - a
                diff[ia + 1] += 1
                diff[ib] -= 1
                if ib < size:
                    acc[ib] += b - ib
        rows.append([(p + f) / SUB for p, f in zip(acc, accumulate(diff))])
    return rows


def icon_lamp_ring(y):
    u = ICON_UNIT
    return ring_spans(ICON_CENTRE, RING_OUTER * u, RING_INNER * u, y - ICON_CENTRE)


def icon_lamp_dot(y):
    return circle_spans(ICON_CENTRE, DOT_RADIUS * ICON_UNIT, y - ICON_CENTRE)


def render_icon(size):
    """Straight-alpha RGBA rows of the app icon at `size` px."""
    body = coverage_rows(size, CANVAS, body_spans)
    ring = coverage_rows(size, CANVAS, icon_lamp_ring)
    dot = coverage_rows(size, CANVAS, icon_lamp_dot)
    scale = size / CANVAS
    rr, rg, rb = RING_COLOR
    dr, dg, db = DOT_COLOR
    out = []
    for py in range(size):
        t = ((py + 0.5) / scale - BODY_ORIGIN) / BODY_SIZE
        t = min(max(t, 0.0), 1.0)
        br, bg, bb = (top + (bot - top) * t for top, bot in zip(GRADIENT_TOP, GRADIENT_BOTTOM))
        row = bytearray()
        for s, k, m in zip(body[py], ring[py], dot[py]):
            if s <= 0.0:
                row += b"\0\0\0\0"
                continue
            # Premultiplied "over": body, then ring, then dot.
            a, r, g, b = s, br * s, bg * s, bb * s
            if k > 0.0:
                a, r, g, b = k + a * (1 - k), rr * k + r * (1 - k), rg * k + g * (1 - k), rb * k + b * (1 - k)
            if m > 0.0:
                a, r, g, b = m + a * (1 - m), dr * m + r * (1 - m), dg * m + g * (1 - m), db * m + b * (1 - m)
            row += bytes((round(r / a), round(g / a), round(b / a), round(a * 255)))
        out.append(bytes(row))
    return out


def render_mark(size):
    """Black template rows: the lamp's ring and dot, alpha only."""
    def lamp(y):
        dy = y - LAMP_CENTRE
        return ring_spans(LAMP_CENTRE, RING_OUTER, RING_INNER, dy) + circle_spans(LAMP_CENTRE, DOT_RADIUS, dy)

    out = []
    for cov in coverage_rows(size, LAMP_VIEW, lamp):
        row = bytearray()
        for c in cov:
            row += bytes((0, 0, 0, round(min(c, 1.0) * 255)))
        out.append(bytes(row))
    return out


# --- PNG and icns ------------------------------------------------------------


def png_chunk(tag: bytes, payload: bytes) -> bytes:
    body = tag + payload
    return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))


def encode_png(rows, srgb: bool) -> bytes:
    size = len(rows)
    raw = b"".join(b"\0" + r for r in rows)  # filter type 0 on every row
    return (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
        + (png_chunk(b"sRGB", b"\0") if srgb else b"")
        + png_chunk(b"IDAT", zlib.compress(raw, 9))
        + png_chunk(b"IEND", b"")
    )


def decode_png(data: bytes):
    """(width, height, raw RGBA bytes) of a PNG this file wrote (8-bit RGBA)."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, w, h = 8, b"", 0, 0
    while pos < len(data):
        n = struct.unpack(">I", data[pos:pos + 4])[0]
        tag, payload = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + n]
        if tag == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", payload[:10])
            if (depth, ctype) != (8, 6):
                raise ValueError("not 8-bit RGBA")
        elif tag == b"IDAT":
            idat += payload
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = w * 4 + 1
    pixels = bytearray()
    prev = bytearray(w * 4)
    for y in range(h):
        f, line = raw[y * stride], bytearray(raw[y * stride + 1:(y + 1) * stride])
        for i in range(len(line)):
            left = line[i - 4] if i >= 4 else 0
            up, ul = prev[i], prev[i - 4] if i >= 4 else 0
            if f == 1:
                line[i] = (line[i] + left) & 255
            elif f == 2:
                line[i] = (line[i] + up) & 255
            elif f == 3:
                line[i] = (line[i] + (left + up) // 2) & 255
            elif f == 4:
                p = left + up - ul
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - ul)
                line[i] = (line[i] + (left if pa <= pb and pa <= pc else up if pb <= pc else ul)) & 255
        pixels += line
        prev = line
    return w, h, bytes(pixels)


def icns_rle(plane: bytes) -> bytes:
    """The icns RLE (as for is32 / ARGB): runs of 3..130, literals of 1..128."""
    out, i, n = bytearray(), 0, len(plane)
    lit = bytearray()

    def flush():
        while lit:
            part = lit[:128]
            out.append(len(part) - 1)
            out.extend(part)
            del lit[:128]

    while i < n:
        run = 1
        while i + run < n and run < 130 and plane[i + run] == plane[i]:
            run += 1
        if run >= 3:
            flush()
            out += bytes((0x80 + run - 3, plane[i]))
            i += run
        else:
            lit.append(plane[i])
            i += 1
    flush()
    return bytes(out)


def icns_unrle(data: bytes, count: int):
    out, i = bytearray(), 0
    while len(out) < count:
        c = data[i]
        i += 1
        if c < 0x80:
            out += data[i:i + c + 1]
            i += c + 1
        else:
            out += bytes([data[i]]) * (c - 125)
            i += 1
    return bytes(out[:count]), i


def encode_argb(rows) -> bytes:
    flat = b"".join(rows)
    planes = [flat[c::4] for c in (3, 0, 1, 2)]  # A, R, G, B
    return b"ARGB" + b"".join(icns_rle(p) for p in planes)


def decode_argb(data: bytes, size: int) -> bytes:
    if data[:4] != b"ARGB":
        raise ValueError("not ARGB")
    pos, planes = 4, []
    for _ in range(4):
        plane, used = icns_unrle(data[pos:], size * size)
        planes.append(plane)
        pos += used
    a, r, g, b = planes
    return bytes(v for px in zip(r, g, b, a) for v in px)


def pack_icns(chunks) -> bytes:
    body = b"".join(t + struct.pack(">I", len(d) + 8) + d for t, d in chunks)
    return b"icns" + struct.pack(">I", len(body) + 8) + body


def parse_icns(data: bytes):
    if data[:4] != b"icns" or struct.unpack(">I", data[4:8])[0] != len(data):
        raise ValueError("bad icns header")
    pos, chunks = 8, []
    while pos < len(data):
        tag, n = data[pos:pos + 4], struct.unpack(">I", data[pos + 4:pos + 8])[0]
        chunks.append((tag, data[pos + 8:pos + n]))
        pos += n
    return chunks


def icns_pixels(tag: bytes, payload: bytes, size: int) -> bytes:
    if tag in ARGB_TYPES:
        return decode_argb(payload, size)
    w, h, px = decode_png(payload)
    if (w, h) != (size, size):
        raise ValueError(f"{tag.decode()} is {w}x{h}, expected {size}")
    return px


# --- SVG sources -------------------------------------------------------------


def fmt(v: float) -> str:
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s == "-0" else s


def body_path(segments=32) -> str:
    """The squircle as a path: straight edges and sampled superellipse corners."""
    x0, x1 = BODY_ORIGIN, BODY_ORIGIN + BODY_SIZE
    ext, n = CORNER_EXTENT, CORNER_EXPONENT

    def corner(cx, cy, sx, sy, clockwise_from):
        # Points of |u|^n + |v|^n = 1 from angle param, centre (cx, cy), quadrant (sx, sy).
        pts = []
        for i in range(segments + 1):
            th = (math.pi / 2) * i / segments
            c, s = math.cos(th), math.sin(th)
            u, v = c ** (2 / n), s ** (2 / n)
            pts.append((cx + sx * ext * u, cy + sy * ext * v))
        return pts if clockwise_from else pts[::-1]

    pts = []
    # Clockwise from the top edge: top-right, bottom-right, bottom-left, top-left.
    pts += corner(x1 - ext, x0 + ext, 1, -1, False)
    pts += corner(x1 - ext, x1 - ext, 1, 1, True)
    pts += corner(x0 + ext, x1 - ext, -1, 1, False)
    pts += corner(x0 + ext, x0 + ext, -1, -1, True)
    head, *rest = pts
    return f"M{fmt(head[0])} {fmt(head[1])}" + "".join(f"L{fmt(x)} {fmt(y)}" for x, y in rest) + "Z"


def hexcolor(c) -> str:
    return "#%02X%02X%02X" % c


def svg(view: float, body: str, note: str) -> bytes:
    v = fmt(view)
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>\n'
        f"<!-- {note} Generated by scripts/make_brand.py; edit the script, not this file. -->\n"
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{v}" height="{v}" viewBox="0 0 {v} {v}">\n'
        f"{body}</svg>\n"
    ).encode()


def gradient_def(y0: float, y1: float) -> str:
    return (
        f'  <defs><linearGradient id="bg" gradientUnits="userSpaceOnUse" x1="0" y1="{fmt(y0)}" x2="0" y2="{fmt(y1)}">'
        f'<stop offset="0" stop-color="{hexcolor(GRADIENT_TOP)}"/>'
        f'<stop offset="1" stop-color="{hexcolor(GRADIENT_BOTTOM)}"/></linearGradient></defs>\n'
    )


def ring_svg(c: float, unit: float, color: str) -> str:
    mid = (RING_OUTER + RING_INNER) / 2 * unit
    return (
        f'  <circle cx="{fmt(c)}" cy="{fmt(c)}" r="{fmt(mid)}" fill="none" '
        f'stroke="{color}" stroke-width="{fmt(RING_STROKE * unit)}"/>\n'
    )


def dot_svg(c: float, unit: float, color: str) -> str:
    return f'  <circle cx="{fmt(c)}" cy="{fmt(c)}" r="{fmt(DOT_RADIUS * unit)}" fill="{color}"/>\n'


def svg_files():
    c, u = ICON_CENTRE, ICON_UNIT
    ring_c, dot_c = hexcolor(RING_COLOR), hexcolor(DOT_COLOR)
    y0, y1 = BODY_ORIGIN, BODY_ORIGIN + BODY_SIZE
    files = {
        BRAND_DIR / "pulse-icon.svg": svg(
            CANVAS,
            gradient_def(y0, y1) + f'  <path d="{body_path()}" fill="url(#bg)"/>\n'
            + ring_svg(c, u, ring_c) + dot_svg(c, u, dot_c),
            "Pulse app icon (Live Lamp), 1024 canvas, macOS squircle body.",
        ),
        BRAND_DIR / "pulse-mark.svg": svg(
            LAMP_VIEW,
            ring_svg(LAMP_CENTRE, 1, "#000000") + dot_svg(LAMP_CENTRE, 1, "#000000"),
            "Pulse template mark: Lamp.draw's 16-unit lamp, ring and centre dot.",
        ),
        # Icon Composer layers: full-bleed, unmasked — the system applies the
        # shape, the glass and the shadow.
        ICON_BUNDLE / "Assets/background.svg": svg(
            CANVAS,
            gradient_def(0, CANVAS) + f'  <rect width="{fmt(CANVAS)}" height="{fmt(CANVAS)}" fill="url(#bg)"/>\n',
            "Icon Composer layer: background gradient (full bleed; the system masks it).",
        ),
        ICON_BUNDLE / "Assets/ring.svg": svg(CANVAS, ring_svg(c, u, ring_c), "Icon Composer layer: the lamp's ring."),
        ICON_BUNDLE / "Assets/dot.svg": svg(CANVAS, dot_svg(c, u, dot_c), "Icon Composer layer: the running dot."),
    }
    return files


def icon_json() -> bytes:
    """Best-effort Icon Composer document. UNVERIFIED schema — see module doc."""
    doc = {
        "groups": [
            {"name": "Lamp", "layers": [
                {"name": "dot", "image-name": "dot.svg", "glass": True},
                {"name": "ring", "image-name": "ring.svg", "glass": True},
            ], "shadow": {"kind": "neutral", "opacity": 0.5}},
            {"name": "Background", "layers": [
                {"name": "background", "image-name": "background.svg", "glass": False},
            ]},
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }
    return (json.dumps(doc, indent=2, sort_keys=True) + "\n").encode()


# --- outputs -----------------------------------------------------------------


def build():
    """Every output as {path: bytes}, plus pixel views of the images."""
    files = {p: b for p, b in svg_files().items()}
    files[ICON_BUNDLE / "icon.json"] = icon_json()

    pixels = {}
    rendered = {}
    for tag, size in ICNS_TYPES:
        if size not in rendered:
            rendered[size] = render_icon(size)
    chunks = []
    for tag, size in ICNS_TYPES:
        rows = rendered[size]
        chunks.append((tag, encode_argb(rows) if tag in ARGB_TYPES else encode_png(rows, srgb=True)))
    files[ICNS_PATH] = pack_icns(chunks)
    pixels[ICNS_PATH] = [(tag, size, b"".join(rendered[size])) for tag, size in ICNS_TYPES]

    for name, size in MARK_SIZES.items():
        rows = render_mark(size)
        files[MARK_DIR / name] = encode_png(rows, srgb=False)
        pixels[MARK_DIR / name] = [(None, size, b"".join(rows))]
    return files, pixels


def close(a: bytes, b: bytes) -> bool:
    return len(a) == len(b) and all(abs(x - y) <= 1 for x, y in zip(a, b))


def differs(path: Path, want: bytes, views) -> str | None:
    disk = ROOT / path
    if not disk.exists():
        return "missing"
    have = disk.read_bytes()
    if have == want:
        return None
    if views is None:
        return "differs"
    try:
        if path.suffix == ".icns":
            chunks = parse_icns(have)
            if [t for t, _ in chunks] != [t for t, _, _ in views]:
                return "icns chunk table differs"
            for (tag, payload), (_, size, px) in zip(chunks, views):
                if not close(icns_pixels(tag, payload, size), px):
                    return f"{tag.decode()} pixels differ"
            return None
        (_, size, px), = views
        w, h, got = decode_png(have)
        return None if (w, h) == (size, size) and close(got, px) else "pixels differ"
    except (ValueError, zlib.error, IndexError, struct.error) as e:
        return f"unreadable ({e})"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if a committed file differs")
    args = ap.parse_args()

    start = time.monotonic()
    files, pixels = build()

    if args.check:
        drifted = [(p, why) for p, b in sorted(files.items()) if (why := differs(p, b, pixels.get(p)))]
        if drifted:
            print("brand files differ from their generator:", file=sys.stderr)
            for p, why in drifted:
                print(f"  · {p} — {why}", file=sys.stderr)
            print("run: python3 scripts/make_brand.py", file=sys.stderr)
            return 1
        print(f"brand OK — {len(files)} files match scripts/make_brand.py ({time.monotonic() - start:.1f}s)")
        return 0

    for p, b in sorted(files.items()):
        out = ROOT / p
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(b)
        print(f"wrote {p} ({len(b)} bytes)")
    print(f"done in {time.monotonic() - start:.1f}s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
