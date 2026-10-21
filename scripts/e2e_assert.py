#!/usr/bin/env python3
"""Assertions for scripts/e2e.sh — kept out of the shell so each says what
it checked.

    e2e_assert.py line <events.tsv> <lines-before> <expected>
        exactly one line was appended, and it is <expected>: a v9 kind, or
        ignored:<why> (PulseBar/Tests/Fixtures/hooks/expected.json's words)
    e2e_assert.py expected <expected.json> <agent/event[@variant]>
        print what that fixture becomes
    e2e_assert.py count <events.tsv>
        print how many lines the log holds
    e2e_assert.py snapshot <snapshot.json> <phase> <agent>
        phase blocked  — the lamp is red, one row of <agent> needs you, and
                         its wait has one banner (posted, or held because
                         its prompt was in front)
        phase answered — nothing needs you, the row runs again, and no
                         banner is open (a posted one was withdrawn)
        phase ended    — no row of <agent> is live: it ended
"""
from __future__ import annotations

import json
import sys
from pathlib import Path


def lines(path: Path) -> list[list[str]]:
    if not path.exists():
        return []
    out = []
    for raw in path.read_text(encoding="utf-8", errors="replace").split("\n"):
        cols = raw.split("\t")
        # A record has seventeen columns and starts with its seq; the header
        # does not.
        if len(cols) == 17 and cols[0].isdigit():
            out.append(cols)
    return out


def fail(message: str) -> int:
    print(f"e2e FAIL {message}")
    return 1


def check_line(path: Path, before: int, expected: str) -> int:
    records = lines(path)
    if len(records) != before + 1:
        return fail(f"{len(records) - before} lines appended, expected 1 ({path})")
    cols = records[-1]
    kind, message = cols[3], cols[16]
    got = f"ignored:{message}" if kind == "ignored" else kind
    if got != expected:
        return fail(f"line is {got!r}, expected {expected!r} (event {cols[4]})")
    return 0


def check_snapshot(path: Path, phase: str, agent: str) -> int:
    snap = json.loads(path.read_text(encoding="utf-8"))
    rows = [r for r in snap["rows"] if r["agent"] == agent]
    banners = snap["banners"]
    shown = json.dumps({k: snap[k] for k in ("lamp", "counts", "banners")}, sort_keys=True)
    live = [r for r in rows if r["status"] in ("needsYou", "running", "stalled", "yourTurn")]
    if phase == "blocked":
        waiting = [r for r in rows if r["status"] == "needsYou"]
        if snap["lamp"] != "waiting":
            return fail(f"blocked: the lamp is {snap['lamp']!r}, expected red (waiting) — {shown}")
        if len(waiting) != 1:
            return fail(f"blocked: {len(waiting)} {agent} rows need you, expected 1 — {rows}")
        mine = [b for b in banners["planned"] + banners["deferred"] if b.startswith(f"pulse-waiting-{agent}-")]
        if len(mine) != 1:
            return fail(f"blocked: {len(mine)} banners for {agent}'s wait, expected 1 — {shown}")
        if mine[0] in banners["planned"] and mine[0] not in banners["open"]:
            return fail(f"blocked: the posted banner is not open — {shown}")
    elif phase == "answered":
        if snap["counts"]["blocked"] != 0:
            return fail(f"answered: {snap['counts']['blocked']} rows still need you — {shown}")
        if not any(r["status"] == "running" for r in rows):
            return fail(f"answered: the {agent} row is not running again — {rows}")
        if banners["open"]:
            return fail(f"answered: banners still open {banners['open']} — {shown}")
        for posted in banners["planned"]:
            if posted not in banners["withdrawn"]:
                return fail(f"answered: banner {posted} was never withdrawn — {shown}")
    elif phase == "ended":
        if live:
            return fail(f"ended: {agent} rows are still live — {live}")
        if rows and not all(r.get("reason") == "ended" for r in rows):
            return fail(f"ended: {agent} rows left for another reason — {rows}")
    else:
        return fail(f"unknown phase {phase}")
    print(f"e2e ok   {agent} {phase}: lamp={snap['lamp']} rows={[r['status'] for r in rows]}")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) >= 1 and argv[0] == "line" and len(argv) == 4:
        return check_line(Path(argv[1]), int(argv[2]), argv[3])
    if len(argv) >= 1 and argv[0] == "expected" and len(argv) == 3:
        expected = json.loads(Path(argv[1]).read_text(encoding="utf-8"))["expected"]
        if argv[2] not in expected:
            return fail(f"no expectation for {argv[2]}")
        print(expected[argv[2]])
        return 0
    if len(argv) >= 1 and argv[0] == "count" and len(argv) == 2:
        print(len(lines(Path(argv[1]))))
        return 0
    if len(argv) >= 1 and argv[0] == "snapshot" and len(argv) == 4:
        return check_snapshot(Path(argv[1]), argv[2], argv[3])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
