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
import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

# Synthetic fixtures intentionally exercise the protected Cursor/Warp paths.
# Production defaults to the privacy-safe profile; the gate opts in only for
# its isolated temporary home so adapter coverage remains testable.
os.environ.setdefault("PULSE_ALLOW_APP_DATA", "1")
import activity_scan as A  # noqa: E402

COLUMNS = 24
COL_TASK, COL_TIN, COL_TOUT, COL_TOOL = 1, 2, 3, 4
COL_PROJECT, COL_CWD, COL_SESSION, COL_RECORDS, COL_STARTED = 6, 7, 11, 12, 13
COL_EVIDENCE = 14
COL_PHASE, COL_OUTCOME, COL_MODEL, COL_MODE = 15, 16, 17, 18
COL_ERRORS, COL_FILES, COL_CONTEXT, COL_PROGRESS_DONE, COL_PROGRESS_TOTAL = 19, 20, 21, 22, 23

RECORDS = 34
MULTI_SESSION_TEST_COUNT = 6
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


def emit_to_line(*args, **kwargs) -> list[str]:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        A.emit_row(*args, **kwargs)
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

    # A recursive cache walk can contain hundreds of unrelated files. The
    # newest session must survive the bounded walk even when the filesystem
    # enumerates it after the first page of entries.
    many = d / "large-cache"
    many.mkdir()
    for i in range(205):
        old = many / f"old-{i}.json"
        old.write_text("{}", encoding="utf-8")
        os.utime(old, (1_000 + i, 1_000 + i))
    fresh = many / "fresh-session.json"
    fresh.write_text("{}", encoding="utf-8")
    os.utime(fresh, (time.time(), time.time()))
    if fresh not in A.recent_files_under(many, ("*.json",), limit=1):
        return fail("bounded recursive scan discarded the newest session")

    fake_secret = "sk-proj-ExampleSecret123456789"
    redacted = A.redact_sensitive(
        f"Deploy {fake_secret}; Authorization: Bearer fakeBearerValue123"
    )
    if fake_secret in redacted or "fakeBearerValue123" in redacted:
        return fail("credential-shaped content crossed the harvest boundary")
    safe = "Review token budget for sketch session 550e8400-e29b-41d4-a716-446655440000"
    if A.redact_sensitive(safe) != safe:
        return fail("redaction changed ordinary technical text")

    # Negative fixtures matter as much as rich happy paths: an arbitrary cache
    # preference or an Agent-generated placeholder must never become a session.
    generic = emit_to_line(
        "antigravity",
        ("Antigravity session", 0, 0, "", "", "extension-cache", "", int(time.time() * 1000)),
        evidence=A.EVIDENCE_CACHE,
    )
    if generic:
        return fail("generic cache placeholder was promoted to a session")
    structured_placeholder = emit_to_line(
        "grok",
        ("Grok session", 0, 0, "", "", "", "", int(time.time() * 1000), "grok-session"),
        evidence=A.EVIDENCE_SESSION,
    )
    if structured_placeholder:
        return fail("bare structured placeholder was promoted to a session")
    records_only_placeholder = emit_to_line(
        "grok",
        ("Grok session", 0, 0, "", "", "", "", int(time.time() * 1000), "grok-records", {
            "records": RECORDS,
        }),
        evidence=A.EVIDENCE_SESSION,
    )
    if records_only_placeholder:
        return fail("record count alone was promoted to a generic session")
    preference = {
        "theme": "dark",
        "model": "agent-model",
        "status": "enabled",
        "telemetry": True,
    }
    if A.observed_facts_from_json(preference):
        return fail("unscoped cache preferences were promoted to session facts")

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
    if with_extras[COL_EVIDENCE] != A.EVIDENCE_SESSION:
        return fail(f"structured fixture lost its evidence tier: {with_extras}")

    # Cache adapters must not turn their own fallback labels into observations.
    placeholder = emit_to_line(
        "roo",
        ("Roo session", 0, 0, "", "", "roo-code", "", int(time.time() * 1000), "state"),
        evidence=A.EVIDENCE_CACHE,
    )
    if placeholder:
        return fail(f"cache placeholder escaped admission filter: {placeholder}")
    observed = emit_to_line(
        "roo",
        ("Refactor authentication", 0, 0, "", "", "app", "", int(time.time() * 1000), "state"),
        evidence=A.EVIDENCE_CACHE,
    )
    if not observed or observed[COL_EVIDENCE] != A.EVIDENCE_CACHE:
        return fail(f"useful cache observation lost its tier: {observed}")

    nested = {
        "state": {
            "sessions": [
                {
                    "sessionId": "s-cache-1",
                    "title": "Refactor authentication",
                    "workspacePath": "/Users/me/code/app",
                }
            ]
        }
    }
    if A.observed_session_from_json(nested) != (
        "Refactor authentication", "/Users/me/code/app", "s-cache-1"
    ):
        return fail("nested extension session facts were not recovered")
    multi_nested = {
        "state": {
            "sessions": [
                {
                    "sessionId": f"s-cache-{i}",
                    "title": f"Concurrent task {i}",
                    "workspacePath": f"/Users/me/code/app-{i}",
                    "lastUpdatedAt": int(time.time() * 1000) - i * 1000,
                }
                for i in range(1, MULTI_SESSION_TEST_COUNT + 1)
            ]
        }
    }
    recovered = A.observed_sessions_from_json(multi_nested)
    if len(recovered) != MULTI_SESSION_TEST_COUNT:
        return fail(
            "shared extension cache was collapsed before the product-wide "
            f"session cap: {recovered}"
        )
    if len({row[2] for row in recovered}) != MULTI_SESSION_TEST_COUNT:
        return fail(f"shared extension sessions were not kept distinct: {recovered}")
    long_nested = {
        "state": {
            "sessions": [
                {"sessionId": f"old-{i}", "title": f"Old task {i}"}
                for i in range(220)
            ] + [
                {
                    "sessionId": f"tail-{i}",
                    "title": f"Tail task {i}",
                    "workspacePath": f"/Users/me/code/tail-{i}",
                }
                for i in range(1, MULTI_SESSION_TEST_COUNT + 1)
            ]
        }
    }
    tail_rows = A.observed_sessions_from_json(long_nested)
    if len(tail_rows) < MULTI_SESSION_TEST_COUNT or not any(row[2] == "tail-6" for row in tail_rows):
        return fail("large shared cache lost active tail sessions during bounded parsing")
    config = {
        "profile": {"name": "Default"},
        "model": {"name": "claude_sonnet"},
        "theme": {"title": "Dark"},
    }
    if A.observed_session_from_json(config) != ("", "", ""):
        return fail("configuration names were guessed as a session")
    if A.observed_facts_from_json(config) != {}:
        return fail("configuration values were guessed as session telemetry")
    # Cursor has emitted all of seconds, milliseconds, microseconds, and ISO
    # text for `lastUpdatedAt` across client builds. One malformed timestamp
    # must not make the collector discard every concurrent session.
    expected_ms = 1_754_000_000_000
    if A.normalize_time_ms(expected_ms // 1000) != expected_ms:
        return fail("epoch-second timestamp was not normalized to milliseconds")
    if A.normalize_time_ms(str(expected_ms)) != expected_ms:
        return fail("numeric timestamp string was not normalized")
    if A.normalize_time_ms(expected_ms * 1000) != expected_ms:
        return fail("microsecond timestamp was not normalized")
    iso = "2026-07-28T10:00:00Z"
    if A.normalize_time_ms(iso) != A.iso_time_ms(iso):
        return fail("ISO timestamp was not normalized")
    if A.normalize_time_ms("not-a-time") != 0:
        return fail("malformed timestamp was treated as activity")
    usage_blob = '{"usage":{"input":1200,"output":37,"cacheRead":90}}'
    if A.last_usage_tokens(usage_blob) != (1200, 37):
        return fail("provider usage input/output fields were not recovered")
    if A.last_model_name('{"model":"provider-model"}') != "provider-model":
        return fail("explicit provider model was not recovered")

    # Generic IDE adapters must ignore a settings/index file even if it has a
    # title and workspace-shaped values. An explicitly session-like path is
    # still accepted, preserving the useful fallback contract.
    generic_root = d / "generic-cache"
    generic_root.mkdir()
    (generic_root / "settings.json").write_text(
        json.dumps({"title": "Dark", "cwd": "/Users/me/code/Pulse", "model": "x"}),
        encoding="utf-8",
    )
    if A.home_dir_activities("roo", [generic_root]):
        return fail("generic settings file escaped the session admission filter")
    session_root = d / "sessions" / "thread-1"
    session_root.mkdir(parents=True)
    (session_root / "state.json").write_text(
        json.dumps({
            "title": "Refactor authentication",
            "cwd": "/Users/me/code/Pulse",
            "sessionId": "thread-1",
            "phase": "testing",
        }),
        encoding="utf-8",
    )
    if not A.home_dir_activities("roo", [d / "sessions"]):
        return fail("explicit session-shaped cache file was discarded")
    rich_nested = {
        "state": {
            "sessions": [{
                "sessionId": "s-rich",
                "title": "Ship observability",
                "workspacePath": "/Users/me/code/Pulse",
                "phase": "testing",
                "modelId": "agent-4",
                "agentMode": "build",
                "errorCount": 2,
                "filesChanged": 7,
                "contextWindowUsage": 41,
                "completedTasks": 3,
                "totalTasks": 5,
            }]
        }
    }
    facts = A.observed_facts_from_json(rich_nested)
    expected = {
        "phase": "testing", "model": "agent-4", "mode": "build",
        "errors": 2, "files": 7, "context_pct": 41,
        "progress_done": 3, "progress_total": 5,
    }
    if facts != expected:
        return fail(f"qualified cache telemetry was not recovered: {facts}")
    jsonl = (
        '{"type":"meta","sessionId":"s2","workspacePath":"/Users/me/code/pulse"}\n'
        '{"type":"session","title":"Polish the tray"}\n'
    )
    title, cwd, _ = A.observed_session_from_text(jsonl)
    if title != "Polish the tray" or cwd != "/Users/me/code/pulse":
        return fail(f"JSONL session facts were not recovered: {(title, cwd)}")

    # Python cannot decide stale-vs-live because the process match happens in
    # Swift. It must emit the row so a live process can keep its known goal.
    stale = emit_to_line(
        "amp",
        ("Known long-running goal", 0, 0, "", "", "Pulse", "/Users/me/Pulse",
         int(time.time() * 1000) - A.FRESH_SEC * 1000 - 10_000, "amp-stale"),
    )
    if not stale:
        return fail("stale session evidence was dropped before live-process merge")

    # A helper path is not an invoked skill.
    if A.last_skill_name('{"path":"/tmp/skills/audit/scripts/preflight.py"}'):
        return fail("a skill helper path was exposed as an invoked skill")
    skill_blob = (
        '{"type":"tool_use","name":"Skill","skill":"product-design:audit"}\n'
    )
    facts = A.observed_facts_from_text(skill_blob)
    if facts.get("phase") != "researching":
        return fail(f"explicit skill invocation lost its semantic phase: {facts}")

    # Long tool output after a recent prompt must not push that prompt out of
    # a fixed tail window and resurrect the session-opening task.
    rollout = d / "large-codex-rollout.jsonl"
    opening = json.dumps({
        "type": "event_msg",
        "payload": {"type": "user_message", "message": "Initial setup request"},
    })
    latest = json.dumps({
        "type": "event_msg",
        "payload": {"type": "user_message", "message": "Fix the four panel corners"},
    })
    filler = '{"type":"response_item","payload":{"type":"tool_result","text":"x"}}\n'
    rollout.write_text(
        opening + "\n" + filler * 2_000 + latest + "\n" + filler * 3_000,
        encoding="utf-8",
    )
    got = A.codex_user_title_from_file(rollout, max_bytes=32_000)
    if got != "Fix the four panel corners":
        return fail(f"large Codex rollout resurrected an old task: {got!r}")
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
    pi_prompt = (
        '{"type":"session","id":"pi-fixture"}\n'
        '{"type":"message","message":{"role":"user","content":'
        '[{"type":"text","text":"pi update"}]}}\n'
        '{"type":"message","message":{"role":"assistant","content":'
        '[{"type":"text","text":"All packages are current"}]}}\n'
    )
    if A.pi_user_title(pi_prompt) != "pi update":
        return fail("Pi user prompt was not extracted from message.content")
    if A.normalize_pi_task("pi update") != "Update Pi and extensions":
        return fail("Pi maintenance prompt stayed as an opaque CLI command")

    unresolved = (
        '{"type":"response_item","payload":{"type":"function_call",'
        '"name":"view_image","call_id":"call-1"}}\n'
    )
    if A.semantic_phase_from_events(unresolved) != "reading":
        return fail("an unresolved image inspection did not produce the semantic Reading role")
    resolved = unresolved + (
        '{"type":"response_item","payload":{"type":"function_call_output",'
        '"call_id":"call-1","output":"ok"}}\n'
    )
    if A.semantic_phase_from_events(resolved):
        return fail("a completed historical tool was presented as the current phase")
    completed = resolved + '{"type":"event_msg","payload":{"type":"turn_complete"}}\n'
    if A.semantic_phase_from_events(completed) != "turn_complete":
        return fail("an explicit turn completion was not preserved")
    permission = '{"type":"permission_requested","message":"approve command"}\n'
    if A.semantic_phase_from_events(permission) != "waiting_permission":
        return fail("an explicit permission wait was not preserved")
    # Codex Desktop wraps shell calls in a JavaScript tool envelope. The
    # command is escaped inside `input`, so role detection must still expose
    # the useful phase without leaking the command itself to the UI.
    escaped_shell = json.dumps({
        "type": "response_item",
        "payload": {
            "type": "custom_tool_call",
            "name": "exec",
            "call_id": "escaped-1",
            "input": 'const r = await tools.exec_command({cmd:\"rg -n foo\"})',
        },
    })
    if A.semantic_phase_from_events(escaped_shell) != "reading":
        return fail("an escaped Codex rg command did not become the semantic Reading role")
    shell_test = (
        '{"type":"function_call","name":"exec_command","call_id":"test-1",'
        '"arguments":{"cmd":"swift test"}}\n'
    )
    if A.semantic_phase_from_events(shell_test) != "testing":
        return fail("a structured test command did not become the semantic Testing role")
    shell_build = (
        '{"type":"function_call","name":"exec_command","call_id":"build-1",'
        '"arguments":{"cmd":"swift build"}}\n'
    )
    if A.semantic_phase_from_events(shell_build) != "building":
        return fail("a structured build command did not become the semantic Building role")
    shell_publish = (
        '{"type":"function_call","name":"exec_command","call_id":"publish-1",'
        '"arguments":{"cmd":"git push origin main"}}\n'
    )
    if A.semantic_phase_from_events(shell_publish) != "publishing":
        return fail("a structured publish command did not become the semantic Publishing role")
    if A.semantic_phase_from_events(
        '{"type":"function_call","name":"write_stdin","call_id":"poll-1"}\n'
    ) != "working":
        return fail("terminal polling was mislabelled as Editing")
    if A.semantic_phase_from_events(
        '{"type":"function_call","name":"build","call_id":"build-2"}\n'
    ) != "building":
        return fail("a build tool was mislabelled as Testing")
    if A.semantic_phase_from_events(
        '{"type":"function_call","name":"latest","call_id":"latest-1"}\n'
    ) != "working":
        return fail("a tool with `test` as a substring was mislabelled as Testing")
    return 0


def check_runtime_health_protocol() -> int:
    """One scan stream must explain both rows and zero/error outcomes."""
    A.EMITTED_COUNTS.clear()
    out = io.StringIO()
    original_source_probe = A.collector_source_present
    A.collector_source_present = lambda agent: agent == "codex"
    try:
        with contextlib.redirect_stdout(out):
            A.guard(
                ("claude", "codex"),
                lambda: A.emit(
                    "claude", "Health fixture", 0, 0, "", "", mtime_ms=int(time.time() * 1000)
                ),
            )
    finally:
        A.collector_source_present = original_source_probe
    health = [line.split("\t") for line in out.getvalue().splitlines() if line.startswith("#health\t")]
    states = {cols[1]: (cols[2], cols[4], cols[6]) for cols in health}
    if states != {
        "claude": ("observed", "1", "0"),
        "codex": ("no_sessions", "0", "1"),
    }:
        return fail(f"runtime health did not distinguish rows from healthy zero-data: {states}")

    def boom() -> None:
        raise ValueError("private vendor path must not enter stdout")

    out = io.StringIO()
    err = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        A.guard("amp", boom)
    line = next((x for x in out.getvalue().splitlines() if x.startswith("#health\t")), "")
    # Duration and source-presence depend on the runner. The error class and
    # privacy-safe state do not.
    cols = line.split("\t")
    if (
        len(cols) != 7
        or cols[1] != "amp"
        or cols[2] != "schema_mismatch"
        or cols[4:6] != ["0", "ValueError"]
        or cols[6] not in ("0", "1")
    ):
        return fail(f"runtime failure health is malformed: {line!r}")
    if "private vendor path" in out.getvalue():
        return fail("runtime health leaked the collector exception message to stdout")
    return 0


def check_collectors(home: Path) -> int:
    """The part that was missing: disk → collector → TSV, per collector.

    Each entry lays out a session where that collector looks, then asserts the
    facts survive the collector's own row-shaping. Cascade and Amp are here by
    name because both lost the metrics in their own adapter while the string
    count said they were wired.
    """
    cases: list[tuple[str, Path, object]] = []

    def write_session(path: Path, agent: str) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps({
                "type": "session",
                "id": f"{agent}-fixture",
                "sessionId": f"{agent}-fixture",
                "title": f"Observe {agent} activity",
                "task": f"Observe {agent} activity",
                "cwd": "/Users/me/code/Pulse",
                "workspacePath": "/Users/me/code/Pulse",
                "phase": "testing",
                "completedTasks": 2,
                "totalTasks": 3,
                "agent": True,
                "event": "agent",
                "action": "tool_call",
                "chat": "message",
            }) + "\n",
            encoding="utf-8",
        )
        return path

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
        '{"type":"turn_context","payload":{"model":"fixture-model",'
          '"collaboration_mode_kind":"default"}}\n'
        '{"type":"event_msg","payload":{"type":"task_started",'
          '"model_context_window":10000}}\n'
        + filler
        + '{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec",'
          '"arguments":"{\\"title\\":\\"Internal tool title\\"}"}}\n'
        + '{"type":"event_msg","payload":{"type":"user_message",'
          '"message":"# Files mentioned by the user:\\n\\n## screenshot.png: /tmp/screenshot.png'
          '\\n\\n## My request for Codex:\\nFix all collector and tray issues'
          '\\n<image name=\\"Image #1\\">transport metadata</image>"}}\n'
        + '{"type":"event_msg","payload":{"type":"token_count","info":{'
          '"total_token_usage":{"input_tokens":9000000,"output_tokens":800000},'
          '"last_token_usage":{"input_tokens":3210,"output_tokens":456},'
          '"model_context_window":10000}}}\n'
        + '{"type":"event_msg","payload":{"type":"user_message","message":"进展如何"}}\n'
        + '{"type":"event_msg","payload":{"type":"user_message","message":"发布"}}\n'
        + '{"type":"response_item","payload":{"type":"function_call","name":"view_image"}}\n',
        encoding="utf-8",
    )
    cases.append(("codex", codex, lambda: A.emit_all("codex", A.codex_activities())))

    grok = home / ".grok"
    grok_session = grok / "sessions" / "%2FUsers%2Fme%2Fcode%2FPulse" / "grok-real"
    grok_session.mkdir(parents=True, exist_ok=True)
    grok.mkdir(parents=True, exist_ok=True)
    (grok / "active_sessions.json").write_text(
        '[{"session_id":"grok-real","cwd":"/Users/me/code/Pulse"}]',
        encoding="utf-8",
    )
    (grok_session / "summary.json").write_text(
        '{"generated_title":"Fix multipart upload","created_at":"2026-07-28T10:00:00Z",'
        '"num_messages":23,"current_model_id":"grok-4.5","agent_name":"grok-build-plan"}',
        encoding="utf-8",
    )
    (grok_session / "signals.json").write_text(
        '{"turnCount":4,"toolFailureCount":1,"totalFilesTouched":3,"contextWindowUsage":27}',
        encoding="utf-8",
    )
    (grok_session / "events.jsonl").write_text(
        '{"type":"tool_started","tool_name":"read_file"}\n'
        '{"type":"turn_ended","outcome":"completed"}\n',
        encoding="utf-8",
    )
    (grok_session / "chat_history.jsonl").write_text(
        '{"role":"tool","content":"internal failure must not become title"}\n',
        encoding="utf-8",
    )
    cases.append(("grok", grok_session, lambda: A.emit_all("grok", [A.grok_activity()])))
    # The active index can lag its just-written session directory. Exercise the
    # summary fallback rather than only the happy-path index.
    (grok / "active_sessions.json").write_text("[]", encoding="utf-8")

    # Every remaining adapter gets a source-shaped disk fixture and is run
    # through its real collector plus emit_row. Shared helpers are deliberately
    # exercised once per public Agent contract: a change to a needle or root
    # must identify which Agent lost observability.
    pi = write_session(
        home / ".pi" / "agent" / "sessions" / "pulse" / "pi-fixture.jsonl",
        "pi",
    )
    cases.append(("pi", pi, lambda: A.emit_all("pi", [A.pi_activity()])))

    continue_file = write_session(home / ".continue" / "sessions" / "continue.jsonl", "continue")
    cases.append(("continue", continue_file, lambda: A.emit_all("continue", A.continue_activities())))

    copilot_dir = home / ".copilot" / "session-state" / "copilot-fixture"
    copilot_events = write_session(copilot_dir / "events.jsonl", "copilot")
    (copilot_dir / "workspace.yaml").write_text(
        'title: Observe Copilot activity\ncwd: /Users/me/code/Pulse\n',
        encoding="utf-8",
    )
    cases.append(("copilot", copilot_events, lambda: A.emit_all("copilot", A.copilot_activities())))

    simple_sources = {
        "amazon_q": home / ".aws" / "amazonq" / "session.json",
        "zed_agent": home / ".zed" / "threads" / "agent-session.json",
        "openhands": home / ".openhands" / "sessions" / "session.json",
        "antigravity": home / ".antigravity" / "sessions" / "session.json",
        "cascade": home / ".codeium" / "sessions" / "cascade.json",
        "windsurf": home / ".windsurf" / "sessions" / "windsurf.json",
        "augment": home / ".augment" / "sessions" / "session.json",
        "trae": home / ".trae" / "sessions" / "agent-session.json",
        "warp_agent": home / ".warp" / "conversations" / "agent-session.json",
        "devin": home / ".devin" / "sessions" / "session.json",
        "junie": home / ".junie" / "sessions" / "session.json",
        "replit": home / ".replit" / "sessions" / "session.json",
        "goose": home / ".config" / "goose" / "sessions" / "session.json",
    }
    simple_functions = {
        "amazon_q": A.amazon_q_activities,
        "zed_agent": A.zed_agent_activities,
        "openhands": A.openhands_activities,
        "antigravity": A.antigravity_activities,
        "cascade": A.cascade_windsurf_activities,
        "windsurf": A.windsurf_shell_activities,
        "augment": A.augment_activities,
        "trae": A.trae_activities,
        "warp_agent": A.warp_agent_activities,
        "devin": A.devin_activities,
        "junie": A.junie_activities,
        "replit": A.replit_activities,
        "goose": A.goose_activities,
    }
    for name, path in simple_sources.items():
        write_session(path, name)
        fn = simple_functions[name]
        cases.append((name, path, lambda name=name, fn=fn: A.emit_all(name, fn())))

    code_storage = home / "Library" / "Application Support" / "Code" / "User" / "globalStorage"
    extension_sources = {
        "cline": code_storage / "saoudrizwan.claude-dev" / "session.json",
        "roo": code_storage / "roo-code" / "session.json",
        "kilo": code_storage / "kilocode" / "session.json",
        "kiro": code_storage / "amazon.kiro" / "session.json",
    }
    extension_functions = {
        "cline": A.cline_activities,
        "roo": A.roo_activities,
        "kilo": A.kilo_activities,
        "kiro": A.kiro_activities,
    }
    for name, path in extension_sources.items():
        write_session(path, name)
        fn = extension_functions[name]
        cases.append((name, path, lambda name=name, fn=fn: A.emit_all(name, fn())))

    aider_files: list[Path] = []
    for i in range(1, MULTI_SESSION_TEST_COUNT + 1):
        aider = home / "code" / f"Pulse-{i}" / ".aider.chat.history.md"
        aider.parent.mkdir(parents=True, exist_ok=True)
        aider.write_text(
            f"# aider chat {i}\nObserve aider activity {i}\n", encoding="utf-8"
        )
        aider_files.append(aider)
    cases.append(("aider", aider_files[0], lambda: A.emit_all("aider", A.aider_activities())))

    command_dir = home / ".commandcode" / "projects" / "pulse"
    command_meta = write_session(command_dir / "command-fixture.meta.json", "command_code")
    command_transcript = command_dir / "command-fixture.jsonl"
    command_transcript.parent.mkdir(parents=True, exist_ok=True)
    command_lines = [json.dumps({"cwd": "/Users/me/code/Pulse"}), json.dumps({
            "type": "message",
            "message": {
                "role": "user",
                "content": [{"type": "text", "text": "Inspect Command Code session telemetry"}],
            },
        })]
    # Make the fixture exceed the old tail-only read. The real Command Code
    # transcript has large tool results between the opening request and the
    # current tool call; a short fixture would let that regression pass.
    command_lines.extend(
        json.dumps({
            "type": "message",
            "message": {
                "role": "user",
                "content": [{
                    "type": "tool_result",
                    "content": [{"type": "text", "text": "tool output " + ("x" * 10_000)}],
                }],
            },
        })
        for _ in range(30)
    )
    command_lines.extend([
        json.dumps({
            "type": "message",
            "message": {
                "role": "user",
                "content": [{
                    "type": "tool_result",
                    "content": [{"type": "text", "text": "internal tool output"}],
                }],
            },
        }) + "\n"
        + json.dumps({
            "type": "message",
            "message": {
                "role": "assistant",
                "content": [{"type": "tool_use", "name": "read_file"}],
            },
            "model": "command-fixture-model",
        }),
    ])
    command_transcript.write_text("\n".join(command_lines) + "\n", encoding="utf-8")
    (command_dir / "settings.json").write_text(
        '{"cwd":"/Users/me/legacy-command-code"}', encoding="utf-8"
    )
    cases.append((
        "command_code",
        command_meta,
        lambda: A.emit_all("command_code", A.command_code_activities()),
    ))

    kimi_dir = home / ".kimi-code" / "sessions" / "kimi-fixture"
    kimi_state = write_session(kimi_dir / "state.json", "kimi")
    write_session(kimi_dir / "agents" / "main" / "wire.jsonl", "kimi")
    cases.append(("kimi", kimi_state, lambda: A.emit_all("kimi", A.kimi_activities())))

    gemini = home / ".gemini" / "tmp" / "pulse" / "chats" / "session-fixture.jsonl"
    gemini.parent.mkdir(parents=True, exist_ok=True)
    gemini.write_text(
        '{"type":"user","content":"Observe Gemini activity"}\n'
        '{"functionCall":{"name":"read_file"},"promptTokenCount":120,"candidatesTokenCount":30}\n',
        encoding="utf-8",
    )
    (gemini.parent.parent / ".project_root").write_text(
        "/Users/me/code/Pulse", encoding="utf-8"
    )
    cases.append(("gemini", gemini, lambda: A.emit_all("gemini", A.gemini_activities())))

    import sqlite3

    # Warp stores Agent conversations in an App Group SQLite database. Keep a
    # small real schema fixture so the collector cannot regress to its old
    # JSON-only fallback without this gate noticing.
    warp_db = (
        home / "Library" / "Group Containers" / "2BBY89MBSN.dev.warp"
        / "Library" / "Application Support" / "dev.warp.Warp-Stable" / "warp.sqlite"
    )
    warp_db.parent.mkdir(parents=True, exist_ok=True)
    wcon = sqlite3.connect(warp_db)
    wcon.executescript(
        """
        CREATE TABLE agent_conversations (
            id INTEGER PRIMARY KEY, conversation_id TEXT NOT NULL,
            conversation_data TEXT NOT NULL, last_modified_at TIMESTAMP NOT NULL,
            summary TEXT
        );
        CREATE TABLE agent_tasks (
            id INTEGER PRIMARY KEY, conversation_id TEXT NOT NULL,
            task_id TEXT NOT NULL, task BLOB NOT NULL, last_modified_at TIMESTAMP NOT NULL
        );
        CREATE TABLE ai_queries (
            id INTEGER PRIMARY KEY, exchange_id TEXT NOT NULL,
            conversation_id TEXT NOT NULL, start_ts DATETIME NOT NULL,
            input TEXT NOT NULL, working_directory TEXT, output_status TEXT NOT NULL,
            model_id TEXT NOT NULL, planning_model_id TEXT NOT NULL, coding_model_id TEXT NOT NULL
        );
        """
    )
    warp_now = "2026-07-28 12:00:00"
    warp_summary = json.dumps({
        "title": "Inspect Warp Agent telemetry",
        "initial_query": "Inspect Warp Agent telemetry",
        "initial_working_directory": "/Users/me/code/Pulse",
    })
    warp_conversation_data = json.dumps({
        "conversation_usage_metadata": {
            "tool_usage_metadata": {"run_command_stats": {"count": 3}}
        }
    })
    wcon.execute(
        "INSERT INTO agent_conversations VALUES (1, ?, ?, ?, ?)",
        ("warp-fixture", warp_conversation_data, warp_now, warp_summary),
    )
    wcon.execute(
        "INSERT INTO agent_tasks VALUES (1, ?, ?, ?, ?)",
        ("warp-fixture", "task-1", b"task", warp_now),
    )
    wcon.execute(
        "INSERT INTO ai_queries VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            "exchange-1", "warp-fixture", warp_now,
            json.dumps({"Query": {"text": "Inspect Warp Agent telemetry"}}),
            "/Users/me/code/Pulse", '"Completed"', "warp-fixture-model", "", "",
        ),
    )
    wcon.commit()
    wcon.close()

    cursor_db = home / "Library" / "Application Support" / "Cursor" / "User" / "globalStorage" / "state.vscdb"
    cursor_db.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(cursor_db)
    con.execute("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)")
    con.execute(
        "CREATE TABLE composerHeaders "
        "(composerId TEXT, workspaceId TEXT, lastUpdatedAt INTEGER, value TEXT, "
        "isArchived INTEGER, isSubagent INTEGER)"
    )
    now_ms = int(time.time() * 1000)
    cursor_ids = [f"cursor-fixture-{i}" for i in range(1, MULTI_SESSION_TEST_COUNT + 1)]
    con.execute(
        "INSERT INTO ItemTable VALUES (?, ?)",
        ("cursor/glass.selectedAgent", json.dumps(cursor_ids[0])),
    )
    con.execute(
        "INSERT INTO ItemTable VALUES (?, ?)",
        (
            "cloudAgentRepository.agents.fixture",
            json.dumps(
                [
                    {
                        "bcId": "cursor-cloud-fixture",
                        "name": "Observe Cursor cloud activity",
                        "status": 1,
                        "updatedAt": now_ms,
                        "isArchived": False,
                        "repoUrl": "github.com/example/cloud-project",
                        "modelDetails": {"modelName": "cursor-agent"},
                    }
                ]
            ),
        ),
    )
    for i, cursor_id in enumerate(cursor_ids):
        con.execute(
            "INSERT INTO composerHeaders VALUES (?, ?, ?, ?, 0, 0)",
            (
                cursor_id,
                "workspace-fixture",
                now_ms - i * 1000,
                json.dumps(
                    {
                        "name": f"Observe Cursor activity {i + 1}",
                        "unifiedMode": "agent",
                    }
                ),
            ),
        )
    con.commit()
    con.close()
    workspace = cursor_db.parent.parent / "workspaceStorage" / "workspace-fixture"
    workspace.mkdir(parents=True, exist_ok=True)
    (workspace / "workspace.json").write_text(
        '{"folder":"file:///Users/me/code/Pulse"}', encoding="utf-8"
    )
    cases.append(("cursor", cursor_db, lambda: A.emit_all("cursor", A.cursor_activities())))

    opencode_db = home / ".local" / "share" / "opencode" / "opencode.db"
    opencode_db.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(opencode_db)
    con.execute(
        "CREATE TABLE session "
        "(id TEXT, title TEXT, directory TEXT, tokens_input INTEGER, "
        "tokens_output INTEGER, time_updated INTEGER, time_archived INTEGER, "
        "model TEXT)"
    )
    con.execute(
        "CREATE TABLE part "
        "(session_id TEXT, time_updated INTEGER, data TEXT)"
    )
    for i in range(1, MULTI_SESSION_TEST_COUNT + 1):
        con.execute(
            "INSERT INTO session VALUES (?, ?, ?, ?, ?, ?, 0, ?)",
            (
                f"opencode-fixture-{i}",
                f"Observe OpenCode activity {i}",
                "/Users/me/code/Pulse",
                120 + i,
                30 + i,
                now_ms - i,
                '{"id":"fixture-model","providerID":"fixture"}',
            ),
        )
        con.execute(
            "INSERT INTO part VALUES (?, ?, ?)",
            (
                f"opencode-fixture-{i}",
                now_ms - i,
                json.dumps({"type": "tool", "tool": "read_file", "state": {"status": "completed"}}),
            ),
        )
        con.execute(
            "INSERT INTO part VALUES (?, ?, ?)",
            (
                f"opencode-fixture-{i}",
                now_ms - i + 1,
                json.dumps({"type": "step-finish", "reason": "stop"}),
            ),
        )
    con.commit()
    con.close()
    cases.append(("opencode", opencode_db, lambda: A.emit_all("opencode", A.opencode_activities())))

    saw_any = False
    scored_agents: dict[str, set[str]] = {}

    def observed_facts(row: list[str]) -> set[str]:
        facts: set[str] = {"activity", "evidence"}
        if row[COL_TASK]:
            facts.add("goal")
        if row[COL_CWD] or row[COL_PROJECT]:
            facts.add("workspace")
        if int(row[COL_TIN] or 0) or int(row[COL_TOUT] or 0):
            facts.add("tokens")
        if row[COL_TOOL]:
            facts.add("last_action")
        if row[5] == "pending":
            facts.add("wait")
        if int(row[COL_RECORDS] or 0):
            facts.add("records")
        if int(row[COL_STARTED] or 0):
            facts.add("session_age")
        if row[COL_PHASE]:
            facts.add("phase")
        if row[COL_OUTCOME]:
            facts.add("outcome")
        if row[COL_MODEL]:
            facts.add("model")
        if row[COL_MODE]:
            facts.add("mode")
        if int(row[COL_ERRORS] or 0):
            facts.add("failures")
        if int(row[COL_FILES] or 0):
            facts.add("files")
        if int(row[COL_CONTEXT] or 0):
            facts.add("context")
        if int(row[COL_PROGRESS_DONE] or 0) or int(row[COL_PROGRESS_TOTAL] or 0):
            facts.update(("progress", "turns"))
        if int(row[9] or 0) or int(row[10] or 0):
            facts.add("subagents")
        return facts

    for name, where, block in cases:
        try:
            rows = capture(block)
        except Exception as exc:  # a collector must never take the scan down
            return fail(f"{name} collector raised {type(exc).__name__}: {exc}")
        if not rows:
            return fail(f"{name}: source-shaped fixture produced no row from {where}")
        saw_any = True
        row = rows[0]
        if name == "cursor":
            expected_cursor_rows = MULTI_SESSION_TEST_COUNT + 1
            if len(rows) != expected_cursor_rows:
                return fail(
                    f"Cursor emitted {len(rows)} active sessions; "
                    f"expected {expected_cursor_rows}"
                )
            if len({row[COL_SESSION] for row in rows}) != expected_cursor_rows:
                return fail(f"Cursor active sessions collapsed during emission: {rows}")
            cloud = next(
                (row for row in rows if row[COL_SESSION] == "cursor-cloud-fixture"),
                None,
            )
            if (
                cloud is None
                or cloud[COL_PHASE] != "running"
                or cloud[COL_MODE] != "cloud"
                or cloud[COL_PROJECT] != "cloud-project"
            ):
                return fail(f"Cursor cloud session facts were not merged: {cloud}")
            local_rows = [
                row for row in rows
                if row[COL_SESSION] != "cursor-cloud-fixture"
            ]
            if any(row[COL_MODE] != "local" for row in local_rows):
                return fail(f"Cursor local session mode was not preserved: {local_rows}")
        if name in {"aider", "opencode"}:
            if len(rows) != MULTI_SESSION_TEST_COUNT:
                return fail(
                    f"{name} emitted {len(rows)} active sessions; "
                    f"expected {MULTI_SESSION_TEST_COUNT}"
                )
            if len({row[COL_SESSION] for row in rows}) != MULTI_SESSION_TEST_COUNT:
                return fail(f"{name} active sessions collapsed during emission: {rows}")
        if name == "opencode":
            if any(row[COL_MODEL] != "fixture-model" for row in rows):
                return fail(f"OpenCode model facts were not surfaced: {rows}")
            if any(row[COL_TOOL] != "read_file" for row in rows):
                return fail(f"OpenCode last-action facts were not surfaced: {rows}")
            if any(row[COL_PHASE] != "turn_complete" or row[COL_OUTCOME] != "completed" for row in rows):
                return fail(f"OpenCode lifecycle facts were not surfaced: {rows}")
        if name == "warp_agent":
            if row[COL_TASK] != "Inspect Warp Agent telemetry":
                return fail(f"Warp SQLite conversation title was not surfaced: {row}")
            if row[COL_CWD] != "/Users/me/code/Pulse" or row[COL_PROJECT] != "Pulse":
                return fail(f"Warp SQLite workspace was not surfaced: {row}")
            if row[COL_TOOL] != "run_command" or row[COL_MODEL] != "warp-fixture-model":
                return fail(f"Warp tool/model evidence was not surfaced: {row}")
            if row[COL_PHASE] != "turn_complete" or row[COL_OUTCOME] != "completed":
                return fail(f"Warp lifecycle facts were not surfaced: {row}")
        if len(row) != COLUMNS:
            return fail(f"{name} emitted {len(row)} columns: {row}")
        if row[COL_EVIDENCE] != A.HARVEST_CONTRACTS[name]:
            return fail(
                f"{name}: emitted {row[COL_EVIDENCE]!r}, "
                f"contract says {A.HARVEST_CONTRACTS[name]!r}"
            )
        if name in {"claude", "amp", "droid", "codex", "grok"} \
                and row[COL_RECORDS] == "0" and row[COL_STARTED] == "0":
            return fail(
                f"{name}: the collector paid for the file scan and shipped 0/0 — "
                f"its row shaping drops the extras (row={row})"
            )
        if not row[COL_TASK] and not row[7]:
            return fail(f"{name}: fixture produced neither a goal nor a workspace: {row}")
        if int(row[8] or 0) <= 0:
            return fail(f"{name}: fixture produced no activity timestamp: {row}")
        facts = observed_facts(row)
        scored_agents[name] = facts
        declared_enhancements = set(A.OBSERVABILITY_CONTRACTS[name]) - {
            "goal", "workspace", "activity", "evidence",
        }
        if not facts.intersection(declared_enhancements):
            return fail(
                f"{name}: fixture proved only baseline detection; "
                f"none of its declared useful facts survived "
                f"(declared={sorted(declared_enhancements)}, observed={sorted(facts)})"
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
            if row[COL_MODEL] != "fixture-model":
                return fail(f"codex dropped the selected model from runtime facts: {row}")
            if row[COL_CONTEXT] != "32":
                return fail(f"codex dropped context occupancy from runtime facts: {row}")
        if name == "grok":
            if row[COL_TASK] != "Fix multipart upload":
                return fail(f"grok used tool output as its task: {row}")
            expected_facts = (
                "turn_complete", "completed", "grok-4.5", "grok-build-plan",
                "1", "3", "27", "4",
            )
            got = (
                row[COL_PHASE], row[COL_OUTCOME], row[COL_MODEL], row[COL_MODE],
                row[COL_ERRORS], row[COL_FILES], row[COL_CONTEXT], row[COL_PROGRESS_DONE],
            )
            if got != expected_facts:
                return fail(f"grok rich facts shifted or disappeared: {got}")
        if name == "command_code":
            if row[COL_TASK] != "Inspect Command Code session telemetry":
                return fail(
                    "Command Code promoted metadata/tool output instead of the user goal: "
                    f"{row}"
                )
            if row[COL_TOOL] != "read_file" or row[COL_MODEL] != "command-fixture-model":
                return fail(f"Command Code runtime facts were not surfaced: {row}")
            if row[COL_CWD] != "/Users/me/code/Pulse" or row[COL_PROJECT] != "Pulse":
                return fail(f"Command Code transcript cwd did not override storage metadata: {row}")

    if not saw_any:
        return fail("no collector produced a row; this gate is asserting nothing")
    if set(scored_agents) != set(A.OBSERVABILITY_CONTRACTS):
        return fail(
            "quality scorecards did not execute for every adapter "
            f"(missing={sorted(set(A.OBSERVABILITY_CONTRACTS) - set(scored_agents))})"
        )

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
        if rc := check_runtime_health_protocol():
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
    swift_builder = (
        ROOT / "PulseBar" / "Sources" / "PulseBar" / "SnapshotBuilder.swift"
    ).read_text(encoding="utf-8")
    swift_cap = re.search(r"maxSessionsPerAgent\s*=\s*(\d+)", swift_builder)
    if not swift_cap or A.MAX_SESSIONS_PER_AGENT <= int(swift_cap.group(1)):
        return fail(
            "the collector must emit beyond Swift's per-agent display budget "
            f"({A.MAX_SESSIONS_PER_AGENT} vs "
            f"{swift_cap.group(1) if swift_cap else 'missing'})"
        )
    low_cap_patterns = {
        "literal two-row break": r"len\(out\)\s*>=\s*[123]\b",
        "literal two-row slice": r"out\[:[123]\]",
        "low extension-cache limit": r"harvest_extension_storage\([^\n]*limit\s*=\s*[123]\b",
        "low home-session limit": r"home_dir_activities\([^\n]*limit\s*=\s*[123]\b",
    }
    for label, pattern in low_cap_patterns.items():
        if re.search(pattern, source):
            return fail(
                f"{label} bypasses the product-wide "
                f"{A.MAX_SESSIONS_PER_AGENT}-session budget"
            )
    for line in source.splitlines():
        if "recent_files_under(" in line and "def recent_files_under" not in line and "limit=" in line:
            if "limit=MAX_SESSIONS_PER_AGENT" not in line:
                return fail(f"adapter scan has a private session cap: {line.strip()}")
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

    support_model = (
        ROOT / "PulseBar" / "Sources" / "PulseBar" / "Models.swift"
    ).read_text(encoding="utf-8")
    support_store = (
        ROOT / "PulseBar" / "Sources" / "PulseBar" / "StatusStore.swift"
    ).read_text(encoding="utf-8")
    support_contract = {
        "goal fact": "hasGoal,",
        "workspace fact": "hasWorkspace,",
        "activity fact": "hasActivity,",
        "evidence fact": "evidence != nil || processDetected,",
        "conditional Waiting": "agent.waitingSource != .none, !waitingSignalReady",
    }
    for label, fragment in support_contract.items():
        if fragment not in support_model:
            return fail(f"support health lost its {label} contract")
    fact_sources = {
        "goal": "hasGoal: rows.contains { $0.usefulTask != nil }",
        "workspace": "hasWorkspace: rows.contains { !$0.displayPath.isEmpty }",
        "activity": "$0.harvestMs > 0 && $0.observationSource != .process",
    }
    for label, fragment in fact_sources.items():
        if fragment not in support_store:
            return fail(f"support health no longer derives the {label} fact from runtime rows")

    if set(A.HARVEST_CONTRACTS) != {
        "claude", "codex", "cursor", "grok", "pi", "amp", "aider", "gemini",
        "copilot", "opencode", "goose", "openhands", "continue", "droid",
        "command_code", "kimi", "amazon_q", "cline", "roo", "cascade",
        "windsurf", "augment", "zed_agent", "trae", "warp_agent", "kilo",
        "devin", "kiro", "junie", "replit", "antigravity",
    }:
        return fail("collector evidence contracts do not cover all 31 harvest agents")
    if set(A.OBSERVABILITY_CONTRACTS) != set(A.HARVEST_CONTRACTS):
        return fail("observability contracts do not cover the same 31 agents")
    declared_sources = set(A.COLLECTOR_SOURCE_ROOTS) | set(A.COLLECTOR_COMMANDS)
    if declared_sources != set(A.HARVEST_CONTRACTS):
        missing = sorted(set(A.HARVEST_CONTRACTS) - declared_sources)
        extra = sorted(declared_sources - set(A.HARVEST_CONTRACTS))
        return fail(
            "source-presence declarations do not cover the same 31 agents "
            f"(missing={missing}, extra={extra})"
        )
    baseline = {"goal", "workspace", "activity", "evidence"}
    thin = {
        agent: sorted(baseline - set(facts))
        for agent, facts in A.OBSERVABILITY_CONTRACTS.items()
        if not baseline.issubset(facts)
    }
    if thin:
        return fail(f"agents without the minimum useful observation: {thin}")
    shallow = {
        agent: sorted(set(facts) - baseline)
        for agent, facts in A.OBSERVABILITY_CONTRACTS.items()
        if len(set(facts) - baseline) < 2
    }
    if shallow:
        return fail(f"agents without two adapter-specific useful facts: {shallow}")
    print(
        f"harvest stats OK — {COLUMNS} columns · 31 evidence contracts · "
        "31 quality scorecards · 31 end-to-end collector fixtures"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
