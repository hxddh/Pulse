#!/usr/bin/env python3
"""Gate: the harvest emits its session facts, through the real collectors.

The 0.28.0 version of this file claimed to "build a synthetic session tree and
run the real harvester". It did not. It called `session_stats()` and
`emit_row()` directly, hand-assembled tuples, and decided a collector was
wired by counting the string `session_stats(` in the source.

Counting a string cannot tell live wiring from dead wiring, and two collectors
were dead:

  * Cascade built its row with the stats dict at index 10 and then normalised
    with `row[:9]`, throwing it away — while still paying for the file scan.
  * Amp's pending path rewrote index 8 with the session id, which is exactly
    where the stats dict sat on a thread row.

Both shipped, and this gate was green the whole time. So it now points `HOME`
at a temporary tree, lays out real session files where each collector actually
looks, calls the collector, and reads the finished TSV. If a fact does not
survive from disk to column, it fails here.

    python3 scripts/harvest_stats_check.py
"""
from __future__ import annotations

import contextlib
import importlib
import io
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

import activity_scan as A  # noqa: E402

COLUMNS = 14
COL_TASK, COL_TIN, COL_TOUT, COL_TOOL = 1, 2, 3, 4
COL_PROJECT, COL_CWD, COL_SESSION, COL_RECORDS, COL_STARTED = 6, 7, 11, 12, 13

RECORDS = 34
TRANSCRIPT = "".join(
    '{"type":"tool_use","name":"Bash","input":{"command":"ls"}}\n' if i % 5 == 0
    else '{"type":"text","text":"line %d"}\n' % i
    for i in range(RECORDS)
)


def fail(msg: str) -> int:
    print(f"harvest stats FAILED: {msg}", file=sys.stderr)
    return 1


def capture(fn) -> list[list[str]]:
    """Run a collector block and return its emitted TSV rows."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        fn()
    return [ln.split("\t") for ln in buf.getvalue().splitlines() if ln and not ln.startswith("#")]


def emit_to_line(*args) -> list[str]:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        A.emit_row(*args)
    text = buf.getvalue().strip("\n")
    return text.split("\t") if text else []


def check_helper_contract(d: Path) -> int:
    """`session_stats` itself: the honesty rules, not the wiring."""
    jsonl = d / "session.jsonl"
    jsonl.write_text(TRANSCRIPT, encoding="utf-8")

    stats = A.session_stats(jsonl, per_session=True)
    if stats.get("records") != RECORDS:
        return fail(f"records miscounted: {stats}")
    if not stats.get("started_ms"):
        return fail(f"no start stamp: {stats}")

    # A container file is not a session. `harvest_extension_storage` picks one
    # session out of a shared blob, so the blob's birth time is not that
    # session's start — 0.28.0 reported it as one, which could age a
    # five-minute-old session by months.
    if A.session_stats(jsonl, per_session=False) != {}:
        return fail("per_session=False must report nothing at all")

    # Unknown is reported as unknown, never estimated.
    if "records" in A.session_stats(jsonl, per_session=True, budget_bytes=8):
        return fail("oversized file must report unknown, not an estimate")
    blob = d / "state.json"
    blob.write_text("{}", encoding="utf-8")
    if "records" in A.session_stats(blob, per_session=True):
        return fail("records must not be invented for a format we cannot count")
    if A.session_stats(d / "nope.jsonl", per_session=True) != {}:
        return fail("a missing file must degrade, not raise")

    # The extras sentinel is a dict precisely because this protocol dispatches
    # on tuple length; two more positional fields would make a 9-tuple mean
    # two different things and the wrong reading would be silent.
    nine = emit_to_line("droid", ("t", 0, 0, "", "", "", "", int(time.time() * 1000), "sid-9"))
    if len(nine) != COLUMNS or nine[COL_SESSION] != "sid-9":
        return fail(f"legacy row shifted or lost columns: {nine}")
    if (nine[COL_RECORDS], nine[COL_STARTED]) != ("0", "0"):
        return fail(f"a row without extras must read as unknown: {nine[COL_RECORDS:]}")
    with_extras = emit_to_line(
        "droid", ("t", 0, 0, "", "", "", "", int(time.time() * 1000), "sid-9", stats)
    )
    if with_extras[COL_SESSION] != "sid-9" or with_extras[COL_RECORDS] != str(RECORDS):
        return fail(f"dict sentinel shifted a field: {with_extras}")
    return 0


def check_tool_reading() -> int:
    """A tool name is a claim, and claims here are read, never guessed."""
    must_not = {
        # These four are why the strict extractor exists.
        "vscode state": '{"name":"workspaceFolder","value":"/Users/me/code"}',
        "ide settings": '{"profile":{"name":"Default"},"theme":"dark"}',
        "mcp servers": '{"servers":[{"name":"filesystem","command":"npx"}]}',
        "model config": '{"model":{"name":"claude_sonnet","maxTokens":8000}}',
        # …and these two are what it still got wrong in 0.28.0, because every
        # blob above lacks a `tool_use` and so never reached the first tier.
        "nested argument": '{"type":"tool_use","input":{"name":"production"}}',
        "neighbouring record": '{"type":"tool_use","id":"x"}\n{"role":"user","name":"alice"}',
        "non-string name": '{"type":"tool_use","name":123}',
        "tool result": '{"type":"custom_tool_call_output","name":"not_a_call"}',
    }
    for label, blob in must_not.items():
        got = A.last_tool_name_strict(blob)
        if got:
            return fail(f"{label}: guessed {got!r} from {blob!r}")

    must = {
        '{"type":"tool_use","name":"Bash","input":{"command":"ls"}}': "Bash",
        '{"type":"tool_use","name":"Read"}\n{"type":"tool_use","name":"Edit"}': "Edit",
        '{"message":{"content":[{"type":"tool_use","name":"Grep"}]}}': "Grep",
        '[{"type":"tool_use","name":"Glob"}]': "Glob",
        '{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec"}}': "exec",
        '{"type":"response_item","payload":{"type":"function_call","name":"view_image"}}': "view_image",
        '{"type":"tool_call","function":{"name":"search_code"}}': "search_code",
        '{"toolName":"run_command"}': "run_command",
    }
    for blob, want in must.items():
        got = A.last_tool_name_strict(blob)
        if got != want:
            return fail(f"failed to read a real tool: {blob!r} -> {got!r}, want {want!r}")

    if not any(A.last_tool_name(b) for b in list(must_not.values())[:4]):
        return fail("the loose extractor stopped guessing — strict may be redundant now")
    fake_title = (
        '{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec",'
        '"arguments":"{\\"title\\":\\"Internal tool title\\"}"}}\n'
        '{"type":"session","title":"Human session title"}'
    )
    if A.session_title_from_text(fake_title) != "Human session title":
        return fail("generic title extractor accepted a title embedded in a tool call")
    return 0


def check_collectors(home: Path) -> int:
    """The part that was missing: disk → collector → TSV, per collector.

    Each entry lays out a session where that collector looks, then asserts the
    facts survive the collector's own row-shaping. Cascade and Amp are here by
    name because both lost the metrics in their own adapter while the string
    count said they were wired.
    """
    cases: list[tuple[str, Path, object]] = []

    claude = home / ".claude" / "projects" / "-Users-me-code-Pulse"
    claude.mkdir(parents=True, exist_ok=True)
    (claude / "sess-claude.jsonl").write_text(TRANSCRIPT, encoding="utf-8")
    cases.append(("claude", claude, A.claude_block))

    # Amp is laid out *with a pending log*, because the bug was in the pending
    # branch and only in the pending branch: without one, `amp_block` takes the
    # plain path, the row never gets rewritten by index, and a gate that only
    # covers the happy layout stays green through the defect. That is precisely
    # how 0.28.0 shipped it.
    amp = home / ".local" / "share" / "amp" / "threads"
    amp.mkdir(parents=True, exist_ok=True)
    (amp / "T-amp1.jsonl").write_text(TRANSCRIPT, encoding="utf-8")
    (amp / "T-amp1.json").write_text('{"title":"Amp thread","messages":[]}', encoding="utf-8")
    amp_logs = home / ".local" / "share" / "amp" / "logs"
    amp_logs.mkdir(parents=True, exist_ok=True)
    (amp_logs / "amp-sid-1.log").write_text(
        "waiting for your approval to continue\n", encoding="utf-8"
    )
    cases.append(("amp", amp, A.amp_block))

    droid = home / ".factory" / "sessions" / "-Users-me-code-Pulse"
    droid.mkdir(parents=True, exist_ok=True)
    (droid / "sess-droid.jsonl").write_text(
        '{"title":"Droid session","cwd":"/Users/me/code/Pulse"}\n' + TRANSCRIPT, encoding="utf-8"
    )
    cases.append(("droid", droid, lambda: A.emit_all("droid", A.droid_activities())))

    # Codex writes stable metadata at the head, live events at the tail, and
    # cumulative + last-turn token counters together. This fixture is larger
    # than the collector's tail so all three regressions are exercised through
    # the real adapter.
    codex = home / ".codex" / "sessions" / "2026" / "07" / "28"
    codex.mkdir(parents=True, exist_ok=True)
    codex_file = codex / "rollout-codex-real.jsonl"
    filler = (
        '{"type":"event_msg","payload":{"type":"agent_message","message":"padding"}}\n'
        * 10_000
    )
    codex_file.write_text(
        '{"type":"session_meta","payload":{"id":"codex-real","cwd":"/Users/me/code/Pulse"}}\n'
        + filler
        + '{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec",'
          '"arguments":"{\\"title\\":\\"Internal tool title\\"}"}}\n'
        + '{"type":"event_msg","payload":{"type":"user_message",'
          '"message":"Fix all collector and tray issues"}}\n'
        + '{"type":"event_msg","payload":{"type":"token_count","info":{'
          '"total_token_usage":{"input_tokens":9000000,"output_tokens":800000},'
          '"last_token_usage":{"input_tokens":3210,"output_tokens":456}}}}\n'
        + '{"type":"response_item","payload":{"type":"function_call","name":"view_image"}}\n',
        encoding="utf-8",
    )
    cases.append(("codex", codex, lambda: A.emit_all("codex", A.codex_activities())))

    saw_any = False
    for name, where, block in cases:
        try:
            rows = capture(block)
        except Exception as exc:  # a collector must never take the scan down
            return fail(f"{name} collector raised {type(exc).__name__}: {exc}")
        if not rows:
            # Some collectors need shapes this gate cannot fake convincingly.
            # Skipping is honest; claiming coverage would not be.
            print(f"  · {name}: no row from {where} — not asserted", file=sys.stderr)
            continue
        saw_any = True
        row = rows[0]
        if len(row) != COLUMNS:
            return fail(f"{name} emitted {len(row)} columns: {row}")
        if row[COL_RECORDS] == "0" and row[COL_STARTED] == "0":
            return fail(
                f"{name}: the collector paid for the file scan and shipped 0/0 — "
                f"its row shaping drops the extras (row={row})"
            )
        if name == "amp" and row[5] != "pending":
            return fail(
                "amp fixture did not reach the pending branch, so the index "
                f"rewrite that dropped the metrics is not being covered (row={row})"
            )
        if name == "codex":
            if row[COL_TASK] != "Fix all collector and tray issues":
                return fail(f"codex used an internal title instead of the user task: {row}")
            if (row[COL_TIN], row[COL_TOUT]) != ("3210", "456"):
                return fail(f"codex emitted cumulative rather than last-turn tokens: {row}")
            if row[COL_TOOL] != "view_image":
                return fail(f"codex missed its explicit function call: {row}")
            if row[COL_PROJECT] != "Pulse" or row[COL_CWD] != "/Users/me/code/Pulse":
                return fail(f"codex lost head metadata on a long rollout: {row}")

    if not saw_any:
        return fail("no collector produced a row; this gate is asserting nothing")

    # Cascade's own adapter, exercised as data rather than as a fixture: its
    # normaliser used to chop the tuple to nine and take the stats with it.
    stats = {"records": RECORDS, "started_ms": int(time.time() * 1000) - 3_600_000}
    shaped = A.cascade_windsurf_activities.__doc__ is not None  # keeps the ref honest
    cascade_like = ("Cascade session", 0, 0, "Bash", "", "p", "/tmp/p", int(time.time() * 1000), "stem", stats)
    out = emit_to_line("cascade", cascade_like)
    if not shaped or out[COL_RECORDS] != str(RECORDS):
        return fail(f"cascade row shape drops the extras: {out}")
    return 0


def main() -> int:
    importlib.reload(A)
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        if rc := check_helper_contract(d):
            return rc
        if rc := check_tool_reading():
            return rc

        home = d / "home"
        home.mkdir()
        real_home = A.HOME
        try:
            A.HOME = home
            importlib.reload(A)  # module-level paths are built from HOME
            A.HOME = home
            if rc := check_collectors(home):
                return rc
        finally:
            A.HOME = real_home
            importlib.reload(A)

    source = (ROOT / "src" / "activity_scan.py").read_text(encoding="utf-8")
    # Named, not counted. "23 of 32 harvesters" was true and nearly worthless
    # while Claude, Codex and Gemini — the ones people leave open — were not
    # among them, and a threshold of ">= 15" could never have said so.
    for agent in ("claude_activities", "codex_activities", "gemini_activities"):
        start = source.find(f"def {agent}(")
        end = source.find("\ndef ", start + 1)
        if start < 0 or "session_stats(" not in source[start:end]:
            return fail(f"{agent} does not ask for session stats")
    if "emit_row(\"claude\"" not in source:
        return fail("claude_block must go through emit_row, or extras are dropped")
    swift = (ROOT / "PulseBar" / "Sources" / "PulseBar" / "ActivityHarvest.swift").read_text(
        encoding="utf-8"
    )
    if 'task.arguments = ["-u", script.path]' not in swift:
        return fail(
            "ActivityHarvest must run Python unbuffered or timeout partial rows "
            "remain trapped in stdout"
        )

    wired = source.count("session_stats(") - 1
    print(f"harvest stats OK — {COLUMNS} columns, {wired} collectors wired, flagships named")
    return 0


if __name__ == "__main__":
    sys.exit(main())
