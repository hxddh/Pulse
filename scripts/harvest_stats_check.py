#!/usr/bin/env python3
"""Gate: the harvest actually emits the two universal session facts.

Measured on 0.27.2, before this existed: of 32 harvesters, 5 produced token
counts and 5 produced a tool name. **Twenty-six produced nothing that changes
while work happens** — their rows could only ever say a session title and a
path, both fixed for the session's entire life, so a session at minute forty
looked identical to the same session at minute one. The panel was not
under-designed; it had nothing to show.

`turns` and `started_ms` are the two facts any file-backed session can answer.
This gate builds a synthetic session tree, runs the real harvester against it,
and asserts the columns arrive populated — the part that a Swift unit test
cannot reach, because it lives in Python and in the file system.

    python3 scripts/harvest_stats_check.py

Exit 1 if the wire format loses a column, if the stats stop being computed, or
if a legacy row stops parsing.
"""
from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

import activity_scan as A  # noqa: E402

COLUMNS = 14


def fail(msg: str) -> int:
    print(f"harvest stats FAILED: {msg}", file=sys.stderr)
    return 1


def emit_to_line(*args, **kwargs) -> list[str]:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        A.emit_row(*args, **kwargs)
    text = buf.getvalue().strip("\n")
    return text.split("\t") if text else []


def main() -> int:
    now_ms = int(time.time() * 1000)

    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)

        # --- session_stats over a real file ---------------------------------
        jsonl = d / "session.jsonl"
        jsonl.write_text("".join('{"i":%d}\n' % i for i in range(34)), encoding="utf-8")
        stats = A.session_stats(jsonl)
        if stats.get("turns") != 34:
            return fail(f"turns miscounted: {stats}")
        if not stats.get("started_ms"):
            return fail(f"no start stamp: {stats}")

        # A file with no trailing newline still has its last record counted?
        # No — and that is deliberate: a partially written last line is not a
        # turn yet. Assert the conservative behaviour so it cannot drift.
        partial = d / "partial.jsonl"
        partial.write_text('{"a":1}\n{"b":2}', encoding="utf-8")
        if A.session_stats(partial).get("turns") != 1:
            return fail("a half-written trailing record must not count as a turn")

        # --- the budget guard reports unknown rather than guessing ----------
        if "turns" in A.session_stats(jsonl, budget_bytes=8):
            return fail("oversized file must report unknown, not an estimate")

        # --- non-JSONL still gets the universal fact ------------------------
        blob = d / "state.json"
        blob.write_text("{}", encoding="utf-8")
        s2 = A.session_stats(blob)
        if "turns" in s2:
            return fail("turns must not be invented for a format we cannot count")
        if not s2.get("started_ms"):
            return fail("every file-backed session can answer when it started")

        # --- a vanished path is not an exception ----------------------------
        if A.session_stats(d / "nope.jsonl") != {}:
            return fail("a missing file must degrade, not raise")

        # --- the wire format ------------------------------------------------
        row = ("Fix the parser", 12_000, 3_000, "Bash", "", "Pulse", "/tmp/p", now_ms, "sid-1", stats)
        cols = emit_to_line("claude", row)
        if len(cols) != COLUMNS:
            return fail(f"expected {COLUMNS} columns, got {len(cols)}: {cols}")
        if cols[12] != "34":
            return fail(f"turns column wrong: {cols[12]}")
        if int(cols[13] or 0) <= 0:
            return fail(f"started_ms column wrong: {cols[13]}")

        # --- a row with no extras keeps working -----------------------------
        legacy = emit_to_line("amp", ("Amp thread", 0, 0, "", "", "", "", now_ms))
        if len(legacy) != COLUMNS:
            return fail(f"legacy row lost columns: {legacy}")
        if (legacy[12], legacy[13]) != ("0", "0"):
            return fail(f"legacy row must read as unknown: {legacy[12:]}")

        # --- the dict sentinel must not be mistaken for a field -------------
        # This protocol dispatches on tuple length, which is why the extras
        # ride in a dict: appending two positional fields would make a
        # 9-tuple ambiguous and the wrong reading would be silent.
        nine = emit_to_line("droid", ("t", 0, 0, "", "", "", "", now_ms, "sid-9"))
        if nine[11] != "sid-9":
            return fail(f"session id misread as something else: {nine}")
        with_extras = emit_to_line("droid", ("t", 0, 0, "", "", "", "", now_ms, "sid-9", stats))
        if with_extras[11] != "sid-9" or with_extras[12] != "34":
            return fail(f"dict sentinel shifted a field: {with_extras}")

    # --- the tool name must never be a guess --------------------------------
    #
    # `last_tool_name` ends with "any \"name\": \"...\" that is not one of six keys
    # we know are not tools". Against the four transcript-shaped agents it was
    # written for that is fine. Against the other twenty-six — VS Code
    # globalStorage, IDE state, MCP config — it misfires on all of these, and
    # each misfire is displayed as "this agent is currently running X".
    #
    # Waiting comes only from hooks or an explicit pending, never from a guess.
    # A tool name is the same class of claim.
    blobs = {
        "vscode state": '{"name":"workspaceFolder","value":"/Users/me/code"}',
        "ide settings": '{"profile":{"name":"Default"},"theme":"dark"}',
        "mcp servers": '{"servers":[{"name":"filesystem","command":"npx"}]}',
        "model config": '{"model":{"name":"claude_sonnet","maxTokens":8000}}',
    }
    for label, blob in blobs.items():
        if A.last_tool_name_strict(blob):
            return fail(f"{label}: guessed a tool from {blob!r}")
    if not any(A.last_tool_name(b) for b in blobs.values()):
        return fail("the loose extractor stopped guessing — strict may be redundant now")

    real = '{"type":"tool_use","name":"Bash","input":{"command":"ls"}}'
    if A.last_tool_name_strict(real) != "Bash":
        return fail("strict must still read a real tool_use record")
    if A.last_tool_name_strict('{"toolName":"run_command"}') != "run_command":
        return fail("strict must still read a recognised tool name")

    # --- the harvesters are actually wired ----------------------------------
    source = (ROOT / "src" / "activity_scan.py").read_text(encoding="utf-8")
    wired = source.count("session_stats(") - 1  # minus the definition
    if wired < 15:
        return fail(f"only {wired} harvesters ask for session stats")
    tools = source.count("last_tool_name_strict(") - 1
    if tools < 12:
        return fail(f"only {tools} harvesters extract a tool name")

    print(f"harvest stats OK — {COLUMNS} columns, {wired} stats-wired, {tools} tool-wired")
    return 0


if __name__ == "__main__":
    sys.exit(main())
