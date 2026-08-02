#!/usr/bin/env python3
"""Best-effort local harvest of agent task/tokens/tools/skills for Pulse.
Prints one TSV line per session/agent:
  agent_id<TAB>task<TAB>tokens_in<TAB>tokens_out<TAB>last_tool<TAB>last_skill<TAB>project<TAB>cwd
  <TAB>mtime_ms<TAB>sub_run<TAB>sub_total<TAB>session_id<TAB>records<TAB>started_ms
"""
from __future__ import annotations

import glob
import json
import os
import re
import signal
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

HOME = Path.home()

# One product-wide safety budget. It is deliberately much larger than the
# tray's eight-row default fold: visual density is not a detection limit.
#
# Keep candidate scans wider than the output budget so an archived, draft, or
# malformed record does not prevent a later active session from being found.
# The collector deliberately emits more than the tray will render. Swift keeps
# the newest 32 per Agent and counts the remainder, so "32 shown" never means
# "Pulse stopped looking at 32". This is an ingestion safety budget, not UI.
MAX_SESSIONS_PER_AGENT = 64
SESSION_CANDIDATE_LIMIT = MAX_SESSIONS_PER_AGENT * 2

# Bytes the whole scan may spend counting records, across every collector.
#
# The per-file cap alone was not a bound: nineteen call sites, several looping
# over eight or ten files each, could in principle read hundreds of megabytes
# inside the bounded harvest window (`ActivityHarvest.harvestTimeoutSec`). On
# timeout the partial output is treated as a good scan, so a slow collector
# does not just lose its own row — it can drop every collector after it. That
# breaks "one agent's harvest must never blind the others".
SCAN_READ_BUDGET_BYTES = 24_000_000
_scan_bytes_spent = 0
COLLECTOR_TIMEOUT_SEC = 0.8
COLLECTOR_TIMEOUT_OVERRIDES = {
    # These adapters perform bounded reverse transcript or SQLite reads. Their
    # cold path is legitimately wider than a simple JSON/cache adapter.
    "codex": 1.4,
    "cursor": 1.2,
    "aider": 1.0,
}


class CollectorTimeoutError(TimeoutError):
    pass


def _collector_timeout(_signum, _frame) -> None:
    raise CollectorTimeoutError("adapter deadline exceeded")

_SENSITIVE_RULES = (
    (re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{12,}\b", re.I), "••••"),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{12,}\b", re.I), "••••"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{12,}\b", re.I), "••••"),
    (re.compile(r"\bxox[a-z]-[A-Za-z0-9-]{12,}\b", re.I), "••••"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "••••"),
    (
        re.compile(r"\b(Bearer\s+)[A-Za-z0-9._~+/\-=]{8,}", re.I),
        r"\1••••",
    ),
    (
        re.compile(
            r"""\b((?:api[_-]?key|access[_-]?token|auth[_-]?token|secret|password|passwd|token)\s*[:=]\s*['"]?)[^\s'";,]{8,}""",
            re.I,
        ),
        r"\1••••",
    ),
    (re.compile(r"(https?://[^/\s:@]+:)[^@\s/]+@", re.I), r"\1••••@"),
    (re.compile(r"""(\b(?:ssh\s+)?-i\s+)(?:~|/)[^\s'"]+""", re.I), r"\1••••"),
    (
        re.compile(
            r"-----BEGIN[ A-Z0-9_-]*PRIVATE KEY-----.*?-----END[ A-Z0-9_-]*PRIVATE KEY-----",
            re.I | re.S,
        ),
        "••••",
    ),
)


def redact_sensitive(value: str) -> str:
    """Remove credential-shaped content before a value crosses the TSV wire."""
    result = value or ""
    for pattern, replacement in _SENSITIVE_RULES:
        result = pattern.sub(replacement, result)
    return result


def _spend_scan_budget(size: int) -> bool:
    """Reserve `size` bytes of the scan-wide read budget."""
    global _scan_bytes_spent
    if _scan_bytes_spent + size > SCAN_READ_BUDGET_BYTES:
        return False
    _scan_bytes_spent += size
    return True


def newest(paths: list[str], limit: int = 1) -> list[Path]:
    files = [Path(p) for p in paths if Path(p).is_file()]
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return files[:limit]


def short_project(name: str) -> str:
    """Turn Claude-style encoded cwd or a path into a short folder name."""
    s = (name or "").strip().replace("\\", "/")
    if not s:
        return ""
    # Encoded Claude project dir: -Users-me-code-Pulse → Pulse
    if s.startswith("-") and "/" not in s and " " not in s:
        parts = [p for p in s.split("-") if p]
        # Drop common home roots: Users/<user>/...
        if len(parts) >= 3 and parts[0].lower() in ("users", "home"):
            parts = parts[2:]
        elif len(parts) >= 2 and parts[0].lower() in ("users", "home"):
            parts = parts[1:]
        if parts:
            return parts[-1][:48]
        return s[:48]
    # Plain path
    base = s.rstrip("/").split("/")[-1]
    if base in (".", "..", ""):
        return ""
    # Skip opaque hashes
    if re.fullmatch(r"[0-9a-f]{16,}", base, re.I):
        return ""
    return base[:48]


def bounded_sequence(value: list, limit: int = SESSION_CANDIDATE_LIMIT) -> list:
    """Keep both ends of a large session list within the parse budget.

    Vendors differ on ordering: some append the newest session, others place
    it first. Taking only `value[:N]` made a large shared cache look idle when
    its active records lived at the tail. A head/tail sample preserves both
    conventions while keeping recursive JSON walks bounded.
    """
    if len(value) <= limit:
        return value
    half = max(1, limit // 2)
    return list(value[:half]) + list(value[-half:])


def decode_claude_project_dir(name: str) -> str:
    """Best-effort: -Users-me-code-Pulse → /Users/me/code/Pulse"""
    s = (name or "").strip()
    if not (s.startswith("-") and "/" not in s):
        return ""
    parts = [p for p in s.split("-") if p]
    if not parts:
        return ""
    # Heuristic: Users/<user>/... on macOS
    if parts[0].lower() == "users" and len(parts) >= 2:
        return "/" + "/".join(parts)
    if parts[0].lower() == "home" and len(parts) >= 2:
        return "/" + "/".join(parts)
    return ""


def tail_bytes(path: Path, n: int = 400_000) -> str:
    """Read at most the last `n` bytes.

    This used to be `path.read_bytes()[-n:]` — it pulled entire session files
    into memory before slicing. Claude `.jsonl` transcripts reach tens of MB and
    this runs on every probe tick, so seek to the tail instead.
    """
    try:
        with path.open("rb") as f:
            try:
                size = os.fstat(f.fileno()).st_size
            except OSError:
                size = 0
            if size > n:
                f.seek(-n, os.SEEK_END)
            data = f.read(n)
        return data.decode("utf-8", errors="replace")
    except OSError:
        return ""


def head_tail_text(path: Path, head_n: int = 96_000, tail_n: int = 400_000) -> str:
    """Read stable session metadata and recent activity with a hard byte bound.

    Session metadata (cwd, repository, session id) is normally written once at
    the start of JSONL files, while the useful live facts are at the end. A
    tail-only read silently loses the former on long sessions and makes the UI
    fall back to an opaque UUID. Keep both ends without reading the full file.

    Torn boundary records are removed. Structured readers below must never join
    two unrelated fragments into a plausible JSON object.
    """
    try:
        with path.open("rb") as f:
            size = os.fstat(f.fileno()).st_size
            if size <= head_n + tail_n:
                data = f.read()
                return data.decode("utf-8", errors="replace")

            head = f.read(head_n)
            f.seek(-tail_n, os.SEEK_END)
            tail = f.read(tail_n)

        head_cut = head.rfind(b"\n")
        if head_cut >= 0:
            head = head[: head_cut + 1]
        tail_cut = tail.find(b"\n")
        if tail_cut >= 0:
            tail = tail[tail_cut + 1 :]
        return (head + tail).decode("utf-8", errors="replace")
    except OSError:
        return ""


def json_records(text: str) -> list[object]:
    """Decode complete JSON/JSONL records, ignoring bounded-read fragments."""
    if not text:
        return []
    records: list[object] = []
    for raw in text.splitlines():
        raw = raw.strip()
        if not raw.startswith(("{", "[")):
            continue
        try:
            records.append(json.loads(raw))
        except Exception:
            continue
    if records:
        return records
    stripped = text.strip()
    if stripped.startswith(("{", "[")):
        try:
            return [json.loads(stripped)]
        except Exception:
            pass
    return []


def extract_field(text: str, key: str) -> str | None:
    # "key":"value" with JSON string escapes
    m = re.search(rf'"{re.escape(key)}"\s*:\s*"((?:\\.|[^"\\])*)"', text)
    if not m:
        return None
    return decode_json_string(m.group(1))


def decode_json_string(raw: str) -> str:
    """Decode a JSON string body without mojibaking literal UTF-8/CJK."""
    try:
        return json.loads(f'"{raw}"')
    except json.JSONDecodeError:
        # Fallback: treat as latin-1 then unicode-escape (handles \\uXXXX only)
        try:
            return raw.encode("latin-1", errors="backslashreplace").decode(
                "unicode_escape", errors="replace"
            )
        except Exception:
            return raw


def last_usage_tokens(text: str) -> tuple[int, int]:
    """Last message `usage` block — session context size, not sum of every turn."""
    tin = tout = 0
    for m in re.finditer(r'"usage"\s*:\s*\{([^}]{0,500})\}', text):
        block = m.group(1)
        im = re.search(r'"(?:input_tokens|input)"\s*:\s*(\d+)', block)
        om = re.search(r'"(?:output_tokens|output)"\s*:\s*(\d+)', block)
        cm = re.search(r'"cache_read_input_tokens"\s*:\s*(\d+)', block)
        if im:
            tin = int(im.group(1))
            if cm:
                tin += int(cm.group(1))
        if om:
            tout = int(om.group(1))
    return tin, tout


def last_model_name(text: str) -> str:
    """Read the latest explicit model field from a known session transcript."""
    names = re.findall(
        r'"(?:model|modelId|model_id|currentModel|current_model)"\s*:\s*"([^"\n]{1,96})"',
        text or "",
    )
    return redact_sensitive(names[-1].strip()) if names else ""


def sum_int_fields(text: str, key: str) -> int:
    total = 0
    for m in re.finditer(rf'"{re.escape(key)}"\s*:\s*(\d+)', text):
        total += int(m.group(1))
    return total


def token_usage_totals(text: str) -> tuple[int, int]:
    """Best-effort token totals across common snake/camel-case schemas."""
    input_keys = ("input_tokens", "prompt_tokens", "inputTokens", "promptTokens")
    output_keys = ("output_tokens", "completion_tokens", "outputTokens", "completionTokens")

    def total(keys: tuple[str, ...]) -> int:
        pattern = "|".join(re.escape(key) for key in keys)
        return sum(int(match.group(1)) for match in re.finditer(rf'"(?:{pattern})"\s*:\s*(\d+)', text))

    return total(input_keys), total(output_keys)


def last_tool_name(text: str) -> str:
    names = re.findall(r'"type"\s*:\s*"tool_use"[\s\S]{0,200}?"name"\s*:\s*"([^"]+)"', text)
    if names:
        return names[-1]
    names = re.findall(
        r'"name"\s*:\s*"(exec_command|apply_patch|Bash|Read|Write|Edit|Skill|WebFetch|WebSearch|Glob|Grep)"',
        text,
    )
    if names:
        return names[-1]
    m = list(re.finditer(r'"name"\s*:\s*"([A-Za-z_][A-Za-z0-9_]{1,40})"', text))
    skip = {"type", "role", "message", "content", "sessionId", "parentUuid"}
    for hit in reversed(m):
        if hit.group(1) not in skip:
            return hit.group(1)
    return ""


TOOL_CALL_TYPES = {
    "tool_use",
    "tool_call",
    "toolcall",
    "custom_tool_call",
    "function_call",
    "functioncall",
    "mcp_tool_call",
}

TOOL_RESULT_TYPES = {
    "tool_result",
    "tool_call_output",
    "custom_tool_call_output",
    "function_call_output",
    "function_response",
    "mcp_tool_call_end",
}


def _tool_use_names(value) -> list[str]:
    """Every explicit tool-call name, never a nested argument or result."""
    found: list[str] = []

    def walk(node) -> None:
        if isinstance(node, dict):
            kind = str(node.get("type") or "").replace("-", "_").lower()
            if kind in TOOL_RESULT_TYPES:
                return
            if kind in TOOL_CALL_TYPES:
                name = node.get("name")
                if not isinstance(name, str):
                    function = node.get("function")
                    if isinstance(function, dict):
                        name = function.get("name")
                if isinstance(name, str) and name.strip():
                    found.append(name.strip())
            for child in node.values():
                walk(child)
        elif isinstance(node, list):
            for child in node:
                walk(child)

    walk(value)
    return found


def last_tool_name_strict(text: str, records: list[object] | None = None) -> str:
    """The tool a transcript last recorded, read rather than pattern-matched.

    This existed to stop the loose extractor guessing, and then guessed anyway.
    Its first tier was `"type":"tool_use"` followed by *any* `"name"` within two
    hundred characters, which is not the same claim at all:

        {"type":"tool_use","input":{"name":"production"}}   -> "production"
        {"type":"tool_use","id":"x"}\n{"role":"user","name":"alice"} -> "alice"

    The first reads a nested argument; the second reaches into the *next*
    record. Both were shown as "this agent is currently running X". The gate
    that was supposed to prevent exactly this only exercised the fallback tier,
    because none of its four blobs began with a `tool_use`.

    So the record is decoded and inspected: a name counts only when it is a
    string on the same dictionary that carries `type == "tool_use"`. Nesting
    cannot smuggle one in and a neighbouring record cannot lend one.

    Transcripts are read newest-first, because the last tool is the point.
    """
    if not text:
        return ""

    for obj in reversed(records if records is not None else json_records(text)):
        names = _tool_use_names(obj)
        if names:
            return names[-1][:40]

    # Compatibility tier: a name we recognise as a tool, on a key that means
    # "tool". Bounded by a whitelist, so it cannot invent a new one — but it
    # does match a `tool_result` as readily as a `tool_use`, which is why this
    # column is *last* tool and not *running* tool. Nothing here can tell you
    # whether the process is still executing it.
    names = re.findall(
        r'"(?:name|tool|toolName|tool_name)"\s*:\s*"'
        r"(exec_command|apply_patch|shell|terminal|Bash|Read|Write|Edit|MultiEdit|"
        r"NotebookEdit|Skill|Task|WebFetch|WebSearch|Glob|Grep|str_replace_editor|"
        r'run_command|read_file|write_file|edit_file|search_files|list_files)"',
        text,
    )
    if names:
        return names[-1][:40]
    return ""


def semantic_phase_from_events(
    text: str, records: list[object] | None = None
) -> str:
    """Read an explicit current phase from ordered lifecycle events.

    A last tool name is historical evidence, not proof that the tool is still
    running. Calls are therefore considered current only until a matching tool
    result arrives. Explicit permission/completion/phase events remain valid
    because they describe lifecycle state rather than a guessed activity.
    """
    pending: dict[str, str] = {}
    unkeyed_tool = ""
    explicit = ""

    def tool_phase(name: str, event: dict) -> str:
        low = (name or "").lower()

        def name_has(*tokens: str) -> bool:
            # Match tool-name components, not arbitrary substrings: `latest`
            # must not become Testing, and `write_stdin` is terminal plumbing,
            # not an Editing action. Underscores and dashes are intentional
            # boundaries here.
            return any(
                low == token or re.search(rf"(?<![a-z]){re.escape(token)}(?![a-z])", low)
                for token in tokens
            )

        # Generic shell/exec tools carry no useful meaning by name. Structured
        # arguments can still yield a high-confidence *role* without exposing
        # the command, path, tool identifier, or skill name to the UI.
        try:
            # Codex and a few desktop agents serialize the shell request inside
            # a JSON string (`input: "...cmd:\\"rg ..."`). Looking only for a
            # literal `"rg ` therefore degraded every such call to `working`.
            # Normalize one escaping layer before matching command intent; the
            # command itself is never emitted, only its high-confidence role.
            args = json.dumps(event, ensure_ascii=False).lower()
            args = args.replace('\\\\"', '"').replace('\\n', ' ')
        except Exception:
            args = ""
        if any(re.search(pattern, args) for pattern in (
            r"\bgh\s+release\b", r"\bgit\s+push\b", r"\bnpm\s+publish\b",
            r"\bcargo\s+publish\b",
        )):
            return "publishing"
        if any(re.search(pattern, args) for pattern in (
            r"\bswift\s+test\b", r"\bpytest\b", r"\bnpm\s+test\b",
            r"\bpnpm\s+test\b", r"\byarn\s+test\b", r"\bxcodebuild\s+test\b",
            r"\bcargo\s+test\b", r"\bgo\s+test\b",
        )):
            return "testing"
        if any(re.search(pattern, args) for pattern in (
            r"\bswift\s+build\b", r"\bxcodebuild\b", r"\bnpm\s+run\s+build\b",
            r"\bpnpm\s+build\b", r"\byarn\s+build\b", r"\bcargo\s+build\b",
            r"\bgo\s+build\b",
        )):
            return "building"
        if any(re.search(pattern, args) for pattern in (
            r"\bapply_patch\b", r"\bgit\s+apply\b", r"\bperl\s+-pi\b", r"\bsed\s+-i\b",
        )):
            return "editing"
        if any(re.search(pattern, args) for pattern in (
            r"\brg(?:\s|$)", r"\bgrep(?:\s|$)", r"\bfind(?:\s|$)",
            r"\bls(?:\s|$)", r"\bsed\s+-n\b", r"\bgit\s+(?:diff|status|show)\b",
            r"\bhead(?:\s|$)", r"\btail(?:\s|$)",
        )):
            return "reading"

        # Only now use the tool name. This is a fallback for vendors that do
        # not include structured arguments; a shell command above always wins
        # over a generic wrapper such as `write_stdin` or `exec_command`.
        if name_has("plan", "todo", "update_plan"):
            return "planning"
        if name_has("search", "web", "browser", "fetch"):
            return "researching"
        if name_has("test", "verify", "check"):
            return "testing"
        if name_has("build"):
            return "building"
        if name_has("edit", "patch", "apply_patch", "write_file", "write_text"):
            return "editing"
        if name_has("read", "glob", "grep", "view_image", "screenshot"):
            return "reading"
        return "working"

    def walk(value):
        nonlocal explicit, unkeyed_tool
        if isinstance(value, list):
            for item in value:
                walk(item)
            return
        if not isinstance(value, dict):
            return
        typ = str(
            value.get("type") or value.get("event") or value.get("kind") or ""
        ).lower()
        if typ in ("phase_changed", "phase_change"):
            phase = str(value.get("phase") or value.get("state") or "").strip()
            if phase:
                explicit = phase[:64]
        elif typ in (
            "permission_requested", "permission_request", "tool_permission",
            "approval_requested", "input_requested", "ask_user",
        ):
            explicit = "waiting_permission"
        elif typ in (
            "turn_complete", "turn_completed", "task_complete", "task_completed",
            "turn_ended", "task_ended",
        ):
            explicit = "turn_complete"
            pending.clear()
            unkeyed_tool = ""
        elif typ in ("response_started", "message_stream_started", "responding"):
            explicit = "responding"
        elif typ in (
            "tool_use", "custom_tool_call", "function_call", "tool_call",
            "tool_started",
        ):
            fn = value.get("function") if isinstance(value.get("function"), dict) else {}
            name = str(
                value.get("name") or value.get("tool_name")
                or value.get("toolName") or fn.get("name") or ""
            ).strip()
            if name:
                call_id = str(
                    value.get("id") or value.get("call_id")
                    or value.get("tool_use_id") or ""
                ).strip()
                phase = tool_phase(name, value)
                if call_id:
                    pending[call_id] = phase
                else:
                    unkeyed_tool = phase
                explicit = ""
        elif typ in (
            "tool_result", "tool_completed", "custom_tool_call_output",
            "function_call_output", "tool_call_output",
        ):
            call_id = str(
                value.get("call_id") or value.get("tool_use_id")
                or value.get("id") or ""
            ).strip()
            if call_id:
                pending.pop(call_id, None)
            else:
                unkeyed_tool = ""
        for child in value.values():
            if isinstance(child, (dict, list)):
                walk(child)

    if records is None:
        for line in text.splitlines():
            line = line.strip()
            if not line.startswith(("{", "[")):
                continue
            try:
                walk(json.loads(line))
            except Exception:
                continue
    else:
        for record in records:
            walk(record)
    if pending:
        return list(pending.values())[-1]
    if unkeyed_tool:
        return unkeyed_tool
    return explicit

def last_skill_name(text: str) -> str:
    """Return an explicitly invoked skill, never a path that happens to contain `skills/`.

    Skill package paths and helper script names are implementation detail. The
    previous path fallback turned `skills/.../user_context_preflight.py` into a
    user-facing "skill", even though no record claimed that it was invoked.
    """
    m = re.findall(r'"name"\s*:\s*"Skill"[\s\S]{0,300}?"skill"\s*:\s*"([^"]+)"', text)
    if m:
        return m[-1]
    m = re.findall(r'"name"\s*:\s*"Skill"[\s\S]{0,300}?"name"\s*:\s*"([^"]+)"', text)
    if m:
        return m[-1]
    return ""


def iso_time_ms(value) -> int:
    """ISO-8601 string → epoch milliseconds, or unknown."""
    if not isinstance(value, str) or not value.strip():
        return 0
    try:
        return int(datetime.fromisoformat(value.strip().replace("Z", "+00:00")).timestamp() * 1000)
    except (TypeError, ValueError, OverflowError):
        return 0


def normalize_time_ms(value) -> int:
    """Normalize vendor timestamps without treating a read time as activity.

    Agent stores are inconsistent: SQLite-backed IDEs have shipped epoch
    seconds, milliseconds, microseconds, and ISO strings for the same field.
    A direct ``int(value)`` turns one string into a collector-wide exception,
    which is especially damaging for Cursor because all composer rows are
    discarded by its outer safety guard. Unknown or malformed values remain
    unknown (0); callers decide whether a row is still useful without a time.
    """
    if isinstance(value, bool):
        return 0
    if isinstance(value, (int, float)):
        try:
            raw = int(value)
        except (TypeError, ValueError, OverflowError):
            return 0
        if raw <= 0:
            return 0
        # Seconds, milliseconds, microseconds, then nanoseconds. Keep the
        # thresholds deliberately broad for vendor-specific future formats.
        while raw < 10_000_000_000:
            raw *= 1000
        while raw > 100_000_000_000_000:
            raw //= 1000
        return raw
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return 0
        try:
            return normalize_time_ms(float(text))
        except (TypeError, ValueError, OverflowError):
            return iso_time_ms(text)
    return 0


def meaningful_prompt(value) -> str:
    """Reject continuation buttons and transport envelopes as session goals."""
    title = clean_session_title(value)
    if not title:
        return ""
    low = re.sub(r"[\s.!！。?？]+", "", title.lower())
    if low in {
        "continue", "goon", "proceed", "resume", "keepgoing",
        "继续", "继续分析", "继续修复", "继续处理", "继续推进",
        "progress", "status", "statusupdate", "howisitgoing", "whatsprogress",
        "进展如何", "进度如何", "状态如何", "现在怎么样",
        "release", "publish", "ship", "发布", "合入发布",
    }:
        return ""
    return title


def clean_session_title(value) -> str:
    """Normalize a human-facing title and reject injected context envelopes."""
    if not isinstance(value, str):
        return ""
    title = " ".join(value.strip().split())
    if len(title) < 3:
        return ""
    low = title.lower()
    if low.startswith(("<environment_context", "<recommended_plugins", "<app-context")):
        return ""
    return title[:160]


def clean_codex_user_request(value) -> str:
    """Extract the user's request from Codex Desktop attachment envelopes.

    Codex Desktop prepends file metadata and appends an image transport block
    to the real prompt. That transport text is useful to the runtime, but it
    is not the task title a person should see in Pulse.
    """
    if not isinstance(value, str):
        return ""
    text = value.strip()
    marker = re.search(r"##\s+My request for Codex:\s*", text, re.I)
    if marker:
        text = text[marker.end() :]
    text = re.sub(r"<image\b[^>]*>[\s\S]*?</image>", " ", text, flags=re.I)
    text = re.sub(r"<image\b[^>]*/?>", " ", text, flags=re.I)
    text = re.sub(r"\[Image\s*#[^\]]*\]\([^)]*\)", " ", text, flags=re.I)
    return clean_session_title(text)


def _title_candidates(value) -> list[str]:
    """Title-like strings outside tool calls/results, in document order."""
    found: list[str] = []

    def walk(node) -> None:
        if isinstance(node, dict):
            kind = str(node.get("type") or "").replace("-", "_").lower()
            if kind in TOOL_CALL_TYPES or kind in TOOL_RESULT_TYPES:
                return
            for key in ("aiTitle", "customTitle", "title", "summary", "lastPrompt"):
                title = clean_session_title(node.get(key))
                if title:
                    found.append(title)
            for child in node.values():
                walk(child)
        elif isinstance(node, list):
            for child in node:
                walk(child)

    walk(value)
    return found


def session_title_from_text(text: str) -> str:
    """Last explicit session title that is not embedded in a tool payload."""
    found: list[str] = []
    for obj in json_records(text):
        found.extend(_title_candidates(obj))
    return found[-1] if found else ""


def codex_user_title(text: str) -> str:
    """Latest substantive user request from a Codex rollout."""
    found: list[str] = []
    # Tool result records can be hundreds of KB. Decode only lines that can
    # actually be user messages; parsing every recent tool event made the
    # background harvester scrape its 2.5 s deadline under App Nap.
    candidates: list[object] = []
    for raw in text.splitlines():
        if '"user_message"' not in raw and '"role":"user"' not in raw.replace(" ", ""):
            continue
        try:
            candidates.append(json.loads(raw))
        except Exception:
            continue
    for obj in candidates:
        if not isinstance(obj, dict):
            continue
        top_type = str(obj.get("type") or "")
        payload = obj.get("payload")
        if not isinstance(payload, dict):
            continue
        payload_type = str(payload.get("type") or "")
        if top_type == "event_msg" and payload_type == "user_message":
            title = clean_codex_user_request(payload.get("message"))
            if title:
                found.append(title)
            continue
        if top_type == "response_item" and payload_type == "message":
            if str(payload.get("role") or "") != "user":
                continue
            content = payload.get("content")
            if isinstance(content, str):
                title = clean_codex_user_request(content)
                if title:
                    found.append(title)
            elif isinstance(content, list):
                text_parts = [
                    str(part.get("text") or "")
                    for part in content
                    if isinstance(part, dict)
                    and str(part.get("type") or "") in ("input_text", "text")
                ]
                title = clean_codex_user_request(" ".join(text_parts))
                if title:
                    found.append(title)
    if not found:
        return ""
    # Status pings and one-word continuation commands are part of the same
    # task, not a new goal. Walk backwards to keep the latest substantial user
    # intent as the hero. If a session contains only a short command, keep it
    # rather than inventing a title.
    for title in reversed(found):
        if meaningful_prompt(title):
            return title
    return found[-1]


def codex_user_title_from_file(path: Path, max_bytes: int = 8_000_000) -> str:
    """Read a bounded rollout window and parse only real user-message lines."""
    try:
        size = path.stat().st_size
    except OSError:
        return ""
    if size <= max_bytes:
        try:
            return codex_user_title(path.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            return ""

    # A long tool result can exceed the old fixed 4 MB tail by itself. The
    # newest user request then vanished from the window and Pulse fell back to
    # the session-opening prompt — exactly when the user most needed to know
    # what a many-hour Agent was doing now. Walk bounded chunks backwards,
    # parsing only user-message lines, and stop at the newest substantive goal.
    newest_short = ""
    carried = b""
    position = size
    remaining = min(size, 24_000_000)
    try:
        with path.open("rb") as handle:
            while position > 0 and remaining > 0:
                take = min(2_000_000, position, remaining)
                position -= take
                remaining -= take
                handle.seek(position)
                data = handle.read(take) + carried

                # The first record starts in the previous (older) chunk.
                # Carry that fragment back so a user event split exactly at a
                # chunk boundary is reconstructed rather than silently lost.
                if position > 0:
                    newline = data.find(b"\n")
                    if newline < 0:
                        carried = data
                        continue
                    carried = data[:newline]
                    data = data[newline + 1 :]

                title = codex_user_title(data.decode("utf-8", errors="replace"))
                if meaningful_prompt(title):
                    return title
                if title and not newest_short:
                    newest_short = title
    except OSError:
        return ""

    # No substantive prompt was found in the bounded reverse scan. Preserve
    # the opening request as the honest stable fallback instead of promoting a
    # one-word "continue" or "publish" command to the row hero.
    try:
        with path.open("rb") as handle:
            opening = codex_user_title(
                handle.read(512_000).decode("utf-8", errors="replace")
            )
    except OSError:
        return ""
    return opening or newest_short


def codex_last_usage(
    text: str, records: list[object] | None = None
) -> tuple[int, int]:
    """Token usage for the latest model turn, not the whole rollout."""
    latest = (0, 0)
    for obj in records if records is not None else json_records(text):
        if not isinstance(obj, dict) or obj.get("type") != "event_msg":
            continue
        payload = obj.get("payload")
        if not isinstance(payload, dict) or payload.get("type") != "token_count":
            continue
        info = payload.get("info")
        if not isinstance(info, dict):
            continue
        usage = info.get("last_token_usage")
        if not isinstance(usage, dict):
            continue
        latest = (
            int(usage.get("input_tokens") or 0),
            int(usage.get("output_tokens") or 0),
        )
    return latest


def codex_runtime_facts(
    text: str, records: list[object] | None = None
) -> dict:
    """Extract explicit Codex model/context facts without guessing.

    Codex stores these in `turn_context` and `task_started`/`token_count`
    events rather than beside the user prompt. They are high-value operational
    signals: a model name explains what is running, while context usage warns
    before a long rollout becomes constrained. Missing fields remain unknown.
    """
    facts: dict = {}
    context_window = 0
    input_tokens = 0
    for obj in records if records is not None else json_records(text):
        if not isinstance(obj, dict):
            continue
        typ = str(obj.get("type") or "")
        payload = obj.get("payload")
        if not isinstance(payload, dict):
            payload = {}

        if typ == "turn_context":
            model = payload.get("model")
            if isinstance(model, str) and model.strip():
                facts["model"] = model.strip()[:64]
            mode = payload.get("collaboration_mode_kind")
            if isinstance(mode, str) and mode.strip() and mode.lower() != "default":
                facts["mode"] = mode.strip()[:64]
        elif typ == "session_meta":
            # Some Codex builds put the selected model on session metadata.
            model = payload.get("model") or payload.get("model_id")
            if isinstance(model, str) and model.strip() and "model" not in facts:
                facts["model"] = model.strip()[:64]

        event_type = str(payload.get("type") or "")
        if typ == "event_msg" and event_type == "task_started":
            raw_window = payload.get("model_context_window")
            if isinstance(raw_window, (int, float)) and raw_window > 0:
                context_window = int(raw_window)
        if typ == "event_msg" and event_type == "token_count":
            info = obj.get("info")
            if not isinstance(info, dict):
                info = payload.get("info")
            if isinstance(info, dict):
                raw_window = info.get("model_context_window")
                if isinstance(raw_window, (int, float)) and raw_window > 0:
                    context_window = int(raw_window)
                usage = info.get("last_token_usage")
                if isinstance(usage, dict):
                    raw_input = usage.get("input_tokens")
                    if isinstance(raw_input, (int, float)) and raw_input > 0:
                        input_tokens = int(raw_input)

    if context_window > 0 and input_tokens > 0:
        facts["context_pct"] = max(1, min(100, round(input_tokens * 100 / context_window)))
    return facts


FRESH_SEC = 45 * 60  # Claude session files older than this (and no live subs) are skipped
# A `pending` guess is a Waiting claim — only trust it on a very recently
# touched file, so a stale session can never sit lit as "needs you".
PENDING_FRESH_SEC = 5 * 60

def codex_has_unresolved_approval(text: str) -> bool:
    """True when rollout tail shows an approval/user request without a later resolution."""
    # Find last approval-ish event and last resolution-ish event by position.
    approval_pat = re.compile(
        r'"(?:type|subtype|method)"\s*:\s*"(?:exec_approval_request|apply_patch_approval_request|'
        r'patch_approval_request|command_approval_request|request_user_input|user_input_request|'
        r'pending_approval|approval_request|ApprovalRequest|item\.command_execution/request_approval|'
        r'item\.file_change/request_approval)"',
        re.I,
    )
    resolve_pat = re.compile(
        r'"(?:type|subtype|method)"\s*:\s*"(?:exec_approval_response|apply_patch_approval_response|'
        r'user_input_response|approval_resolved|approval_decision|ApprovalResponse|'
        r'item\.command_execution/approval_decision|item\.file_change/approval_decision)"',
        re.I,
    )
    # Also Codex sometimes uses nested "status":"pending" near approval.
    pending_blob = re.compile(r'"status"\s*:\s*"pending"', re.I)
    last_a = -1
    for m in approval_pat.finditer(text):
        last_a = m.start()
    last_r = -1
    for m in resolve_pat.finditer(text):
        last_r = m.start()
    if last_a >= 0 and last_a > last_r:
        return True
    # Fallback: pending status in last 8k of file near "approval"
    tail = text[-8000:]
    if "approval" in tail.lower() and pending_blob.search(tail):
        return True
    return False


def gemini_has_unresolved_ask(text: str) -> bool:
    """Detect AskUserQuestion / confirmation functionCall without a later user turn."""
    ask_pat = re.compile(
        r'"name"\s*:\s*"(?:AskUserQuestion|ask_user|confirm|confirmation|'
        r'request_user_confirmation)"',
        re.I,
    )
    user_pat = re.compile(r'"type"\s*:\s*"user"', re.I)
    last_ask = -1
    for m in ask_pat.finditer(text):
        last_ask = m.start()
    if last_ask < 0:
        # functionCall blocks
        for m in re.finditer(r'functionCall[\s\S]{0,200}?AskUser', text, re.I):
            last_ask = m.start()
    if last_ask < 0:
        return False
    last_user = -1
    for m in user_pat.finditer(text):
        last_user = m.start()
    return last_ask > last_user


def opencode_pending_skill() -> str:
    """OpenCode: pending tool states or recent permission rows → pending."""
    db = HOME / ".local/share" / "opencode" / "opencode.db"
    if not db.is_file():
        return ""
    try:
        import sqlite3

        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=0.4)
        try:
            now_ms = int(time.time() * 1000)
            # permission table with recent update
            try:
                row = con.execute(
                    "SELECT time_updated FROM permission ORDER BY time_updated DESC LIMIT 1"
                ).fetchone()
                if row and row[0]:
                    tu = int(row[0])
                    if tu < 10_000_000_000:
                        tu *= 1000
                    if now_ms - tu <= 30 * 60 * 1000:
                        return "pending"
            except Exception:
                pass
            # tool parts with non-completed status
            rows = con.execute(
                """
                SELECT data FROM part
                WHERE data LIKE '%"type":"tool"%'
                ORDER BY time_updated DESC LIMIT 40
                """
            ).fetchall()
            for (data,) in rows:
                try:
                    obj = json.loads(data)
                except Exception:
                    continue
                if obj.get("type") != "tool":
                    continue
                st = str((obj.get("state") or {}).get("status") or "").lower()
                tool = str(obj.get("tool") or "").lower()
                if st in ("pending", "running", "waiting") and tool in (
                    "permission",
                    "ask",
                    "question",
                    "confirm",
                    "bash",
                    "edit",
                    "write",
                    "patch",
                ):
                    # Only treat permission-like or explicitly pending
                    if st == "pending" or tool in ("permission", "ask", "question", "confirm"):
                        return "pending"
        finally:
            con.close()
    except Exception:
        return ""
    return ""



def file_mtime_ms(path: Path) -> int:
    try:
        return int(path.stat().st_mtime * 1000)
    except OSError:
        return 0


def claude_subagent_counts(session_file: Path) -> tuple[int, int]:
    """Count subagents for a session: (running, total).

    Layout: ~/.claude/projects/<proj>/<sessionId>/subagents/agent-*.jsonl
    Running ≈ mtime within 2 minutes (Claude Watch heuristic).
    """
    sub_dir = session_file.parent / session_file.stem / "subagents"
    if not sub_dir.is_dir():
        return 0, 0
    now = time.time()
    running = 0
    total = 0
    try:
        files = list(sub_dir.glob("agent-*.jsonl"))
    except OSError:
        return 0, 0
    for f in files:
        total += 1
        try:
            age = now - f.stat().st_mtime
        except OSError:
            continue
        if age <= 120:
            running += 1
    return running, total


def claude_task_progress() -> str:
    """Compact checklist from ~/.claude/tasks if present: e.g. tasks 2/5."""
    root = HOME / ".claude" / "tasks"
    if not root.is_dir():
        return ""
    done = pending = 0
    try:
        files = newest(glob.glob(str(root / "*" / "*.json")) + glob.glob(str(root / "*.json")), 40)
    except Exception:
        return ""
    for tf in files:
        try:
            obj = json.loads(tf.read_text(encoding="utf-8", errors="replace"))
        except Exception:
            continue
        st = str(obj.get("status") or "").lower()
        if st in ("completed", "done", "cancelled", "canceled"):
            done += 1
        elif st in ("in_progress", "pending", "active", "running"):
            pending += 1
    total = done + pending
    if total <= 0:
        return ""
    return f"tasks {done}/{total}"


def claude_activities() -> list[tuple[str, int, int, str, str, str, str, int, int, int]]:
    """Recent Claude sessions (distinct session files / projects).

    Tuple: task, tin, tout, tool, skill, project, cwd, mtime_ms, sub_run, sub_total
    """
    paths = glob.glob(str(HOME / ".claude" / "projects" / "*" / "*.jsonl"))
    files = newest(paths, SESSION_CANDIDATE_LIMIT)
    out: list[tuple[str, int, int, str, str, str, str, int, int, int]] = []
    seen: set[str] = set()
    task_hint = ""
    task_files = newest(glob.glob(str(HOME / ".claude" / "tasks" / "*" / "*.json")), 20)
    for tf in task_files:
        try:
            obj = json.loads(tf.read_text(encoding="utf-8", errors="replace"))
        except Exception:
            continue
        if obj.get("status") in ("in_progress", "pending", "active"):
            task_hint = obj.get("activeForm") or obj.get("subject") or task_hint
            break
        if not task_hint and obj.get("subject"):
            task_hint = obj.get("activeForm") or obj.get("subject")
    checklist = claude_task_progress()
    now = time.time()
    for f in files:
        try:
            age = now - f.stat().st_mtime
        except OSError:
            continue
        sub_run, sub_total = claude_subagent_counts(f)
        # Keep fresh sessions, or anything with live-looking subagents
        if age > FRESH_SEC and sub_run == 0:
            continue
        text = tail_bytes(f)
        project = short_project(f.parent.name)
        cwd = extract_field(text, "cwd") or extract_field(text, "projectDir") or ""
        if cwd:
            project = short_project(cwd) or project
        else:
            cwd = decode_claude_project_dir(f.parent.name)
        key = f.stem  # session id — allow two Claudes in same project
        if key in seen:
            continue
        seen.add(key)
        task = session_title_from_text(text) or (task_hint or "")
        # Prefer last usage snapshot (context size now) — never sum every turn.
        tin, tout = last_usage_tokens(text)
        tool = last_tool_name_strict(text)
        # Raw skill/package names are implementation detail. Checklist progress
        # is useful, but it has its own typed fields instead of overloading the
        # wait-signal column.
        skill = ""
        extra = session_stats(f, per_session=True)
        phase = semantic_phase_from_events(text)
        if phase:
            extra["phase"] = phase
        progress = re.fullmatch(r"tasks\s+(\d+)/(\d+)", checklist or "")
        if progress:
            extra["progress_done"] = int(progress.group(1))
            extra["progress_total"] = int(progress.group(2))
        mtime_ms = file_mtime_ms(f)
        if task or tin or tout or tool or skill or project or sub_total:
            out.append(
                (
                    task[:160],
                    tin,
                    tout,
                    tool[:48],
                    skill[:64],
                    project[:48],
                    (cwd or "")[:240],
                    mtime_ms,
                    sub_run,
                    sub_total,
                    f.stem,
                    extra,
                )
            )
        if len(out) >= MAX_SESSIONS_PER_AGENT:
            break
    return out

def codex_activities() -> list[tuple[str, int, int, str, str, str, str]]:
    paths = glob.glob(str(HOME / ".codex" / "sessions" / "*" / "*" / "*" / "rollout-*.jsonl"))
    files = newest(paths, SESSION_CANDIDATE_LIMIT)
    out: list[tuple[str, int, int, str, str, str, str]] = []
    seen: set[str] = set()
    for f in files:
        # Stable metadata comes from the head; dynamic events from the tail.
        # The task has its own sparse reader below so we do not parse megabytes
        # of tool output on every probe.
        # Codex desktop places the first `turn_context` (selected model and
        # context window) just after the large session metadata record. Keep a
        # little more head than the generic JSONL readers so that explicit
        # model evidence does not fall outside the bounded window.
        text = head_tail_text(f, 160_000, 600_000)
        # Never fall back to the generic title extractor here. MCP invocations
        # carry UI-only `title` strings ("Inspect settings") that are neither a
        # session title nor a user request.
        records = json_records(text)
        task = codex_user_title_from_file(f)
        tin, tout = codex_last_usage(text, records)
        tool = last_tool_name_strict(text, records)
        skill = ""
        cwd = extract_field(text, "cwd") or extract_field(text, "workdir") or ""
        project = short_project(cwd) if cwd else ""
        if not project:
            for key in ("repo_name", "repository", "project_name"):
                v = extract_field(text, key)
                if v:
                    project = short_project(v)
                    break
        key = f.stem  # rollout session file — distinguish same-project sessions
        if key in seen:
            continue
        seen.add(key)
        if codex_has_unresolved_approval(text):
            skill = "pending"
        if task or tin or tout or tool or skill or project:
            extra = session_stats(f, per_session=True)
            extra.update(codex_runtime_facts(text, records))
            # A rollout can contain hundreds of nested tool-result records.
            # Phase is a live signal, so the newest bounded slice is both more
            # useful and far cheaper than replaying the whole transcript.
            phase = semantic_phase_from_events(text, records[-80:])
            if phase:
                extra["phase"] = phase
            out.append(
                (
                    task,
                    tin,
                    tout,
                    tool[:48],
                    skill[:48],
                    project[:48],
                    (cwd or "")[:240],
                    file_mtime_ms(f),
                    f.stem,
                    extra,
                )
            )
        if len(out) >= MAX_SESSIONS_PER_AGENT:
            break
    return out


def workspace_cwd(workspace_id: str) -> str:
    if not workspace_id or workspace_id in ("empty-window",):
        return ""
    wj = HOME / "Library/Application Support/Cursor/User/workspaceStorage" / workspace_id / "workspace.json"
    if not wj.is_file():
        return ""
    try:
        folder = json.loads(wj.read_text(encoding="utf-8", errors="replace")).get("folder") or ""
    except Exception:
        return ""
    if folder.startswith("file://"):
        folder = folder[len("file://") :]
    # URL-decode lightly
    folder = folder.replace("%20", " ")
    return folder if folder.startswith("/") else ""


def path_from_composer_meta(meta: dict) -> str:
    ws = meta.get("workspaceIdentifier")
    if isinstance(ws, dict):
        uri = ws.get("uri") or {}
        if isinstance(uri, dict):
            p = uri.get("fsPath") or uri.get("path") or ""
            if p:
                return p
    dt = meta.get("draftTarget") or {}
    if isinstance(dt, dict):
        env = dt.get("environment") or {}
        if isinstance(env, dict):
            uri = env.get("uri") or {}
            if isinstance(uri, dict):
                p = uri.get("fsPath") or uri.get("path") or ""
                if p:
                    return p
    return ""


def cursor_activities() -> list[tuple[str, int, int, str, str, str, str]]:
    """Cursor local and cloud Agent sessions from its local state DB.

    Sources:
      - ItemTable cursor/glass.selectedAgent
      - composerHeaders (name, pending, recency, workspaceId)
      - ItemTable cloudAgentRepository.agents.* (cloud status/name/repository)

    Local rows remain observable for the current working block rather than
    disappearing after 30 minutes. Cloud rows use Cursor's explicit status:
    status 1 is running; status 2 is completed and only retained while recent,
    selected, or unread.
    """
    import sqlite3
    import time

    db = HOME / "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    if not db.is_file():
        return []
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    except Exception:
        return []
    try:
        now_ms = int(time.time() * 1000)
        local_visible_window_ms = 6 * 60 * 60 * 1000
        cloud_recent_window_ms = 45 * 60 * 1000
        selected = ""
        row = con.execute(
            "SELECT value FROM ItemTable WHERE key='cursor/glass.selectedAgent'"
        ).fetchone()
        if row and row[0]:
            selected = str(row[0]).strip().strip('"')

        local_rows = con.execute(
            """
            SELECT composerId, workspaceId, lastUpdatedAt, value
            FROM composerHeaders
            WHERE IFNULL(isArchived, 0) = 0 AND IFNULL(isSubagent, 0) = 0
            ORDER BY lastUpdatedAt DESC
            """
        ).fetchall()
        candidates: list[tuple] = []
        seen: set[str] = set()
        for cid, ws_id, lu, val in local_rows:
            if not cid or cid == "empty-state-draft":
                continue
            try:
                meta = json.loads(val) if val else {}
            except Exception:
                meta = {}
            if meta.get("isDraft"):
                continue
            pending = bool(meta.get("hasBlockingPendingActions") or meta.get("hasPendingPlan"))
            is_sel = bool(selected and cid == selected)
            hm = normalize_time_ms(lu)
            age = now_ms - hm if hm else 0
            age_ok = bool(hm and 0 <= age <= local_visible_window_ms)
            if not (is_sel or pending or age_ok):
                continue
            mode = meta.get("unifiedMode") or ""
            # Skip stale plain chat unless selected / pending
            if mode == "chat" and not is_sel and not pending:
                continue
            task = (meta.get("name") or meta.get("subtitle") or "").strip()[:160]
            cwd = workspace_cwd(str(ws_id or "")) or path_from_composer_meta(meta)
            project = short_project(cwd) if cwd else ""
            key = str(cid)
            if key in seen:
                continue
            seen.add(key)
            skill = "pending" if pending else ""
            # Always emit when selected/pending/recent — even without a title
            if not task and not project and not pending and not is_sel:
                continue
            if not task:
                task = "Agent session" if mode == "agent" else "Chat"
            # No lastUpdatedAt → don't stamp "now" (false Running freshness).
            if not lu:
                continue
            # `lastUpdatedAt` can be ISO text on older Cursor builds. The
            # normalized value is also the evidence timestamp shown by Pulse;
            # never substitute the collector read time for missing activity.
            if not hm:
                continue
            extra: dict = {"mode": "local"}
            context_pct = meta.get("contextUsagePercent")
            files_changed = meta.get("filesChangedCount")
            if isinstance(context_pct, (int, float)) and context_pct > 0:
                extra["context_pct"] = int(context_pct)
            if isinstance(files_changed, (int, float)) and files_changed > 0:
                extra["files"] = int(files_changed)
            candidates.append(
                (
                    task,
                    0,
                    0,
                    "",
                    skill,
                    project[:48],
                    (cwd or "")[:240],
                    hm,
                    str(cid),
                    extra,
                )
            )

        cloud_values = con.execute(
            "SELECT value FROM ItemTable WHERE key LIKE 'cloudAgentRepository.agents.%'"
        ).fetchall()
        for value_row in cloud_values:
            try:
                cloud_rows = json.loads(value_row[0] or "[]")
            except Exception:
                continue
            if not isinstance(cloud_rows, list):
                continue
            for meta in cloud_rows:
                if not isinstance(meta, dict):
                    continue
                sid = str(meta.get("bcId") or meta.get("id") or "")
                if not sid or sid in seen or bool(meta.get("isArchived")):
                    continue
                try:
                    status = int(meta.get("status"))
                except (TypeError, ValueError):
                    status = -1
                updated_ms = normalize_time_ms(meta.get("updatedAt"))
                selected_cloud = bool(selected and sid == selected)
                unread = bool(meta.get("isUnread"))
                recent_cloud = bool(
                    updated_ms and 0 <= now_ms - updated_ms <= cloud_recent_window_ms
                )
                running_cloud = status == 1
                if not (running_cloud or selected_cloud or unread or recent_cloud):
                    continue
                seen.add(sid)
                title = str(meta.get("name") or "Cursor Cloud Agent").strip()
                repo = str(meta.get("repoUrl") or "")
                project = short_project(repo)
                model_details = (
                    meta.get("modelDetails")
                    if isinstance(meta.get("modelDetails"), dict)
                    else {}
                )
                extra = {
                    "mode": "cloud",
                    "phase": "running" if running_cloud else "completed" if status == 2 else "",
                }
                model = str(model_details.get("modelName") or "")
                if model:
                    extra["model"] = model[:64]
                candidates.append(
                    (
                        title[:160],
                        0,
                        0,
                        "",
                        "",
                        project[:48],
                        "",
                        updated_ms or now_ms,
                        sid[:80],
                        extra,
                    )
                )

        candidates.sort(key=lambda item: int(item[7] or 0), reverse=True)
        return candidates[:MAX_SESSIONS_PER_AGENT]
    except Exception:
        return []
    finally:
        try:
            con.close()
        except Exception:
            pass


def grok_session_activity(active: Path, session: dict) -> tuple | None:
    """Shape one explicit Grok active-session record into a harvest row."""
    sid = str(session.get("session_id") or "")
    if not sid:
        return None
    cwd = session.get("cwd") or session.get("workspace") or session.get("path") or ""
    project = short_project(str(cwd)) if cwd else ""
    task = ""
    for d in (HOME / ".grok" / "sessions").rglob(sid):
        if not d.is_dir():
            continue
        if not project:
            project = short_project(d.name) or short_project(d.parent.name)
        plan = d / "plan.md"
        goal = d / "goal" / "plan.md"
        summary = d / "summary.json"
        signals = d / "signals.json"
        events = d / "events.jsonl"
        extra: dict = {}
        if plan.is_file():
            task = plan.read_text(encoding="utf-8", errors="replace").strip().splitlines()[0][:160]
        elif goal.is_file():
            task = goal.read_text(encoding="utf-8", errors="replace").strip().splitlines()[0][:160]
        elif summary.is_file():
            try:
                obj = json.loads(summary.read_text(encoding="utf-8", errors="replace"))
                task = meaningful_prompt(
                    obj.get("generated_title")
                    or obj.get("session_summary")
                    or obj.get("title")
                    or obj.get("summary")
                )[:160]
                extra["model"] = str(obj.get("current_model_id") or "")[:64]
                extra["mode"] = str(obj.get("agent_name") or "")[:64]
                extra["records"] = int(obj.get("num_messages") or 0)
                extra["started_ms"] = iso_time_ms(obj.get("created_at"))
            except Exception:
                pass
        if signals.is_file():
            try:
                sig = json.loads(signals.read_text(encoding="utf-8", errors="replace"))
                extra["errors"] = max(
                    int(sig.get("errorCount") or 0),
                    int(sig.get("toolFailureCount") or 0),
                )
                extra["files"] = int(sig.get("totalFilesTouched") or 0)
                extra["context_pct"] = int(sig.get("contextWindowUsage") or 0)
                extra["progress_done"] = int(sig.get("turnCount") or 0)
                if not extra.get("model"):
                    extra["model"] = str(sig.get("modelName") or sig.get("modelId") or "")[:64]
            except Exception:
                pass
        hist = d / "chat_history.jsonl"
        tools = skill = ""
        if hist.is_file():
            htext = tail_bytes(hist, 200_000)
            if not task:
                for record in reversed(json_records(htext)):
                    if not isinstance(record, dict):
                        continue
                    if str(record.get("role") or "").lower() not in ("user", "human"):
                        continue
                    candidate = meaningful_prompt(record.get("content"))
                    if candidate:
                        task = candidate[:160]
                        break
            tools = last_tool_name(htext)
            if text_looks_pending(htext):
                skill = "pending"
        if events.is_file():
            try:
                event_rows = json_records(tail_bytes(events, 240_000))
                last_phase = ""
                last_outcome = ""
                last_tool = ""
                for event in event_rows:
                    if not isinstance(event, dict):
                        continue
                    typ = str(event.get("type") or "")
                    if typ == "phase_changed":
                        last_phase = str(event.get("phase") or "")
                    elif typ in ("tool_started", "tool_completed"):
                        last_tool = str(event.get("tool_name") or last_tool)
                        if typ == "tool_completed":
                            last_outcome = str(event.get("outcome") or "")
                    elif typ == "turn_ended":
                        last_phase = "turn_complete"
                        last_outcome = str(event.get("outcome") or last_outcome)
                    elif typ == "permission_requested":
                        last_phase = "waiting_permission"
                if last_phase:
                    extra["phase"] = last_phase[:64]
                if last_outcome:
                    extra["outcome"] = last_outcome[:64]
                if last_tool:
                    tools = last_tool[:48]
            except Exception:
                pass
        return (
            task or "Grok session",
            0,
            0,
            tools,
            skill,
            project[:48],
            str(cwd)[:240],
            file_mtime_ms(events if events.is_file() else hist if hist.is_file() else active),
            sid[:80],
            extra,
        )
    # `active_sessions.json` is itself explicit runtime evidence. Keep the row
    # even if Grok has not flushed the richer session directory yet.
    return (
        "Grok session",
        0,
        0,
        "",
        "",
        project[:48],
        str(cwd)[:240],
        file_mtime_ms(active),
        sid[:80],
        {},
    )


def grok_activities() -> list[tuple]:
    active = HOME / ".grok" / "active_sessions.json"
    if not active.is_file():
        return []
    try:
        raw = json.loads(active.read_text(encoding="utf-8"))
    except Exception:
        return []
    sessions = raw if isinstance(raw, list) else raw.get("sessions", []) if isinstance(raw, dict) else []
    out: list[tuple] = []
    seen: set[str] = set()
    for session in sessions:
        if not isinstance(session, dict):
            continue
        sid = str(session.get("session_id") or "")
        if not sid or sid in seen:
            continue
        seen.add(sid)
        row = grok_session_activity(active, session)
        if row is not None:
            out.append(row)
        if len(out) >= MAX_SESSIONS_PER_AGENT:
            break
    return out


def grok_activity() -> tuple:
    """Backward-compatible single-row helper for older callers."""
    rows = grok_activities()
    return rows[0] if rows else ("", 0, 0, "", "", "", "", 0, "")


def pi_activities() -> list[tuple]:
    paths = glob.glob(str(HOME / ".pi" / "agent" / "sessions" / "*" / "*.jsonl"))
    files = newest(paths, SESSION_CANDIDATE_LIMIT)
    out: list[tuple] = []
    for f in files:
        text = tail_bytes(f)
        task = session_title_from_text(text) or extract_field(text, "text") or extract_field(text, "content") or ""
        tin = sum_int_fields(text, "input_tokens")
        tout = sum_int_fields(text, "output_tokens")
        if tin == 0 and tout == 0:
            tin, tout = token_usage_totals(text)
        if tin == 0 and tout == 0:
            tin, tout = last_usage_tokens(text)
        tool = last_tool_name_strict(text)
        skill = "pending" if text_looks_pending(text) else ""
        cwd = extract_field(text, "cwd") or extract_field(text, "workingDirectory") or ""
        project = short_project(cwd) if cwd else short_project(f.parent.name)
        sid = f.stem
        extra = session_stats(f, per_session=True)
        phase = semantic_phase_from_events(text)
        if phase:
            extra["phase"] = phase
        model = last_model_name(text)
        if model:
            extra["model"] = model
        out.append(
            (
                task[:160],
                tin,
                tout,
                tool[:48],
                skill[:48],
                project[:48],
                (cwd or "")[:240],
                file_mtime_ms(f),
                sid[:80],
                extra,
            )
        )
        if len(out) >= MAX_SESSIONS_PER_AGENT:
            break
    return out


def pi_activity() -> tuple:
    """Backward-compatible single-row helper for older callers."""
    rows = pi_activities()
    return rows[0] if rows else ("", 0, 0, "", "", "", "", 0, "")


def amp_activities() -> list[tuple[str, int, int, str, str, str, str]]:
    """Amp (Sourcegraph): threads/ + modern session.json + history.jsonl."""
    out: list[tuple[str, int, int, str, str, str, str]] = []
    seen: set[str] = set()
    share = HOME / ".local/share" / "amp"

    threads_dir = share / "threads"
    if threads_dir.is_dir():
        files = newest([str(p) for p in threads_dir.glob("T-*.json")] +
                       [str(p) for p in threads_dir.glob("*.json")], 6)
        for f in files:
            try:
                obj = json.loads(f.read_text(encoding="utf-8", errors="replace"))
            except Exception:
                continue
            if not isinstance(obj, dict):
                continue
            title = str(obj.get("title") or obj.get("name") or "").strip()
            cwd = ""
            for key in ("cwd", "workingDirectory", "directory", "workdir"):
                v = obj.get(key)
                if isinstance(v, str) and v:
                    cwd = v
                    break
            meta = obj.get("metadata") if isinstance(obj.get("metadata"), dict) else {}
            if not cwd:
                cwd = str(meta.get("cwd") or meta.get("workdir") or "")
            if not title:
                msgs = obj.get("messages") or obj.get("conversation") or []
                if isinstance(msgs, list):
                    for m in msgs:
                        if not isinstance(m, dict):
                            continue
                        role = str(m.get("role") or "")
                        if role != "user":
                            continue
                        content = m.get("content")
                        if isinstance(content, str):
                            title = content.strip()
                            break
                        if isinstance(content, list):
                            for part in content:
                                if isinstance(part, dict) and isinstance(part.get("text"), str):
                                    title = part["text"].strip()
                                    break
                            if title:
                                break
            project = short_project(cwd) if cwd else ""
            key = f"{project}|{title[:40]}"
            if key in seen:
                continue
            seen.add(key)
            skill = "pending" if (json_looks_pending(obj) or text_looks_pending(json.dumps(obj)[-8000:])) else ""
            out.append((title[:160] or "Amp thread", 0, 0, "", skill, project[:48], (cwd or "")[:240], file_mtime_ms(f), enrich_session_stats(session_stats(f, per_session=True), json.dumps(obj))))
            if len(out) >= MAX_SESSIONS_PER_AGENT:
                return out

    # Modern Amp: ~/.local/share/amp/session.json + history.jsonl (no local threads/)
    hist = share / "history.jsonl"
    session = share / "session.json"
    title = cwd = sid = mode = ""
    ms = 0
    if hist.is_file():
        text = tail_bytes(hist, 80_000)
        lines = [ln for ln in text.splitlines() if ln.strip()]
        for line in reversed(lines):
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if not isinstance(obj, dict):
                continue
            if not cwd:
                cwd = str(obj.get("cwd") or obj.get("workdir") or "")
            candidate = meaningful_prompt(obj.get("prompt") or obj.get("text") or obj.get("content"))
            if candidate:
                title = candidate[:160]
                break
        ms = file_mtime_ms(hist)
    if session.is_file():
        try:
            sobj = json.loads(session.read_text(encoding="utf-8", errors="replace"))
            if isinstance(sobj, dict):
                sid = str(sobj.get("lastThreadId") or "")[:80]
                mode = str(sobj.get("agentMode") or "")[:64]
                # Prefer cwd from last terminal binding if history lacked it
                by_tty = sobj.get("lastThreadByTerminal")
                if isinstance(by_tty, dict) and not cwd:
                    # no cwd in session; keep history cwd
                    pass
                ms = max(ms, file_mtime_ms(session))
                if not title:
                    title = f"Amp · {mode}" if mode else "Amp session"
        except Exception:
            pass
    # Legacy prompts path
    legacy = share / "history" / "prompts.jsonl"
    if not title and legacy.is_file():
        text = tail_bytes(legacy, 40_000)
        lines = [ln for ln in text.splitlines() if ln.strip()]
        if lines:
            try:
                obj = json.loads(lines[-1])
                title = str(obj.get("prompt") or obj.get("text") or "")[:160]
                cwd = str(obj.get("cwd") or "")
                ms = file_mtime_ms(legacy)
            except Exception:
                pass

    if title or sid or cwd:
        project = short_project(cwd) if cwd else ("Amp" if sid else "")
        skill = ""
        if hist.is_file() and text_looks_pending(tail_bytes(hist, 8_000)):
            skill = "pending"
        extra = enrich_session_stats({"mode": mode} if mode else {}, text if hist.is_file() else "")
        row = (
            title[:160] or "Amp session",
            0,
            0,
            "",
            skill,
            project[:48],
            (cwd or "")[:240],
            ms or int(time.time() * 1000),
        )
        # Prefer 9-tuple with session when available
        if sid:
            out.append((*row, sid, extra))
        else:
            out.append((*row, extra))
    return out[:MAX_SESSIONS_PER_AGENT]


PENDING_NEEDLES = (
    "ask_followup",
    "askfollowup",
    "ask_followup_question",
    "ask_user",
    "askuser",
    "awaiting_approval",
    "awaiting_confirmation",
    "awaiting_user",
    "needs_approval",
    "needs_user",
    "needs_response",
    "permission_request",
    "request_approval",
    "tool_approval",
    "tool_permission",
    "waiting_for_user",
    "waiting for your",
    "waiting_for_response",
    "human_input",
    "user_input_required",
    "user_confirmation",
    "confirmation_required",
    "approval_required",
    '"status":"pending"',
    '"status": "pending"',
    '"ask"',
    "y/n",
)


def text_looks_pending(text: str) -> bool:
    if not text:
        return False
    low = text.lower()[-6000:]
    return any(n in low for n in PENDING_NEEDLES)


def json_looks_pending(obj) -> bool:
    """Best-effort walk for ask/approval flags in extension/session JSON."""
    try:
        blob = json.dumps(obj, ensure_ascii=False) if not isinstance(obj, str) else obj
    except Exception:
        return False
    return text_looks_pending(blob)


def vscode_user_roots() -> list[Path]:
    support = HOME / "Library" / "Application Support"
    names = (
        "Code",
        "Code - Insiders",
        "Cursor",
        "Windsurf",
        "Trae",
        "VSCodium",
        "Code - OSS",
        "Kiro",
        "Antigravity",
        "Antigravity IDE",
    )
    out: list[Path] = []
    for n in names:
        p = support / n / "User"
        if p.is_dir():
            out.append(p)
    return out


def vscode_global_storage_dirs(*needles: str) -> list[Path]:
    hits: list[Path] = []
    for root in vscode_user_roots():
        gs = root / "globalStorage"
        if not gs.is_dir():
            continue
        try:
            for child in gs.iterdir():
                if not child.is_dir():
                    continue
                name = child.name.lower()
                if any(n.lower() in name for n in needles):
                    hits.append(child)
        except OSError:
            continue
    return hits


def recent_files_under(root: Path, patterns: tuple[str, ...] = ("*.json", "*.jsonl"), limit: int = 8) -> list[Path]:
    paths: list[str] = []
    try:
        for pat in patterns:
            paths.extend(str(p) for p in root.rglob(pat) if p.is_file())
    except OSError:
        return []
    # Cap walk cost only after ranking by mtime. `rglob` order is not a
    # recency order, so slicing first silently discarded newer sessions that
    # happened to be visited later in a large cache tree.
    candidate_limit = max(200, limit * 4)
    if len(paths) > candidate_limit:
        try:
            paths.sort(key=lambda raw: Path(raw).stat().st_mtime, reverse=True)
        except OSError:
            pass
        paths = paths[:candidate_limit]
    return newest(paths, limit)


def task_from_json_obj(obj: dict) -> tuple[str, str, str]:
    """Return (task, cwd, session)."""
    task = ""
    for k in ("task", "title", "summary", "prompt", "query", "lastMessage"):
        v = obj.get(k)
        if isinstance(v, str) and v.strip():
            task = v.strip()
            break
    cwd = ""
    for k in ("cwd", "workingDirectory", "workdir", "workspacePath", "workspace", "path", "directory"):
        v = obj.get(k)
        if isinstance(v, str) and v.strip():
            cwd = v.strip()
            break
    sid = ""
    for k in ("id", "sessionId", "session_id", "taskId", "conversationId", "uuid"):
        v = obj.get(k)
        if isinstance(v, str) and v.strip():
            sid = v.strip()
            break
    return task[:160], cwd[:240], sid[:80]


def observed_session_from_json(obj) -> tuple[str, str, str]:
    """Find a real session-like object inside a private extension cache.

    VS Code-family extensions usually wrap sessions in a versioned container
    (`state.sessions[]`, `conversations.byId`, `tasks`, …). Reading only the
    root or last list item discarded the useful title/workspace for most of
    those agents. This walk is bounded and conservative: an arbitrary `name`
    in settings/profile/model JSON is never accepted as a task.
    """
    context_needles = ("session", "thread", "conversation", "chat", "task", "composer", "history")
    title_keys = ("task", "title", "summary", "prompt", "query", "lastMessage", "subject")
    cwd_keys = (
        "cwd", "workingDirectory", "workdir", "workspacePath", "workspace",
        "projectPath", "project_path", "directory", "worktree",
    )
    sid_keys = ("sessionId", "session_id", "taskId", "conversationId", "threadId", "uuid", "id")

    best: tuple[int, str, str, str] = (0, "", "", "")
    stack: list[tuple[object, str, int]] = [(obj, "", 0)]
    seen = 0
    while stack and seen < 1200:
        value, context, depth = stack.pop()
        seen += 1
        if depth > 7:
            continue
        if isinstance(value, list):
            for item in bounded_sequence(value):
                stack.append((item, context, depth + 1))
            continue
        if not isinstance(value, dict):
            continue

        task = cwd = sid = ""
        for key in title_keys:
            raw = value.get(key)
            if isinstance(raw, str) and raw.strip():
                task = " ".join(raw.strip().split())
                break
        for key in cwd_keys:
            raw = value.get(key)
            if isinstance(raw, str) and raw.strip().startswith("/"):
                cwd = raw.strip()
                break
        for key in sid_keys:
            raw = value.get(key)
            if isinstance(raw, (str, int)) and str(raw).strip():
                sid = str(raw).strip()
                break

        record_type = str(value.get("type") or value.get("kind") or "").lower()
        context_is_session = (
            any(n in context.lower() for n in context_needles)
            or any(n in record_type for n in context_needles)
        )
        # A title alone at the root may be a theme/profile/model. It needs a
        # session context, identity, or workspace before it becomes evidence.
        qualified = bool(cwd or (task and sid) or (task and context_is_session))
        if qualified:
            score = (8 if task else 0) + (6 if cwd else 0) + (3 if sid else 0)
            if context_is_session:
                score += 4
            if score > best[0]:
                best = (score, task[:160], cwd[:240], sid[:80])

        for key, child in value.items():
            if isinstance(child, (dict, list)):
                child_context = f"{context}.{key}" if context else str(key)
                stack.append((child, child_context, depth + 1))

    return best[1], best[2], best[3]


def observed_sessions_from_json(obj, limit: int = MAX_SESSIONS_PER_AGENT) -> list[tuple]:
    """Return distinct session records from one shared extension container.

    Many VS Code-family agents keep every conversation in one JSON document.
    `observed_session_from_json` intentionally returns the single strongest
    record for compatibility, but using it in a collector made a four-session
    cache look like one session no matter how high the outer row cap was.

    Tuple: task, cwd, session id, optional facts, pending, updated_ms.
    """
    context_needles = ("session", "thread", "conversation", "chat", "task", "composer", "history")
    title_keys = ("task", "title", "summary", "prompt", "query", "lastMessage", "subject")
    cwd_keys = (
        "cwd", "workingDirectory", "workdir", "workspacePath", "workspace",
        "projectPath", "project_path", "directory", "worktree",
    )
    sid_keys = ("sessionId", "session_id", "taskId", "conversationId", "threadId", "uuid", "id")
    time_keys = (
        "lastUpdatedAt", "updatedAt", "updated_at", "time_updated",
        "timestamp", "modifiedAt", "createdAt",
    )

    candidates: dict[str, dict] = {}
    stack: list[tuple[object, str, int]] = [(obj, "", 0)]
    visited = 0
    order = 0
    while stack and visited < 1200:
        value, context, depth = stack.pop()
        visited += 1
        if depth > 7:
            continue
        if isinstance(value, list):
            for item in bounded_sequence(value):
                stack.append((item, context, depth + 1))
            continue
        if not isinstance(value, dict):
            continue

        task = cwd = sid = ""
        for key in title_keys:
            raw = value.get(key)
            if isinstance(raw, str) and raw.strip():
                task = " ".join(raw.strip().split())[:160]
                break
        for key in cwd_keys:
            raw = value.get(key)
            if isinstance(raw, str) and raw.strip().startswith("/"):
                cwd = raw.strip()[:240]
                break
        for key in sid_keys:
            raw = value.get(key)
            if isinstance(raw, (str, int)) and str(raw).strip():
                sid = str(raw).strip()[:80]
                break

        record_type = str(value.get("type") or value.get("kind") or "").lower()
        context_is_session = (
            any(needle in context.lower() for needle in context_needles)
            or any(needle in record_type for needle in context_needles)
        )
        strong_session_context = (
            any(
                needle in context.lower()
                for needle in ("session", "thread", "conversation", "chat", "composer", "history")
            )
            or any(
                needle in record_type
                for needle in ("session", "thread", "conversation", "chat", "composer")
            )
        )
        if not sid and context_is_session:
            leaf = context.rsplit(".", 1)[-1]
            if re.fullmatch(r"[0-9a-z_-]{8,80}", leaf, re.I) and leaf.lower() not in context_needles:
                sid = leaf[:80]

        # A checklist item under `tasks[]` is not automatically an agent
        # session. It needs its own identity/workspace; stronger conversation
        # containers may qualify a titled record without those fields.
        qualified = bool((task and sid) or (task and cwd) or (task and strong_session_context) or (cwd and sid))
        if qualified:
            updated_ms = 0
            for key in time_keys:
                raw = value.get(key)
                updated_ms = normalize_time_ms(raw)
                if updated_ms:
                    break
            score = (
                (8 if task else 0)
                + (6 if cwd else 0)
                + (4 if sid else 0)
                + (4 if context_is_session else 0)
            )
            identity = sid or f"{cwd}\x1f{task}"
            existing = candidates.get(identity)
            if existing is None:
                order += 1
                candidates[identity] = {
                    "task": task,
                    "cwd": cwd,
                    "sid": sid,
                    "node": value,
                    "score": score,
                    "updated_ms": updated_ms,
                    "order": order,
                }
            else:
                if task and (not existing["task"] or score > existing["score"]):
                    existing["task"] = task
                if cwd and not existing["cwd"]:
                    existing["cwd"] = cwd
                if sid and not existing["sid"]:
                    existing["sid"] = sid
                if score > existing["score"]:
                    existing["node"] = value
                    existing["score"] = score
                existing["updated_ms"] = max(existing["updated_ms"], updated_ms)

        for key, child in value.items():
            if isinstance(child, (dict, list)):
                child_context = f"{context}.{key}" if context else str(key)
                stack.append((child, child_context, depth + 1))

    ranked = sorted(
        candidates.values(),
        key=lambda item: (item["updated_ms"], item["score"], item["order"]),
        reverse=True,
    )
    out: list[tuple] = []
    for item in ranked[:max(0, limit)]:
        node = item["node"]
        out.append(
            (
                item["task"],
                item["cwd"],
                item["sid"],
                observed_facts_from_json(node),
                json_looks_pending(node),
                item["updated_ms"],
            )
        )
    return out


def observed_session_from_text(text: str) -> tuple[str, str, str]:
    """Decode a JSON document or recent JSONL records, then walk it."""
    stripped = (text or "").strip()
    if not stripped:
        return "", "", ""
    try:
        if stripped.startswith(("{", "[")):
            return observed_session_from_json(json.loads(stripped))
    except Exception:
        pass
    records = []
    for line in stripped.splitlines()[-160:]:
        line = line.strip()
        if not line.startswith(("{", "[")):
            continue
        try:
            records.append(json.loads(line))
        except Exception:
            continue
    task, cwd, sid = observed_session_from_json(records)
    # JSONL commonly separates immutable session metadata from later title or
    # prompt records. Merge only within this one session file, newest first.
    for record in reversed(records):
        rt, rc, rs = observed_session_from_json(record)
        task = task or rt
        cwd = cwd or rc
        sid = sid or rs
        if task and cwd and sid:
            break
    return task, cwd, sid


def observed_facts_from_json(obj) -> dict:
    """Extract optional lifecycle facts only from session-qualified objects.

    This is deliberately separate from `observed_session_from_json`: private
    extension caches change shape often, and a model/theme/status preference
    must never become session telemetry. A dictionary qualifies only when it
    carries a session identity, absolute workspace, task title, or sits under a
    session-like container.
    """
    session_needles = ("session", "thread", "conversation", "chat", "task", "composer", "history")
    title_keys = ("task", "title", "summary", "prompt", "query", "lastMessage", "subject")
    sid_keys = ("sessionId", "session_id", "taskId", "conversationId", "threadId", "uuid")
    cwd_keys = ("cwd", "workingDirectory", "workdir", "workspacePath", "projectPath", "directory")
    best: tuple[int, dict] = (0, {})
    stack: list[tuple[object, str, int]] = [(obj, "", 0)]
    seen = 0
    while stack and seen < 1200:
        value, context, depth = stack.pop()
        seen += 1
        if depth > 7:
            continue
        if isinstance(value, list):
            for item in bounded_sequence(value):
                stack.append((item, context, depth + 1))
            continue
        if not isinstance(value, dict):
            continue

        context_is_session = any(n in context.lower() for n in session_needles)
        has_title = any(isinstance(value.get(k), str) and value.get(k).strip() for k in title_keys)
        has_sid = any(isinstance(value.get(k), (str, int)) and str(value.get(k)).strip() for k in sid_keys)
        has_cwd = any(
            isinstance(value.get(k), str) and value.get(k).strip().startswith("/")
            for k in cwd_keys
        )
        if context_is_session or has_title or has_sid or has_cwd:
            facts: dict = {}
            for key in ("phase", "stage", "currentPhase", "status", "state"):
                raw = value.get(key)
                if isinstance(raw, str) and raw.strip():
                    facts["phase"] = raw.strip()[:64]
                    break
            for key in ("outcome", "result", "completion", "finalStatus"):
                raw = value.get(key)
                if isinstance(raw, str) and raw.strip():
                    facts["outcome"] = raw.strip()[:64]
                    break
            for key in ("model", "modelId", "model_id", "currentModel", "current_model"):
                raw = value.get(key)
                if isinstance(raw, str) and raw.strip():
                    facts["model"] = raw.strip()[:64]
                    break
            for key in ("agentMode", "agent_mode", "mode", "role"):
                raw = value.get(key)
                if isinstance(raw, str) and raw.strip():
                    facts["mode"] = raw.strip()[:64]
                    break
            number_keys = {
                "errors": ("errorCount", "errors", "toolFailureCount"),
                "files": ("filesChanged", "totalFilesTouched", "filesTouched"),
                "context_pct": ("contextWindowUsage", "contextUsagePercent", "contextPercent"),
                "progress_done": ("completedTasks", "completed", "doneCount"),
                "progress_total": ("totalTasks", "total", "taskCount"),
            }
            for fact, keys in number_keys.items():
                for key in keys:
                    raw = value.get(key)
                    if isinstance(raw, (int, float)) and raw > 0:
                        facts[fact] = int(raw)
                        break
            score = (
                len(facts) * 3
                + (5 if context_is_session else 0)
                + (3 if has_sid else 0)
                + (2 if has_cwd else 0)
            )
            if facts and score > best[0]:
                best = (score, facts)

        for key, child in value.items():
            if isinstance(child, (dict, list)):
                child_context = f"{context}.{key}" if context else str(key)
                stack.append((child, child_context, depth + 1))
    return best[1]


def observed_facts_from_text(text: str, limit: int = 120) -> dict:
    """Merge lifecycle facts from a bounded JSON/JSONL text window.

    A number of IDE adapters have a real session file but no stable top-level
    schema. Reusing the same conservative fact walker keeps model, phase,
    mode, progress and outcome extraction consistent without treating a
    preference blob as a session. Unknown and conflicting values remain
    unknown rather than being guessed.
    """
    if not text:
        return {}
    objects: list[object] = []
    stripped = text.strip()
    if stripped.startswith(("{", "[")):
        try:
            objects.append(json.loads(stripped))
        except Exception:
            pass
    if not objects:
        for line in text.splitlines()[-limit:]:
            line = line.strip()
            if not line.startswith(("{", "[")):
                continue
            try:
                objects.append(json.loads(line))
            except Exception:
                continue
    merged: dict = {}
    for obj in objects:
        facts = observed_facts_from_json(obj)
        for key, value in facts.items():
            if key not in merged:
                merged[key] = value
    return merged


def enrich_session_stats(stats: dict | None, text: str) -> dict:
    """Keep record counts and qualified lifecycle facts in one row payload."""
    merged = dict(stats or {})
    for key, value in observed_facts_from_text(text).items():
        merged.setdefault(key, value)
    return merged


def harvest_extension_storage(agent: str, *needles: str, limit: int = MAX_SESSIONS_PER_AGENT) -> list[tuple]:
    """Generic VS Code/Cursor globalStorage harvest → up to `limit` rows."""
    out: list[tuple] = []
    seen_sessions: set[str] = set()
    for store in vscode_global_storage_dirs(*needles):
        # The row budget is 64 per agent.  A smaller adapter-local cap made
        # sessions 5+ disappear before SnapshotBuilder could apply its own
        # visibility budget, which was especially noticeable in Cursor-like
        # extensions with several active conversations.
        files = recent_files_under(store, ("*.json", "*.jsonl"), limit=MAX_SESSIONS_PER_AGENT)
        for f in files:
            try:
                age = time.time() - f.stat().st_mtime
                if age > FRESH_SEC:
                    continue
            except OSError:
                continue
            text = ""
            try:
                if f.suffix == ".jsonl":
                    text = tail_bytes(f, 120_000)
                    # last JSON line
                    last = ""
                    for ln in reversed(text.splitlines()):
                        if ln.strip().startswith("{"):
                            last = ln
                            break
                    obj = json.loads(last) if last else {}
                else:
                    text = f.read_text(encoding="utf-8", errors="replace")[:400_000]
                    obj = json.loads(text) if text.lstrip().startswith("{") or text.lstrip().startswith("[") else {}
            except Exception:
                obj = {}
                text = tail_bytes(f, 80_000)
            shared_sessions = (
                observed_sessions_from_json(obj, limit=limit - len(out))
                if isinstance(obj, (dict, list))
                else []
            )
            if shared_sessions:
                for task, cwd, sid, extra, pending, updated_ms in shared_sessions:
                    identity = sid or f"{cwd}\x1f{task}"
                    if identity in seen_sessions:
                        continue
                    seen_sessions.add(identity)
                    display_task = task or f"{agent} session"
                    project = short_project(cwd) if cwd else short_project(store.name)
                    out.append(
                        (
                            display_task[:160],
                            0,
                            0,
                            last_tool_name_strict(text),
                            "pending" if pending else "",
                            project[:48],
                            cwd[:240],
                            updated_ms or file_mtime_ms(f),
                            sid or f.stem[:80],
                            extra,
                        )
                    )
                    if len(out) >= limit:
                        return out
                continue
            task = cwd = sid = ""
            extra: dict = {}
            if isinstance(obj, (dict, list)):
                task, cwd, sid = observed_session_from_json(obj)
                extra = observed_facts_from_json(obj)
                pending = json_looks_pending(obj)
            else:
                pending = text_looks_pending(text)
            if not (task and cwd and sid):
                text_task, text_cwd, text_sid = observed_session_from_text(text)
                task = task or text_task
                cwd = cwd or text_cwd
                sid = sid or text_sid
            if not pending:
                pending = text_looks_pending(text)
            extra = enrich_session_stats(extra, text)
            if not task:
                task = session_title_from_text(text) or f"{agent} session"
            project = short_project(cwd) if cwd else short_project(store.name)
            skill = "pending" if pending else ""
            if not (task or pending or cwd):
                continue
            out.append((
                task[:160],
                0,
                0,
                last_tool_name_strict(text),
                skill,
                project[:48],
                cwd[:240],
                file_mtime_ms(f),
                sid or f.stem[:80],
                extra,
            ))
            if len(out) >= limit:
                return out
    return out


def continue_activities() -> list[tuple]:
    """Continue: ~/.continue/sessions and dev_data — deepen ask/pending."""
    out: list[tuple] = []
    roots = [
        HOME / ".continue" / "sessions",
        HOME / ".continue" / "dev_data" / "sessions",
        HOME / ".continue" / "index" / "globalContext",
        HOME / ".continue",
    ]
    files: list[Path] = []
    for root in roots:
        if not root.is_dir():
            continue
        files.extend(recent_files_under(root, ("*.json", "*.jsonl"), limit=MAX_SESSIONS_PER_AGENT))
    files = newest([str(f) for f in files], MAX_SESSIONS_PER_AGENT)
    for f in files:
        text = tail_bytes(f, 140_000)
        low = text.lower()
        # Skip pure config/index blobs
        if "models.json" in str(f) or "config.json" in str(f):
            if "session" not in low and "message" not in low:
                continue
        task = (
            session_title_from_text(text)
            or extract_field(text, "title")
            or extract_field(text, "prompt")
            or extract_field(text, "content")
            or "Continue session"
        )
        cwd = (
            extract_field(text, "workspaceDirectory")
            or extract_field(text, "workspaceDir")
            or extract_field(text, "cwd")
            or ""
        )
        project = short_project(cwd) if cwd else short_project(f.stem)
        pending = text_looks_pending(text) or any(
            x in low[-5000:]
            for x in ("awaiting_user", "needs_response", "tool_permission", "confirmation")
        )
        skill = "pending" if pending else ""
        extra = session_stats(f, per_session=True)
        extra.update({k: v for k, v in observed_facts_from_text(text).items() if k not in extra})
        out.append((task[:160], 0, 0, last_tool_name_strict(text), skill, project[:48], (cwd or "")[:240], file_mtime_ms(f), f.stem[:80], extra))
        if len(out) >= MAX_SESSIONS_PER_AGENT:
            break
    return out


def copilot_activities() -> list[tuple]:
    """GitHub Copilot CLI: ~/.copilot/session-state/<id>/events.jsonl + workspace.yaml."""
    home = Path(os.environ.get("COPILOT_HOME") or (HOME / ".copilot"))
    state = home / "session-state"
    out: list[tuple] = []
    if not state.is_dir():
        # Fallback legacy roots
        return home_dir_activities("copilot", [home, HOME / ".config" / "copilot"], limit=MAX_SESSIONS_PER_AGENT)

    sessions = []
    try:
        for d in state.iterdir():
            if d.is_dir():
                sessions.append(d)
    except OSError:
        return out
    sessions.sort(key=lambda p: p.stat().st_mtime if p.exists() else 0, reverse=True)

    for sdir in sessions[:MAX_SESSIONS_PER_AGENT]:
        events = sdir / "events.jsonl"
        ws = sdir / "workspace.yaml"
        plan = sdir / "plan.md"
        text = tail_bytes(events, 120_000) if events.is_file() else ""
        title = cwd = ""
        if ws.is_file():
            try:
                wtext = ws.read_text(encoding="utf-8", errors="replace")
                for line in wtext.splitlines():
                    if ":" not in line:
                        continue
                    k, _, v = line.partition(":")
                    k, v = k.strip().lower(), v.strip().strip("\"'")
                    if k in ("cwd", "workdir", "path", "directory", "workspace") and v:
                        cwd = v
                    if k in ("title", "name", "summary") and v and not title:
                        title = v
            except OSError:
                pass
        if not title and plan.is_file():
            try:
                title = plan.read_text(encoding="utf-8", errors="replace").strip().splitlines()[0][:160]
            except OSError:
                pass
        if not title:
            title = session_title_from_text(text) or extract_field(text, "prompt") or "Copilot session"
        project = short_project(cwd) if cwd else short_project(sdir.name)
        pending = text_looks_pending(text) or any(
            x in text.lower()[-5000:]
            for x in ("permission", "approval_required", "waiting_for_user", "user_confirmation")
        )
        skill = "pending" if pending else ""
        mtime = file_mtime_ms(events if events.is_file() else sdir)
        stats = session_stats(events if events.is_file() else sdir, per_session=True)
        stats.update({k: v for k, v in observed_facts_from_text(text).items() if k not in stats})
        model = last_model_name(text)
        if model and "model" not in stats:
            stats["model"] = model
        out.append((title[:160], 0, 0, last_tool_name_strict(text), skill, project[:48], (cwd or "")[:240], mtime, sdir.name[:80], stats))
        if len(out) >= MAX_SESSIONS_PER_AGENT:
            break
    return out


def amazon_q_activities() -> list[tuple]:
    roots = [
        HOME / ".aws" / "amazonq",
        HOME / ".aws" / "amazon-q",
        HOME / ".aws" / "q",
        HOME / "Library" / "Application Support" / "amazon-q",
        HOME / "Library" / "Application Support" / "Amazon Q",
        HOME / "Library" / "Application Support" / "AmazonQ",
        HOME / ".local" / "share" / "amazon-q",
    ]
    out: list[tuple] = []
    files: list[str] = []
    for root in roots:
        if root.is_dir():
            files.extend(str(p) for p in recent_files_under(root, ("*.json", "*.jsonl", "*.md", "*.txt"), limit=MAX_SESSIONS_PER_AGENT))
    for f in newest(files, MAX_SESSIONS_PER_AGENT):
        text = tail_bytes(Path(f), 100_000)
        low = text.lower()
        if not any(x in low for x in ("chat", "message", "prompt", "agent", "tool", "q ")):
            # still accept amazonq path files
            if "amazon" not in str(f).lower() and "amazonq" not in str(f).lower():
                continue
        task = session_title_from_text(text) or extract_field(text, "title") or extract_field(text, "prompt") or "Amazon Q chat"
        cwd = extract_field(text, "cwd") or extract_field(text, "workspace") or ""
        project = short_project(cwd) if cwd else short_project(Path(f).stem)
        skill = "pending" if text_looks_pending(text) else ""
        stats = session_stats(Path(f), per_session=True)
        stats.update({k: v for k, v in observed_facts_from_text(text).items() if k not in stats})
        model = last_model_name(text)
        if model and "model" not in stats:
            stats["model"] = model
        out.append((task[:160], 0, 0, last_tool_name_strict(text), skill, project[:48], (cwd or "")[:240], file_mtime_ms(Path(f)), Path(f).stem[:80], stats))
        if len(out) >= MAX_SESSIONS_PER_AGENT:
            break
    return out


def zed_agent_activities() -> list[tuple]:
    roots = [
        HOME / "Library" / "Application Support" / "Zed",
        HOME / ".zed",
        HOME / ".config" / "zed",
    ]
    out: list[tuple] = []
    files: list[str] = []
    for root in roots:
        if not root.is_dir():
            continue
        for pat in (
            "**/threads/**/*.json",
            "**/conversations/**/*",
            "**/*agent*.json",
            "**/*agent*.jsonl",
            "**/assistant/**/*",
            "**/context_servers/**/*",
        ):
            try:
                files.extend(str(p) for p in root.glob(pat) if p.is_file() and p.stat().st_size < 8_000_000)
            except OSError:
                continue
    for f in newest(files, MAX_SESSIONS_PER_AGENT):
        text = tail_bytes(Path(f), 120_000)
        low = text.lower()
        if not any(x in low for x in ("agent", "tool", "message", "thread", "assistant", "ask")):
            continue
        task = session_title_from_text(text) or extract_field(text, "title") or "Zed Agent"
        cwd = extract_field(text, "cwd") or extract_field(text, "project_path") or extract_field(text, "worktree") or ""
        project = short_project(cwd) if cwd else short_project(Path(f).stem)
        skill = "pending" if text_looks_pending(text) else ""
        stats = session_stats(Path(f), per_session=True)
        stats.update({k: v for k, v in observed_facts_from_text(text).items() if k not in stats})
        out.append((task[:160], 0, 0, last_tool_name_strict(text), skill, project[:48], (cwd or "")[:240], file_mtime_ms(Path(f)), Path(f).stem[:80], stats))
        if len(out) >= MAX_SESSIONS_PER_AGENT:
            break
    return out


def openhands_activities() -> list[tuple]:
    roots = [
        HOME / ".openhands" / "sessions",
        HOME / ".openhands" / "file_store",
        HOME / ".openhands",
        HOME / ".openhands-state",
        HOME / ".opendevin",
        HOME / ".cache" / "openhands",
        Path("/tmp/openhands_file_store"),
    ]
    out: list[tuple] = []
    files: list[str] = []
    for root in roots:
        if root.is_dir():
            files.extend(str(p) for p in recent_files_under(root, ("*.json", "*.jsonl", "*.md"), limit=MAX_SESSIONS_PER_AGENT))
    for f in newest(files, MAX_SESSIONS_PER_AGENT):
        text = tail_bytes(Path(f), 120_000)
        low = text.lower()
        if "trajectory" not in low and "event" not in low and "action" not in low and "message" not in low:
            if "session" not in str(f).lower():
                continue
        task = session_title_from_text(text) or extract_field(text, "title") or extract_field(text, "message") or "OpenHands"
        cwd = extract_field(text, "cwd") or extract_field(text, "workspace") or extract_field(text, "workdir") or ""
        project = short_project(cwd) if cwd else short_project(Path(f).stem)
        skill = "pending" if (
            text_looks_pending(text)
            or "awaiting_user" in low
            or "confirmation" in low[-3000:]
            or '"action":"message"' in low[-2000:] and "wait" in low[-2000:]
        ) else ""
        stats = session_stats(Path(f), per_session=True)
        stats.update({k: v for k, v in observed_facts_from_text(text).items() if k not in stats})
        out.append((task[:160], 0, 0, last_tool_name_strict(text), skill, project[:48], (cwd or "")[:240], file_mtime_ms(Path(f)), Path(f).stem[:80], stats))
        if len(out) >= MAX_SESSIONS_PER_AGENT:
            break
    return out


def antigravity_activities() -> list[tuple]:
    """Antigravity IDE/2.0 — B 尽力；Waiting 通常 none。"""
    out = harvest_extension_storage("antigravity", "antigravity", "google.antigravity", limit=MAX_SESSIONS_PER_AGENT)
    support = HOME / "Library" / "Application Support"
    roots = [
        HOME / ".antigravity",
        support / "Antigravity",
        support / "Antigravity IDE",
        support / "Google" / "Antigravity",
        support / "Antigravity" / "User" / "globalStorage",
        support / "Antigravity IDE" / "User" / "globalStorage",
    ]
    # Also scan VS Code-style User under those app folders
    for name in ("Antigravity", "Antigravity IDE"):
        user = support / name / "User"
        if user.is_dir():
            roots.append(user / "globalStorage")
            roots.append(user / "workspaceStorage")
    if len(out) >= MAX_SESSIONS_PER_AGENT:
        return out
    more = home_dir_activities("antigravity", roots, limit=MAX_SESSIONS_PER_AGENT - len(out))
    # Prefer rows that look agent-ish
    filtered = []
    for row in more:
        blob = " ".join(str(x) for x in row).lower()
        if any(x in blob for x in ("agent", "chat", "thread", "task", "pending", "antigravity")):
            filtered.append(row)
    # Do not fall back to arbitrary files from the app's cache. Antigravity
    # ships VS Code schemas, walkthrough metadata and extension indexes in
    # the same tree; those rows look recent but cannot answer what the agent
    # is doing. An honest ``no sessions`` health state is more useful than a
    # tray full of plausible-looking cache titles. Real session-shaped files
    # still pass when they contain agent/chat/task evidence or a workspace.
    return (out + filtered)[:MAX_SESSIONS_PER_AGENT]


def roo_activities() -> list[tuple]:
    """Roo: deepen ask/approval like Cline."""
    out = harvest_extension_storage("roo", "roo-cline", "roo-code", "rooveterinary", "RooCode", limit=MAX_SESSIONS_PER_AGENT)
    if len(out) >= MAX_SESSIONS_PER_AGENT and any(r[4] == "pending" for r in out):
        return out
    for store in vscode_global_storage_dirs("roo-cline", "roo-code", "rooveterinary", "RooCode"):
        for f in recent_files_under(store, ("*.json", "*.jsonl"), limit=MAX_SESSIONS_PER_AGENT):
            text = tail_bytes(f, 120_000)
            low = text.lower()
            pending = text_looks_pending(text) or any(
                n in low for n in ("ask_followup", "needs_approval", "waiting_for_response", "ask_user")
            )
            if not pending and "task" not in low and "message" not in low:
                continue
            task = session_title_from_text(text) or extract_field(text, "task") or "Roo task"
            cwd = extract_field(text, "cwd") or extract_field(text, "workspacePath") or ""
            project = short_project(cwd) if cwd else short_project(store.name)
            skill = "pending" if pending else ""
            row = (
                task[:160], 0, 0, "", skill, project[:48], (cwd or "")[:240],
                file_mtime_ms(f), f.stem[:80], enrich_session_stats({}, text)
            )
            if pending:
                out = [row] + [r for r in out if (len(r) < 9 or r[8] != row[8])]
            elif not out:
                out.append(row)
            if len(out) >= MAX_SESSIONS_PER_AGENT:
                return out[:MAX_SESSIONS_PER_AGENT]
    return out[:MAX_SESSIONS_PER_AGENT]


def kilo_activities() -> list[tuple]:
    out = harvest_extension_storage("kilo", "kilocode", "kilo-code", "kilo.code", limit=MAX_SESSIONS_PER_AGENT)
    if any(r[4] == "pending" for r in out):
        return out
    for store in vscode_global_storage_dirs("kilocode", "kilo-code", "kilo.code"):
        for f in recent_files_under(store, ("*.json", "*.jsonl"), limit=MAX_SESSIONS_PER_AGENT):
            text = tail_bytes(f, 100_000)
            pending = text_looks_pending(text)
            task = session_title_from_text(text) or "Kilo session"
            cwd = extract_field(text, "cwd") or extract_field(text, "workspacePath") or ""
            project = short_project(cwd) if cwd else short_project(store.name)
            skill = "pending" if pending else ""
            if not (task or pending):
                continue
            out.append((task[:160], 0, 0, last_tool_name_strict(text), skill, project[:48], (cwd or "")[:240], file_mtime_ms(f), f.stem[:80], enrich_session_stats(session_stats(f, per_session=True), text)))
            if len(out) >= MAX_SESSIONS_PER_AGENT:
                return out[:MAX_SESSIONS_PER_AGENT]
    return out[:MAX_SESSIONS_PER_AGENT]


def cascade_windsurf_activities() -> list[tuple]:
    """Cascade agent sessions; also Windsurf/Codeium local state."""
    out: list[tuple] = []
    roots = [
        HOME / ".codeium",
        HOME / ".windsurf",
        HOME / "Library" / "Application Support" / "Windsurf",
        HOME / "Library" / "Application Support" / "Codeium",
    ]
    # Extension storage
    out.extend(harvest_extension_storage("cascade", "codeium.cascade", "codeium", "windsurf", limit=MAX_SESSIONS_PER_AGENT))
    files: list[str] = []
    for root in roots:
        if root.is_dir():
            files.extend(str(p) for p in recent_files_under(root, ("*.json", "*.jsonl"), limit=MAX_SESSIONS_PER_AGENT))
    for f in newest(files, MAX_SESSIONS_PER_AGENT):
        if len(out) >= MAX_SESSIONS_PER_AGENT:
            break
        text = tail_bytes(Path(f), 100_000)
        if "cascade" not in text.lower() and "windsurf" not in str(f).lower() and "codeium" not in str(f).lower():
            # still accept recent agent-ish blobs under these roots
            if not any(x in text.lower() for x in ("agent", "tool", "chat", "plan")):
                continue
        task = session_title_from_text(text) or extract_field(text, "title") or "Cascade session"
        cwd = extract_field(text, "cwd") or extract_field(text, "workspace") or ""
        project = short_project(cwd) if cwd else short_project(Path(f).stem)
        skill = "pending" if text_looks_pending(text) else ""
        # No trailing `agent` field. It was added here and chopped off two
        # lines later by `row[:9]`, which also took the stats dict with it —
        # so Cascade paid for the file scan every tick and shipped 0/0. The
        # agent name is chosen by `cascade_block` anyway.
        out.append((task[:160], 0, 0, last_tool_name_strict(text), skill, project[:48], (cwd or "")[:240], file_mtime_ms(Path(f)), Path(f).stem[:80], enrich_session_stats(session_stats(Path(f), per_session=True), text)))
    return out[:MAX_SESSIONS_PER_AGENT]


def augment_activities() -> list[tuple]:
    out = harvest_extension_storage("augment", "augment", "auggie", limit=MAX_SESSIONS_PER_AGENT)
    roots = [HOME / ".augment", HOME / ".auggie", HOME / "Library" / "Application Support" / "Augment"]
    if len(out) >= MAX_SESSIONS_PER_AGENT:
        return out
    files: list[str] = []
    for root in roots:
        if root.is_dir():
            files.extend(str(p) for p in recent_files_under(root, ("*.json", "*.jsonl"), limit=MAX_SESSIONS_PER_AGENT))
    for f in newest(files, MAX_SESSIONS_PER_AGENT):
        text = tail_bytes(Path(f), 80_000)
        task = session_title_from_text(text) or "Augment session"
        cwd = extract_field(text, "cwd") or ""
        project = short_project(cwd) if cwd else short_project(Path(f).stem)
        skill = "pending" if text_looks_pending(text) else ""
        out.append((task[:160], 0, 0, last_tool_name_strict(text), skill, project[:48], (cwd or "")[:240], file_mtime_ms(Path(f)), Path(f).stem[:80], enrich_session_stats(session_stats(Path(f), per_session=True), text)))
        if len(out) >= MAX_SESSIONS_PER_AGENT:
            break
    return out


def trae_activities() -> list[tuple]:
    out = harvest_extension_storage("trae", "trae", "bytedance.trae", limit=MAX_SESSIONS_PER_AGENT)
    roots = [
        HOME / "Library" / "Application Support" / "Trae",
        HOME / "Library" / "Application Support" / "Trae" / "User" / "globalStorage",
        HOME / ".trae",
    ]
    if len(out) >= MAX_SESSIONS_PER_AGENT:
        return out
    for root in roots:
        if not root.is_dir():
            continue
        for f in recent_files_under(root, ("*.json", "*.jsonl"), limit=MAX_SESSIONS_PER_AGENT):
            text = tail_bytes(f, 100_000)
            low = text.lower()
            if "agent" not in low and "agent" not in str(f).lower() and "chat" not in low:
                continue
            task = session_title_from_text(text) or "Trae Agent"
            cwd = extract_field(text, "cwd") or extract_field(text, "workspacePath") or ""
            project = short_project(cwd) if cwd else short_project(f.stem)
            skill = "pending" if text_looks_pending(text) else ""
            out.append((task[:160], 0, 0, last_tool_name_strict(text), skill, project[:48], (cwd or "")[:240], file_mtime_ms(f), f.stem[:80], enrich_session_stats(session_stats(f, per_session=True), text)))
            if len(out) >= MAX_SESSIONS_PER_AGENT:
                return out
    return out


def warp_agent_activities() -> list[tuple]:
    roots = [
        HOME / "Library" / "Application Support" / "dev.warp.Warp-Stable",
        HOME / "Library" / "Application Support" / "dev.warp.Warp",
        HOME / ".warp",
    ]
    out: list[tuple] = []
    files: list[str] = []
    for root in roots:
        if not root.is_dir():
            continue
        for pat in ("**/*agent*", "**/*ai*", "**/conversations/**/*", "**/*warp*ai*", "**/*.json", "**/*.jsonl"):
            try:
                files.extend(
                    str(p)
                    for p in root.glob(pat)
                    if p.is_file() and p.stat().st_size < 5_000_000
                )
            except OSError:
                continue
    for f in newest(files, MAX_SESSIONS_PER_AGENT):
        text = tail_bytes(Path(f), 100_000)
        low = text.lower()
        if not any(x in low for x in ("agent", "warp ai", "tool_call", "approval", "ask", "permission")):
            continue
        task = session_title_from_text(text) or "Warp Agent"
        cwd = extract_field(text, "cwd") or extract_field(text, "working_directory") or ""
        project = short_project(cwd) if cwd else short_project(Path(f).stem)
        skill = "pending" if text_looks_pending(text) else ""
        stats = session_stats(Path(f), per_session=True)
        stats.update({k: v for k, v in observed_facts_from_text(text).items() if k not in stats})
        out.append((task[:160], 0, 0, last_tool_name_strict(text), skill, project[:48], (cwd or "")[:240], file_mtime_ms(Path(f)), Path(f).stem[:80], stats))
        if len(out) >= MAX_SESSIONS_PER_AGENT:
            break
    return out


def home_dir_activities(agent: str, roots: list[Path], limit: int = MAX_SESSIONS_PER_AGENT) -> list[tuple]:
    out: list[tuple] = []
    files: list[str] = []
    for root in roots:
        if root.is_dir():
            files.extend(str(p) for p in recent_files_under(root, ("*.json", "*.jsonl", "*.md"), limit=MAX_SESSIONS_PER_AGENT))
    for f in newest(files, MAX_SESSIONS_PER_AGENT):
        path = Path(f)
        text = tail_bytes(path, 100_000)
        task, cwd, sid = observed_session_from_text(text)
        sessionish_path = any(
            word in str(path).lower()
            for word in ("session", "thread", "conversation", "chat", "task", "composer")
        )
        # A generic settings/index file can contain a title, workspace, or
        # model-shaped keys without representing a conversation. Requiring a
        # session-like path or a real session identity prevents those files
        # from becoming misleading rows such as “Default / project”.
        if not sessionish_path and not sid:
            continue
        if not task and sessionish_path:
            task = session_title_from_text(text) or extract_field(text, "title") or ""
        if not cwd:
            cwd = extract_field(text, "cwd") or extract_field(text, "workspace") or ""
        project = short_project(cwd) if cwd else ""
        skill = "pending" if text_looks_pending(text) else ""
        # A file under an explicitly session-like path is a concrete session,
        # not merely a container cache. Preserve its age/record facts and
        # structured lifecycle fields instead of flattening every generic
        # adapter to title + path.
        extra = session_stats(path, per_session=sessionish_path)
        objects: list[object] = []
        try:
            objects.append(json.loads(text))
        except Exception:
            for line in text.splitlines()[-80:]:
                try:
                    objects.append(json.loads(line))
                except Exception:
                    continue
        for obj in objects:
            facts = observed_facts_from_json(obj)
            for key, value in facts.items():
                if key not in extra:
                    extra[key] = value
        if not task and not cwd and not sid:
            continue
        out.append((
            task[:160],
            0,
            0,
            last_tool_name_strict(text),
            skill,
            project[:48],
            (cwd or "")[:240],
            file_mtime_ms(path),
            sid or path.stem[:80],
            extra,
        ))
        if len(out) >= limit:
            break
    return out


def cline_activities() -> list[tuple]:
    """Cline: VS Code globalStorage — deepen ask/approval pending."""
    out = harvest_extension_storage("cline", "saoudrizwan.claude-dev", "claude-dev", "cline", limit=MAX_SESSIONS_PER_AGENT)
    # Extra pass: task history often stores ask_followup_question / api_req pending
    if len(out) >= MAX_SESSIONS_PER_AGENT and any(r[4] == "pending" for r in out):
        return out
    extra_needles = (
        "ask_followup_question",
        "askfollowupquestion",
        "needs_approval",
        "waiting_for_response",
        "tool_use.*ask",
        '"ask"',
        "yoloMode",
        "autoApproval",
    )
    for store in vscode_global_storage_dirs("saoudrizwan.claude-dev", "claude-dev", "cline"):
        for f in recent_files_under(store, ("*.json", "*.jsonl"), limit=MAX_SESSIONS_PER_AGENT):
            text = tail_bytes(f, 120_000)
            low = text.lower()
            pending = text_looks_pending(text) or any(n in low for n in extra_needles)
            if not pending and "task" not in low and "conversation" not in low:
                continue
            task = session_title_from_text(text) or extract_field(text, "task") or "Cline task"
            cwd = extract_field(text, "cwd") or extract_field(text, "workspacePath") or ""
            project = short_project(cwd) if cwd else short_project(store.name)
            skill = "pending" if pending else ""
            row = (
                task[:160], 0, 0, "", skill, project[:48], (cwd or "")[:240],
                file_mtime_ms(f), f.stem[:80], enrich_session_stats({}, text)
            )
            # Prefer pending rows
            if pending:
                out = [row] + [r for r in out if r[8:] != row[8:]]
            elif not out:
                out.append(row)
            if len(out) >= MAX_SESSIONS_PER_AGENT:
                return out[:MAX_SESSIONS_PER_AGENT]
    return out[:MAX_SESSIONS_PER_AGENT]


def droid_activities() -> list[tuple]:
    """Factory Droid: ~/.factory/sessions/<encoded-cwd>/*.jsonl"""
    root = HOME / ".factory" / "sessions"
    out: list[tuple] = []
    if not root.is_dir():
        return out
    files = newest([str(p) for p in root.rglob("*.jsonl") if p.is_file()], MAX_SESSIONS_PER_AGENT)
    for f in files:
        text = tail_bytes(f, 160_000)
        # First line often metadata
        title = cwd = sid = ""
        try:
            first = text.splitlines()[0] if text else ""
            if first.strip().startswith("{"):
                meta = json.loads(first)
                if isinstance(meta, dict):
                    title = str(meta.get("title") or meta.get("name") or "")[:160]
                    cwd = str(meta.get("cwd") or meta.get("workingDirectory") or meta.get("workdir") or "")
                    sid = str(meta.get("sessionId") or meta.get("id") or f.stem)[:80]
        except Exception:
            pass
        if not title:
            title = session_title_from_text(text) or "Droid session"
        if not cwd:
            # Decode parent dir: -Users-me-code-Pulse → path-ish short_project
            enc = f.parent.name
            cwd = decode_claude_project_dir(enc) if enc.startswith("-") else ""
        project = short_project(cwd) if cwd else short_project(f.parent.name)
        skill = "pending" if text_looks_pending(text) else ""
        stats = session_stats(f, per_session=True)
        stats.update({k: v for k, v in observed_facts_from_text(text).items() if k not in stats})
        out.append((title[:160], 0, 0, last_tool_name_strict(text), skill, project[:48], (cwd or "")[:240], file_mtime_ms(f), sid or f.stem[:80], stats))
        if len(out) >= MAX_SESSIONS_PER_AGENT:
            break
    return out


def command_code_activities() -> list[tuple]:
    """Command Code: ~/.commandcode/projects/**/*.jsonl + *.meta.json"""
    root = HOME / ".commandcode" / "projects"
    out: list[tuple] = []
    if not root.is_dir():
        return out
    metas = newest([str(p) for p in root.rglob("*.meta.json") if p.is_file()], MAX_SESSIONS_PER_AGENT)
    seen: set[str] = set()
    for meta_path in metas:
        mp = Path(meta_path)
        sid = mp.name.replace(".meta.json", "")
        if sid in seen:
            continue
        title = ""
        try:
            obj = json.loads(mp.read_text(encoding="utf-8", errors="replace"))
            if isinstance(obj, dict):
                title = str(obj.get("title") or obj.get("name") or "")[:160]
        except Exception:
            pass
        jl = mp.with_name(f"{sid}.jsonl")
        text = tail_bytes(jl, 120_000) if jl.is_file() else ""
        if not title:
            title = session_title_from_text(text) or "Command Code"
        # Project key from path: projects/users-<name>/... → cwd unknown; use folder
        project = short_project(mp.parent.name)
        cwd = ""
        # settings.json sibling sometimes has cwd
        settings = mp.parent / "settings.json"
        if settings.is_file():
            try:
                s = json.loads(settings.read_text(encoding="utf-8", errors="replace"))
                if isinstance(s, dict):
                    cwd = str(s.get("cwd") or s.get("workingDirectory") or "")
            except Exception:
                pass
        if cwd:
            project = short_project(cwd) or project
        skill = "pending" if text_looks_pending(text) else ""
        # Also check permission / ask patterns unique to Command Code
        if not skill and text:
            low = text.lower()[-4000:]
            if any(x in low for x in ("permission", "awaiting", "needs_approval", "ask_user", '"ask"')):
                skill = "pending"
        mtime = file_mtime_ms(jl if jl.is_file() else mp)
        stats = session_stats(jl if jl.is_file() else mp, per_session=True)
        stats.update({k: v for k, v in observed_facts_from_text(text).items() if k not in stats})
        seen.add(sid)
        out.append((title[:160], 0, 0, last_tool_name_strict(text), skill, project[:48], (cwd or "")[:240], mtime, sid[:80], stats))
        if len(out) >= MAX_SESSIONS_PER_AGENT:
            break
    return out


def kimi_activities() -> list[tuple]:
    """Kimi Code CLI: ~/.kimi-code/sessions + session_index.jsonl"""
    home = Path(os.environ.get("KIMI_CODE_HOME") or (HOME / ".kimi-code"))
    out: list[tuple] = []
    index = home / "session_index.jsonl"
    sessions_root = home / "sessions"
    candidates: list[Path] = []
    if index.is_file():
        try:
            for ln in reversed(index.read_text(encoding="utf-8", errors="replace").splitlines()):
                if not ln.strip():
                    continue
                try:
                    obj = json.loads(ln)
                except Exception:
                    continue
                if not isinstance(obj, dict):
                    continue
                sdir = obj.get("sessionDir") or obj.get("session_dir")
                if isinstance(sdir, str) and sdir:
                    p = Path(sdir)
                    if not p.is_absolute():
                        p = home / p
                    if p.is_dir():
                        candidates.append(p)
                if len(candidates) >= MAX_SESSIONS_PER_AGENT:
                    break
        except OSError:
            pass
    if not candidates and sessions_root.is_dir():
        try:
            for p in sessions_root.rglob("state.json"):
                candidates.append(p.parent)
        except OSError:
            pass
        candidates = sorted(candidates, key=lambda p: p.stat().st_mtime if p.exists() else 0, reverse=True)[:MAX_SESSIONS_PER_AGENT]

    for sdir in candidates:
        state = sdir / "state.json"
        wire = sdir / "agents" / "main" / "wire.jsonl"
        title = cwd = sid = ""
        if state.is_file():
            try:
                obj = json.loads(state.read_text(encoding="utf-8", errors="replace"))
                if isinstance(obj, dict):
                    title = str(obj.get("title") or obj.get("lastPrompt") or "")[:160]
                    cwd = str(obj.get("workDir") or obj.get("cwd") or obj.get("workingDirectory") or "")
                    sid = str(obj.get("sessionId") or obj.get("id") or sdir.name)[:80]
            except Exception:
                pass
        text = tail_bytes(wire, 120_000) if wire.is_file() else ""
        if not title:
            title = session_title_from_text(text) or "Kimi session"
        project = short_project(cwd) if cwd else short_project(sdir.parent.name)
        skill = "pending" if text_looks_pending(text) else ""
        mtime = file_mtime_ms(wire if wire.is_file() else (state if state.is_file() else sdir))
        stats = session_stats(
            wire if wire.is_file() else (state if state.is_file() else sdir),
            per_session=True,
        )
        stats.update({k: v for k, v in observed_facts_from_text(text).items() if k not in stats})
        out.append((title[:160], 0, 0, last_tool_name_strict(text), skill, project[:48], (cwd or "")[:240], mtime, sid or sdir.name[:80], stats))
        if len(out) >= MAX_SESSIONS_PER_AGENT:
            break
    return out


def devin_activities() -> list[tuple]:
    return home_dir_activities(
        "devin",
        [
            HOME / ".devin",
            HOME / ".cognition",
            HOME / "Library" / "Application Support" / "Devin",
            HOME / "Library" / "Application Support" / "Cognition",
        ],
    )


def kiro_activities() -> list[tuple]:
    out = harvest_extension_storage("kiro", "kiro", "amazon.kiro", limit=MAX_SESSIONS_PER_AGENT)
    if len(out) < MAX_SESSIONS_PER_AGENT:
        out.extend(
            home_dir_activities(
                "kiro",
                [
                    HOME / ".kiro",
                    HOME / "Library" / "Application Support" / "Kiro",
                ],
                limit=MAX_SESSIONS_PER_AGENT - len(out),
            )
        )
    return out[:MAX_SESSIONS_PER_AGENT]


def junie_activities() -> list[tuple]:
    return home_dir_activities(
        "junie",
        [
            HOME / ".junie",
            HOME / "Library" / "Application Support" / "JetBrains" / "Junie",
            HOME / "Library" / "Application Support" / "Junie",
        ],
    )


def replit_activities() -> list[tuple]:
    # Local signal is weak; harvest quietly if any cache exists.
    return home_dir_activities(
        "replit",
        [
            HOME / ".replit",
            HOME / ".config" / "replit",
            HOME / "Library" / "Application Support" / "Replit",
        ],
    )


def windsurf_shell_activities() -> list[tuple]:
    """Windsurf IDE shell recent workspace — only if no cascade rows will cover it."""
    roots = [
        HOME / "Library" / "Application Support" / "Windsurf" / "User" / "workspaceStorage",
        HOME / ".windsurf",
    ]
    return home_dir_activities("windsurf", roots, limit=MAX_SESSIONS_PER_AGENT)


def amp_pending_from_logs() -> tuple[str, str, int]:
    """Return (skill, session, mtime) if latest Amp thread log looks blocked on user."""
    log_dirs = [
        HOME / ".local/share" / "amp" / "logs",
        HOME / ".amp" / "logs",
        HOME / "Library" / "Logs" / "amp",
    ]
    files: list[Path] = []
    for d in log_dirs:
        if d.is_dir():
            try:
                files.extend([p for p in d.glob("*.log") if p.is_file()])
                files.extend([p for p in d.glob("*.txt") if p.is_file()])
            except OSError:
                continue
    if not files:
        return "", "", 0
    files.sort(key=lambda p: p.stat().st_mtime if p.exists() else 0, reverse=True)
    for lf in files[:4]:
        try:
            text = tail_bytes(lf, 40_000)
        except Exception:
            continue
        if text_looks_pending(text):
            return "pending", lf.stem, file_mtime_ms(lf)
    return "", "", 0


def gemini_activities() -> list[tuple[str, int, int, str, str, str, str]]:
    """Gemini CLI chats under ~/.gemini/tmp/<project>/chats/."""
    projects_map: dict[str, str] = {}
    pj = HOME / ".gemini" / "projects.json"
    if pj.is_file():
        try:
            data = json.loads(pj.read_text(encoding="utf-8", errors="replace"))
            raw = data.get("projects") if isinstance(data, dict) else {}
            if isinstance(raw, dict):
                # cwd -> slug  ⇒  slug -> cwd
                projects_map = {str(v): str(k) for k, v in raw.items()}
        except Exception:
            pass

    paths = glob.glob(str(HOME / ".gemini" / "tmp" / "*" / "chats" / "session-*"))
    files = newest(paths, MAX_SESSIONS_PER_AGENT)
    out: list[tuple[str, int, int, str, str, str, str]] = []
    seen: set[str] = set()
    for f in files:
        slug = f.parent.parent.name  # tmp/<slug>/chats/file
        cwd = projects_map.get(slug, "")
        if not cwd:
            root = f.parent.parent / ".project_root"
            # also history/<slug>/.project_root
            alt = HOME / ".gemini" / "history" / slug / ".project_root"
            for candidate in (root, alt):
                if candidate.is_file():
                    try:
                        cwd = candidate.read_text(encoding="utf-8", errors="replace").strip()
                    except OSError:
                        cwd = ""
                    if cwd:
                        break
        project = short_project(cwd) if cwd else ""
        key = f.name  # session file — allow multi-session same project
        if key in seen:
            continue

        task = ""
        tool = ""
        tin = tout = 0
        try:
            lines = f.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if not isinstance(obj, dict):
                continue
            typ = str(obj.get("type") or "")
            if typ == "user" and not task:
                content = obj.get("content")
                if isinstance(content, str):
                    task = content.strip()
                elif isinstance(content, list):
                    bits = []
                    for c in content:
                        if isinstance(c, dict) and c.get("text"):
                            bits.append(str(c["text"]))
                        elif isinstance(c, str):
                            bits.append(c)
                    task = " ".join(bits).strip()
            # Best-effort tool / token scrape from serialized line
            blob = line
            if not tool:
                m = re.search(r'"functionCall"\s*:\s*\{[^}]*"name"\s*:\s*"([^"]+)"', blob)
                if m:
                    tool = m.group(1)
            tin = max(tin, sum_int_fields(blob, "input_tokens"), sum_int_fields(blob, "promptTokenCount"))
            tout = max(tout, sum_int_fields(blob, "output_tokens"), sum_int_fields(blob, "candidatesTokenCount"))

        if not (task or tool or tin or tout or cwd):
            continue
        seen.add(key)
        blob = "\n".join(lines[-120:]) if lines else ""
        skill = "pending" if gemini_has_unresolved_ask(blob) else ""
        stats = session_stats(f, per_session=True)
        stats.update({k: v for k, v in observed_facts_from_text(blob).items() if k not in stats})
        model = last_model_name(blob)
        if model and "model" not in stats:
            stats["model"] = model
        out.append(
            (
                task[:160],
                tin,
                tout,
                tool[:48],
                skill,
                project[:48],
                (cwd or "")[:240],
                file_mtime_ms(f),
                f.stem[:80],
                stats,
            )
        )
        if len(out) >= MAX_SESSIONS_PER_AGENT:
            break
    return out


def opencode_activities() -> list[tuple[str, int, int, str, str, str, str]]:
    """OpenCode SQLite sessions (~/.local/share/opencode/opencode.db)."""
    db = HOME / ".local/share" / "opencode" / "opencode.db"
    if not db.is_file():
        return []
    try:
        import sqlite3

        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=0.4)
        try:
            try:
                rows = con.execute(
                    f"""
                    SELECT id, title, directory, tokens_input, tokens_output,
                           time_updated, model
                    FROM session
                    WHERE IFNULL(time_archived, 0) = 0
                    ORDER BY time_updated DESC
                    LIMIT {MAX_SESSIONS_PER_AGENT}
                    """
                ).fetchall()
            except sqlite3.Error:
                # Older OpenCode databases predate the session.model column;
                # keep their titles/tokens observable instead of dropping the
                # entire collector on a harmless schema difference.
                legacy_rows = con.execute(
                    f"""
                    SELECT id, title, directory, tokens_input, tokens_output,
                           time_updated
                    FROM session
                    WHERE IFNULL(time_archived, 0) = 0
                    ORDER BY time_updated DESC
                    LIMIT {MAX_SESSIONS_PER_AGENT}
                    """
                ).fetchall()
                rows = [tuple(row) + ("",) for row in legacy_rows]
        finally:
            con.close()
    except Exception:
        return []

    out: list[tuple] = []
    seen: set[str] = set()
    pending_skill = opencode_pending_skill()
    try:
        detail_con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=0.4)
    except Exception:
        detail_con = None
    for sid, title, directory, tin, tout, tupd, model_raw in rows:
        title_s = str(title or "").strip()
        cwd = str(directory or "").strip()
        project = short_project(cwd)
        key = str(sid or "") or (project or cwd or title_s)
        if not key or key in seen:
            continue
        if not (title_s or tin or tout or cwd):
            continue
        seen.add(key)
        # OpenCode time_updated is often ms; normalize.
        try:
            ms = int(tupd or 0)
        except Exception:
            ms = 0
        if ms > 0 and ms < 10_000_000_000:
            ms *= 1000
        if ms <= 0:
            ms = file_mtime_ms(db)

        # OpenCode keeps the high-value runtime facts in the session row and
        # its part stream rather than in the title. Surface those facts so an
        # otherwise opaque SQLite session still answers “what is it doing?”
        # without exposing prompts or tool arguments.
        extra: dict = {}
        if isinstance(model_raw, str) and model_raw.strip():
            try:
                model_obj = json.loads(model_raw)
                if isinstance(model_obj, dict):
                    model = str(model_obj.get("id") or model_obj.get("model") or "").strip()
                else:
                    model = ""
            except Exception:
                model = model_raw.strip()
            if model:
                extra["model"] = model[:64]
        try:
            if detail_con is None:
                raise sqlite3.Error("details unavailable")
            part_rows = detail_con.execute(
                "SELECT data FROM part WHERE session_id = ? "
                "ORDER BY time_updated DESC LIMIT 80",
                (sid,),
            ).fetchall()
            part_count = detail_con.execute(
                "SELECT COUNT(*) FROM part WHERE session_id = ?", (sid,)
            ).fetchone()
            if part_count and int(part_count[0] or 0) > 0:
                extra["records"] = int(part_count[0])
            for (raw_part,) in part_rows:
                try:
                    part = json.loads(raw_part)
                except Exception:
                    continue
                if not isinstance(part, dict):
                    continue
                part_type = str(part.get("type") or "").lower()
                if part_type == "tool" and not extra.get("tool"):
                    tool = str(part.get("tool") or "").strip()
                    if tool:
                        extra["tool"] = tool[:48]
                    state = part.get("state")
                    if isinstance(state, dict) and str(state.get("status") or "").lower() in {
                        "pending", "running", "waiting"
                    }:
                        extra["phase"] = "working"
                elif part_type in {"step-finish", "step_finish"}:
                    extra.setdefault("phase", "turn_complete")
                    reason = str(part.get("reason") or "").strip().lower()
                    if reason in {"stop", "complete", "completed"}:
                        extra.setdefault("outcome", "completed")
        except sqlite3.Error:
            pass
        out.append(
            (
                title_s[:160],
                int(tin or 0),
                int(tout or 0),
                str(extra.pop("tool", "")),
                pending_skill if len(out) == 0 else "",  # attach wait to newest session only
                project[:48],
                cwd[:240],
                ms,
                str(sid)[:80],
                extra,
            )
        )
        if len(out) >= MAX_SESSIONS_PER_AGENT:
            break
    if detail_con is not None:
        detail_con.close()
    return out


def session_stats(path: Path, per_session: bool, budget_bytes: int = 2_000_000) -> dict:
    """`{"records": n, "started_ms": t}` for a file that **is** one session.

    `per_session` has no default on purpose. The first version computed both
    facts from any path it was handed, and `harvest_extension_storage` hands it
    a shared container: that collector reads a globalStorage blob holding a list
    of sessions, takes `obj[-1]`, and would then have reported the *container
    file's* birth time as that session's start and the container's whole line
    count as its records. A VS Code storage file created in March would have
    made a session opened five minutes ago read as four months old.

    That is a fabricated fact, which is the one thing this product does not do.
    So the flag is required at every call site, and a collector that cannot
    honestly claim "this file is this session" passes False and reports nothing.

    `records` is the record count, not a count of conversational turns: a JSONL
    transcript interleaves user messages, assistant messages, tool calls, tool
    results and token events, so thirty-four records is not thirty-four
    exchanges. It shipped in 0.28.0 labelled "turns", which overclaimed.

    Past `budget_bytes` it returns unknown rather than an estimate.
    """
    out: dict = {}
    if not per_session:
        return out
    try:
        st = path.stat()
    except OSError:
        return out

    born = getattr(st, "st_birthtime", 0) or st.st_ctime
    if born and born > 0:
        started = int(born * 1000)
        # A birth time later than the last write is not a birth time.
        if started <= int(st.st_mtime * 1000) + 1000:
            out["started_ms"] = started

    if path.suffix.lower() in (".jsonl", ".ndjson") and st.st_size <= budget_bytes:
        if _spend_scan_budget(st.st_size):
            try:
                records = 0
                with path.open("rb") as fh:
                    while chunk := fh.read(1 << 20):
                        records += chunk.count(b"\n")
                if records > 0:
                    out["records"] = records
            except OSError:
                pass
    return out

EVIDENCE_SESSION = "session"
EVIDENCE_CACHE = "cache"

# The collector contract is also the product contract. A function existing in
# this file does not make its output a structured session: several IDE agents
# only expose private extension/cache blobs whose shape changes between builds.
# Those rows are still useful when they contain a real title or workspace, but
# the UI must never present them with the same certainty as a transcript,
# thread, composer or session database.
HARVEST_CONTRACTS = {
    "claude": EVIDENCE_SESSION,
    "codex": EVIDENCE_SESSION,
    "cursor": EVIDENCE_SESSION,
    "grok": EVIDENCE_SESSION,
    "pi": EVIDENCE_SESSION,
    "amp": EVIDENCE_SESSION,
    "aider": EVIDENCE_SESSION,
    "gemini": EVIDENCE_SESSION,
    "copilot": EVIDENCE_SESSION,
    "opencode": EVIDENCE_SESSION,
    "goose": EVIDENCE_SESSION,
    "openhands": EVIDENCE_SESSION,
    "continue": EVIDENCE_SESSION,
    "droid": EVIDENCE_SESSION,
    "command_code": EVIDENCE_SESSION,
    "kimi": EVIDENCE_SESSION,
    "amazon_q": EVIDENCE_CACHE,
    "cline": EVIDENCE_CACHE,
    "roo": EVIDENCE_CACHE,
    "cascade": EVIDENCE_CACHE,
    "windsurf": EVIDENCE_CACHE,
    "augment": EVIDENCE_CACHE,
    "zed_agent": EVIDENCE_CACHE,
    "trae": EVIDENCE_CACHE,
    "warp_agent": EVIDENCE_CACHE,
    "kilo": EVIDENCE_CACHE,
    "devin": EVIDENCE_CACHE,
    "kiro": EVIDENCE_CACHE,
    "junie": EVIDENCE_CACHE,
    "replit": EVIDENCE_CACHE,
    "antigravity": EVIDENCE_CACHE,
}

# What each adapter can truthfully contribute when its local source contains
# the corresponding fact. This is a capability contract, not a promise that an
# idle installation has populated every value. Every covered agent must have
# more than process detection: goal + workspace + activity + evidence are the
# minimum useful observation.
_BASE = frozenset(("goal", "workspace", "activity", "evidence"))
_CACHE_RICH = _BASE | frozenset(
    ("phase", "model", "mode", "progress", "outcome", "records", "session_age", "wait")
)
OBSERVABILITY_CONTRACTS = {
    "claude": _BASE | frozenset(("tokens", "last_action", "records", "session_age", "subagents", "wait")),
    "codex": _BASE | frozenset(("tokens", "last_action", "session_age", "subagents", "wait")),
    "cursor": _BASE | frozenset(("mode", "wait")),
    "grok": _BASE | frozenset(("phase", "model", "mode", "turns", "failures", "files", "context", "outcome", "wait")),
    "pi": _BASE | frozenset(("tokens", "last_action", "records", "session_age", "wait")),
    "amp": _BASE | frozenset(("mode", "session_age", "records", "wait")),
    "aider": _BASE | frozenset(("last_action", "session_age", "records", "wait")),
    "gemini": _BASE | frozenset(("tokens", "last_action", "session_age", "records", "wait")),
    "copilot": _BASE | frozenset(("last_action", "session_age", "records", "wait")),
    "opencode": _BASE | frozenset(("tokens", "wait")),
    "goose": _BASE | frozenset(("last_action", "session_age", "records", "wait")),
    "openhands": _BASE | frozenset(("last_action", "session_age", "records", "wait")),
    "continue": _BASE | frozenset(("last_action", "session_age", "records", "wait")),
    "droid": _BASE | frozenset(("last_action", "session_age", "records", "wait")),
    "command_code": _BASE | frozenset(("last_action", "session_age", "records", "wait")),
    "kimi": _BASE | frozenset(("last_action", "session_age", "records", "wait")),
    "amazon_q": _CACHE_RICH,
    "cline": _CACHE_RICH,
    "roo": _CACHE_RICH,
    "cascade": _CACHE_RICH | frozenset(("session_age", "records")),
    "windsurf": _CACHE_RICH | frozenset(("session_age", "records")),
    "augment": _CACHE_RICH,
    "zed_agent": _CACHE_RICH,
    "trae": _CACHE_RICH - frozenset(("wait",)),
    "warp_agent": _CACHE_RICH - frozenset(("wait",)),
    "kilo": _CACHE_RICH,
    "devin": _CACHE_RICH - frozenset(("wait",)),
    "kiro": _CACHE_RICH,
    "junie": _CACHE_RICH - frozenset(("wait",)),
    "replit": _CACHE_RICH - frozenset(("wait",)),
    "antigravity": _CACHE_RICH - frozenset(("wait",)),
}

# Cheap source presence checks for runtime health. These do not crawl, parse,
# or expose vendor paths; they answer the question that "no recent data"
# previously blurred: is there any local source for this adapter at all?
#
# Some agents keep sessions inside project folders (notably Aider), so their
# executable also counts as an installed source even when no session file has
# been found yet.
COLLECTOR_SOURCE_ROOTS = {
    "claude": (HOME / ".claude",),
    "codex": (HOME / ".codex",),
    "cursor": (HOME / "Library/Application Support/Cursor",),
    "grok": (HOME / ".grok",),
    "pi": (HOME / ".pi",),
    "amp": (HOME / ".local/share/amp", HOME / ".amp"),
    "gemini": (HOME / ".gemini",),
    "opencode": (HOME / ".local/share/opencode",),
    "aider": (HOME / ".aider",),
    "goose": (
        HOME / ".config/goose",
        HOME / ".local/share/goose",
        HOME / "Library/Application Support/Goose",
    ),
    "cline": (
        HOME / "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev",
        HOME / "Library/Application Support/Cursor/User/globalStorage/saoudrizwan.claude-dev",
    ),
    "roo": (
        HOME / "Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline",
        HOME / "Library/Application Support/Cursor/User/globalStorage/rooveterinaryinc.roo-cline",
    ),
    "continue": (HOME / ".continue",),
    "copilot": (HOME / ".copilot", HOME / ".config/copilot"),
    "amazon_q": (
        HOME / ".aws/amazonq",
        HOME / ".aws/amazon-q",
        HOME / "Library/Application Support/Amazon Q",
    ),
    "cascade": (
        HOME / ".codeium",
        HOME / ".windsurf",
        HOME / "Library/Application Support/Windsurf",
    ),
    "windsurf": (
        HOME / ".windsurf",
        HOME / "Library/Application Support/Windsurf",
    ),
    "augment": (HOME / ".augment", HOME / ".auggie"),
    "zed_agent": (HOME / ".zed", HOME / ".config/zed"),
    "trae": (HOME / ".trae", HOME / "Library/Application Support/Trae"),
    "warp_agent": (
        HOME / ".warp",
        HOME / "Library/Application Support/dev.warp.Warp-Stable",
    ),
    "openhands": (HOME / ".openhands", HOME / ".openhands-state"),
    "kilo": (
        HOME / "Library/Application Support/Code/User/globalStorage/kilocode.kilo-code",
        HOME / "Library/Application Support/Cursor/User/globalStorage/kilocode.kilo-code",
    ),
    "devin": (HOME / ".devin", HOME / ".cognition"),
    "kiro": (HOME / ".kiro", HOME / "Library/Application Support/Kiro"),
    "junie": (
        HOME / ".junie",
        HOME / "Library/Application Support/JetBrains/Junie",
    ),
    "replit": (HOME / ".replit", HOME / ".config/replit"),
    "droid": (HOME / ".factory",),
    "command_code": (HOME / ".commandcode",),
    "kimi": (HOME / ".kimi-code",),
    "antigravity": (
        HOME / ".antigravity",
        HOME / "Library/Application Support/Antigravity",
    ),
}

COLLECTOR_COMMANDS = {
    "claude": ("claude",),
    "codex": ("codex",),
    "grok": ("grok",),
    "pi": ("pi",),
    "amp": ("amp",),
    "gemini": ("gemini",),
    "opencode": ("opencode",),
    "aider": ("aider",),
    "goose": ("goose",),
    "copilot": ("copilot",),
    "continue": ("continue", "continue-cli"),
    "openhands": ("openhands",),
    "devin": ("devin",),
    "kiro": ("kiro",),
    "junie": ("junie",),
    "droid": ("droid",),
    "command_code": ("cmd", "command-code"),
    "kimi": ("kimi",),
}


def collector_source_present(agent: str) -> bool:
    if any(path.exists() for path in COLLECTOR_SOURCE_ROOTS.get(agent, ())):
        return True
    return any(shutil.which(command) for command in COLLECTOR_COMMANDS.get(agent, ()))


def useful_cache_task(agent: str, task: str) -> bool:
    """Whether a cache title is an observed user fact rather than our fallback."""
    value = " ".join((task or "").strip().split())
    if not value:
        return False
    low = value.lower()
    generic = {
        agent.lower(),
        "chat",
        "new chat",
        "new session",
        "session",
        "thread",
        "task",
        "untitled",
    }
    generic.update(f"{agent.lower()} {suffix}" for suffix in ("agent", "chat", "session", "task", "thread"))
    return low not in generic


def generic_task_title(agent: str, task: str) -> bool:
    """Whether a title is only an adapter fallback, not a user goal.

    Structured collectors are allowed to emit a row without a title when they
    have another useful fact (workspace, phase, tokens, model, or a live tool).
    They must not promote a bare ``Codex session`` / ``Grok session`` into a
    first-class task: that is indistinguishable from a random cache file and
    makes the tray look populated while saying nothing actionable.
    """
    value = " ".join((task or "").strip().split()).lower()
    if not value:
        return True
    agent_low = agent.strip().lower()
    agent_label = re.sub(r"[_-]+", " ", agent_low).strip()
    generic = {
        agent_low,
        agent_label,
        "chat",
        "new chat",
        "new session",
        "session",
        "thread",
        "task",
        "untitled",
    }
    generic.update(
        f"{agent_low} {suffix}"
        for suffix in ("agent", "chat", "session", "task", "thread")
    )
    generic.update(
        f"{agent_label} {suffix}"
        for suffix in ("agent", "chat", "session", "task", "thread")
    )
    return value in generic


EMITTED_COUNTS: dict[str, int] = {}


def emit(
    agent: str,
    task: str,
    tin: int,
    tout: int,
    tool: str,
    skill: str,
    project: str = "",
    cwd: str = "",
    mtime_ms: int = 0,
    sub_run: int = 0,
    sub_total: int = 0,
    session_id: str = "",
    records: int = 0,
    started_ms: int = 0,
    evidence: str = EVIDENCE_SESSION,
    phase: str = "",
    outcome: str = "",
    model: str = "",
    mode: str = "",
    errors: int = 0,
    files: int = 0,
    context_pct: int = 0,
    progress_done: int = 0,
    progress_total: int = 0,
) -> None:
    def clean(s: str) -> str:
        return (
            redact_sensitive(s)
            .replace("\t", " ")
            .replace("\n", " ")
            .replace("\r", " ")
            .strip()
        )

    # Do not pre-filter stale rows here. Swift owns the freshness policy and can
    # keep old session evidence when it matches a currently live process. The
    # old Python filter ran before that merge and reduced long-running agents
    # such as Amp to "Process only" even though their goal/workspace were known.
    # Refuse harvest-only rows with no mtime (prevents eternal "running" ghosts).
    if mtime_ms <= 0 and sub_run == 0 and sub_total == 0:
        return
    evidence = evidence if evidence in (EVIDENCE_SESSION, EVIDENCE_CACHE) else EVIDENCE_CACHE
    # A random cache file is not an observation. Cache-backed collectors must
    # have either a user-recognisable title or a real absolute workspace path;
    # extension folder names and "<agent> session" placeholders are dropped.
    if evidence == EVIDENCE_CACHE and not useful_cache_task(agent, task):
        if not (cwd or "").strip().startswith("/"):
            return

    # Structured stores can legitimately omit a title, but a bare fallback
    # title is still not useful by itself. Keep the row only when another
    # observed fact can answer what is happening (workspace, action, volume,
    # lifecycle, model, or progress). This prevents every private session
    # directory from becoming a meaningless "Agent session" row.
    if generic_task_title(agent, task):
        has_signal = any(
            (
                (cwd or "").strip().startswith("/"),
                bool(tool or skill),
                tin > 0,
                tout > 0,
                sub_run > 0,
                sub_total > 0,
                bool(
                    phase
                    or outcome
                    or model
                    or (mode and mode.strip().lower() not in {"local", "default", "unknown"})
                ),
                errors > 0,
                files > 0,
                context_pct > 0,
                progress_done > 0,
                progress_total > 0,
            )
        )
        if not has_signal:
            return

    EMITTED_COUNTS[agent] = EMITTED_COUNTS.get(agent, 0) + 1
    print(
        f"{agent}\t{clean(task)}\t{tin}\t{tout}\t{clean(tool)}\t{clean(skill)}\t"
        f"{clean(project)}\t{clean(cwd)}\t{mtime_ms}\t{sub_run}\t{sub_total}\t{clean(session_id)}\t"
        f"{records}\t{started_ms}\t{evidence}\t{clean(phase)}\t{clean(outcome)}\t"
        f"{clean(model)}\t{clean(mode)}\t{max(0, int(errors or 0))}\t{max(0, int(files or 0))}\t"
        f"{max(0, min(100, int(context_pct or 0)))}\t{max(0, int(progress_done or 0))}\t"
        f"{max(0, int(progress_total or 0))}"
    )


def emit_row(
    agent: str,
    row: tuple,
    path: Path | None = None,
    evidence: str | None = None,
) -> None:
    """Accept 7/8/10/11/12-tuple activity rows; stamp mtime from path when needed.

    A row may carry a trailing **dict** of extras (`turns`, `started_ms`).
    A dict rather than two more positional fields on purpose: this protocol
    dispatches on tuple length, so appending to it would make a 9-tuple mean
    either "8 fields plus a session id" or "7 fields plus two metrics", and the
    wrong reading would be silent. `isinstance(row[-1], dict)` cannot collide
    with any existing shape.
    """
    extra: dict = {}
    if row and isinstance(row[-1], dict):
        extra = row[-1]
        row = row[:-1]
    records = int(extra.get("records") or 0)
    started_ms = int(extra.get("started_ms") or 0)
    row_evidence = str(extra.get("evidence") or evidence or HARVEST_CONTRACTS.get(agent, EVIDENCE_CACHE))

    def emit_x(*args) -> None:
        emit(
            *args,
            records=records,
            started_ms=started_ms,
            evidence=row_evidence,
            phase=str(extra.get("phase") or ""),
            outcome=str(extra.get("outcome") or ""),
            model=str(extra.get("model") or ""),
            mode=str(extra.get("mode") or ""),
            errors=int(extra.get("errors") or 0),
            files=int(extra.get("files") or 0),
            context_pct=int(extra.get("context_pct") or 0),
            progress_done=int(extra.get("progress_done") or 0),
            progress_total=int(extra.get("progress_total") or 0),
        )

    if len(row) >= 12:
        emit_x(agent, *row[:12])
        return
    if len(row) >= 11:
        # 10-tuple + session OR 11 with subs already
        emit_x(agent, *row[:11])
        return
    if len(row) >= 10:
        emit_x(agent, *row[:10])
        return
    if len(row) >= 9:
        # 8-tuple + session_id
        task, tin, tout, tool, skill, project, cwd, ms, sid = row[:9]
        emit_x(agent, task, tin, tout, tool, skill, project, cwd, int(ms or 0), 0, 0, str(sid or ""))
        return
    if len(row) >= 8:
        task, tin, tout, tool, skill, project, cwd, ms = row[:8]
        emit_x(agent, task, tin, tout, tool, skill, project, cwd, int(ms or 0), 0, 0)
        return
    task, tin, tout, tool, skill, project, cwd = row[:7]
    ms = file_mtime_ms(path) if path is not None else 0
    emit_x(agent, task, tin, tout, tool, skill, project, cwd, ms, 0, 0)


def aider_activities() -> list[tuple]:
    """Aider: recent .aider.chat.history.md — ask/confirm at tail → pending."""
    paths: list[Path] = []
    # The old adapter recursively walked ~/Documents and ~/Desktop to depth 3.
    # On a real iCloud/large Documents tree that one collector consumed the
    # entire harvest deadline, so every adapter after Aider disappeared. Ask
    # Spotlight for the exact filename first; it is indexed, bounded, and does
    # not enumerate unrelated user files.
    try:
        found = subprocess.run(
            ["/usr/bin/mdfind", "-0", 'kMDItemFSName == ".aider.chat.history.md"'],
            capture_output=True,
            timeout=0.45,
            check=False,
        ).stdout
        home_prefix = str(HOME) + os.sep
        for raw in found.split(b"\0"):
            if not raw:
                continue
            value = raw.decode("utf-8", errors="replace")
            if value.startswith(home_prefix):
                paths.append(Path(value))
                if len(paths) >= MAX_SESSIONS_PER_AGENT:
                    break
    except (OSError, subprocess.SubprocessError):
        pass

    roots = [
        HOME / "code",
        HOME / "src",
        HOME / "dev",
        HOME / "Projects",
        HOME / "Pulse",
    ]
    # Escape hatch instead of hardcoded developer paths:
    #   PULSE_AIDER_ROOTS=/path/one:/path/two
    for extra in (os.environ.get("PULSE_AIDER_ROOTS") or "").split(":"):
        extra = extra.strip()
        if extra:
            roots.append(Path(extra).expanduser())
    seen_files: set[str] = set()

    def scan_root(root: Path, max_depth: int = 3) -> None:
        if not root.is_dir() or len(paths) >= MAX_SESSIONS_PER_AGENT:
            return
        root_depth = len(root.parts)
        try:
            for dirpath, dirnames, filenames in os.walk(root):
                depth = len(Path(dirpath).parts) - root_depth
                if depth > max_depth:
                    dirnames[:] = []
                    continue
                # Skip huge / noisy trees
                dirnames[:] = [
                    d
                    for d in dirnames
                    if d not in {".git", "node_modules", "Library", ".Trash", "DerivedData", "build", ".build"}
                ]
                if ".aider.chat.history.md" in filenames:
                    f = Path(dirpath) / ".aider.chat.history.md"
                    try:
                        if f.stat().st_mtime < time.time() - FRESH_SEC:
                            continue
                    except OSError:
                        continue
                    sp = str(f)
                    if sp in seen_files:
                        continue
                    seen_files.add(sp)
                    paths.append(f)
                    if len(paths) >= MAX_SESSIONS_PER_AGENT:
                        return
        except OSError:
            return

    for root in roots:
        scan_root(root)
        if len(paths) >= MAX_SESSIONS_PER_AGENT:
            break
    files = newest([str(p) for p in paths], MAX_SESSIONS_PER_AGENT)
    out: list[tuple] = []
    for f in files:
        text = ""
        try:
            text = Path(f).read_text(encoding="utf-8", errors="replace")[-12000:]
        except OSError:
            continue
        cwd = str(Path(f).parent)
        project = short_project(cwd)
        # Last meaningful non-empty line as task hint
        task = ""
        for line in reversed(text.splitlines()):
            s = line.strip()
            if s and not s.startswith("#"):
                task = s[:160]
                break
        low = text.lower()
        pending = False
        if any(
            x in low[-2000:]
            for x in (
                "waiting for your response",
                "awaiting confirmation",
                "y/n",
                "(y/n)",
                "add these files to the chat",
                "allow this",
            )
        ):
            pending = True
        skill = "pending" if pending else ""
        if not (task or project or pending):
            continue
        out.append((
            task or "Aider session",
            0,
            0,
            last_tool_name_strict(text),
            skill,
            project[:48],
            cwd[:240],
            file_mtime_ms(Path(f)),
            Path(f).parent.name,
            session_stats(Path(f), per_session=True),
        ))
        if len(out) >= MAX_SESSIONS_PER_AGENT:
            break
    return out


def goose_activities() -> list[tuple]:
    """Goose: session JSON under ~/.config/goose or ~/.local/share/goose."""
    roots = [
        HOME / ".config" / "goose",
        HOME / ".local" / "share" / "goose",
        HOME / "Library" / "Application Support" / "Goose",
    ]
    files: list[Path] = []
    for root in roots:
        if not root.is_dir():
            continue
        for pat in ("**/*.json", "**/sessions/*.json", "**/session*.json"):
            try:
                files.extend(root.glob(pat))
            except OSError:
                pass
    files = [Path(p) for p in newest([str(f) for f in files if f.is_file()], MAX_SESSIONS_PER_AGENT)]
    out: list[tuple] = []
    seen: set[str] = set()
    for f in files:
        try:
            obj = json.loads(f.read_text(encoding="utf-8", errors="replace"))
        except Exception:
            continue
        if not isinstance(obj, dict):
            continue
        sid = str(obj.get("id") or obj.get("session_id") or f.stem)
        if sid in seen:
            continue
        title = str(obj.get("name") or obj.get("title") or obj.get("description") or "").strip()
        cwd = str(obj.get("working_dir") or obj.get("cwd") or obj.get("directory") or "")
        status = str(obj.get("status") or obj.get("state") or "").lower()
        pending = status in ("waiting", "awaiting_approval", "needs_input", "pending", "paused")
        # Nested ask/approval markers only count on a recently touched session,
        # and only for explicit markers — a bare "waiting" string anywhere in the
        # blob used to mark every Goose session as Needs-you (fake Waiting).
        if not pending and f.stat().st_mtime > time.time() - PENDING_FRESH_SEC:
            blob = json.dumps(obj)[-8000:].lower()
            pending = any(
                x in blob
                for x in ('"awaiting_approval"', '"needs_permission"', '"ask_user"')
            )
        if not (title or cwd or pending):
            continue
        # skip huge unrelated json
        if f.stat().st_size > 2_000_000:
            continue
        seen.add(sid)
        project = short_project(cwd)
        skill = "pending" if pending else ""
        stats = session_stats(f, per_session=True)
        stats.update({k: v for k, v in observed_facts_from_text(json.dumps(obj)).items() if k not in stats})
        out.append((title[:160] or "Goose session", 0, 0, "", skill, project[:48], cwd[:240], file_mtime_ms(f), sid[:80], stats))
        if len(out) >= MAX_SESSIONS_PER_AGENT:
            break
    return out


def guard(labels: str | tuple[str, ...], body) -> None:
    """Run one agent's harvest in isolation.

    Every harvester touches other tools' private files, so any of them can hit a
    vanished path, a locked sqlite db, or unexpected JSON. Without this, one bad
    agent raised out of main(), the script exited non-zero, and Pulse threw away
    the whole scan (`harvestUnreliable`) — a single broken harvester blinded all
    32 agents.
    """
    agent_labels = (labels,) if isinstance(labels, str) else labels
    label = "/".join(agent_labels)
    before = {agent: EMITTED_COUNTS.get(agent, 0) for agent in agent_labels}
    trace = os.environ.get("PULSE_HARVEST_TRACE") == "1"
    started = time.monotonic()
    error_kind = ""
    previous_alarm = signal.getsignal(signal.SIGALRM)
    signal.signal(signal.SIGALRM, _collector_timeout)
    deadline = max(
        COLLECTOR_TIMEOUT_OVERRIDES.get(agent, COLLECTOR_TIMEOUT_SEC)
        for agent in agent_labels
    )
    signal.setitimer(signal.ITIMER_REAL, deadline)
    if trace:
        print(f"# pulse trace: begin {label}", file=sys.stderr, flush=True)
    try:
        body()
    except Exception as exc:  # harvest is best-effort by design
        error_kind = type(exc).__name__
        print(f"# pulse: {label} harvest failed: {type(exc).__name__}: {exc}", file=sys.stderr)
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_alarm)
        elapsed_ms = max(0, int((time.monotonic() - started) * 1000))
        for agent in agent_labels:
            emitted = max(0, EMITTED_COUNTS.get(agent, 0) - before[agent])
            source_present = collector_source_present(agent)
            if emitted:
                status = "observed"
            elif error_kind in ("PermissionError",):
                status = "permission_denied"
            elif error_kind in (
                "JSONDecodeError", "KeyError", "TypeError", "ValueError",
                "DatabaseError", "OperationalError",
            ):
                status = "schema_mismatch"
            elif error_kind:
                status = "failed"
            elif source_present:
                status = "no_sessions"
            else:
                status = "source_absent"
            # Runtime adapter health shares the existing scan stream. It does
            # not expose vendor paths or exception messages and does not cost a
            # second walk over 32 private stores.
            print(
                f"#health\t{agent}\t{status}\t{elapsed_ms}\t{emitted}\t{error_kind}\t"
                f"{1 if source_present else 0}",
                flush=True,
            )
        if trace:
            print(f"# pulse trace: end {label} {elapsed_ms / 1000:.3f}s", file=sys.stderr, flush=True)


def emit_all(agent: str, rows, evidence: str | None = None) -> None:
    for row in rows:
        emit_row(agent, row, evidence=evidence)


def claude_block() -> None:
    # `emit`, not `emit_row`, was the reason Claude could never carry the new
    # facts: the extras sentinel is unpacked by `emit_row`, and this path
    # skipped it entirely. Claude is the agent most people actually run, so
    # "23 of 32 harvesters wired" meant very little while this line stood.
    for row in claude_activities():
        emit_row("claude", row, evidence=HARVEST_CONTRACTS["claude"])


def amp_block() -> None:
    amp_skill, amp_sid, amp_ms = amp_pending_from_logs()
    amp_rows = amp_activities()
    if amp_rows:
        for i, row in enumerate(amp_rows):
            if i == 0 and amp_skill:
                # Lift the extras off first.
                #
                # This rewrites positions by index, and the stats dict sits at
                # index 8 on an Amp thread row — so `lst[8] = amp_sid` wrote
                # the session id straight over it and the metrics vanished
                # whenever a pending was detected. Positional surgery and a
                # trailing sentinel do not mix; separate them, then reattach.
                lst = list(row)
                extras = lst.pop() if lst and isinstance(lst[-1], dict) else None
                while len(lst) < 8:
                    lst.append("" if len(lst) != 7 else 0)
                if len(lst) >= 5:
                    lst[4] = amp_skill
                if len(lst) >= 9:
                    lst[8] = amp_sid or lst[8]
                elif amp_sid:
                    # 8-tuple → add session
                    if len(lst) == 8:
                        lst.append(amp_sid)
                if extras is not None:
                    lst.append(extras)
                emit_row("amp", tuple(lst), evidence=HARVEST_CONTRACTS["amp"])
            else:
                emit_row("amp", row, evidence=HARVEST_CONTRACTS["amp"])
    elif amp_skill:
        emit(
            "amp",
            "Amp thread",
            0,
            0,
            "",
            amp_skill,
            "",
            "",
            amp_ms or int(time.time() * 1000),
            0,
            0,
            amp_sid,
            evidence=HARVEST_CONTRACTS["amp"],
        )


def cascade_block() -> None:
    cascade_rows = cascade_windsurf_activities()
    for row in cascade_rows:
        emit_row("cascade", row, evidence=HARVEST_CONTRACTS["cascade"])
    if not cascade_rows:
        for row in windsurf_shell_activities():
            emit_row("windsurf", row, evidence=HARVEST_CONTRACTS["windsurf"])


def simple(agent: str, fn):
    """One agent whose harvester is a plain `() -> list[row]`."""
    return (agent, lambda: emit_all(agent, fn(), evidence=HARVEST_CONTRACTS[agent]))


# Emission order is preserved from the pre-0.21.1 inline main(); each entry now
# runs under `guard` so one failure cannot take the rest of the scan with it.
HARVESTERS = (
    ("claude", claude_block),
    simple("codex", codex_activities),
    simple("cursor", cursor_activities),
    simple("grok", grok_activities),
    simple("pi", pi_activities),
    ("amp", amp_block),
    simple("gemini", gemini_activities),
    simple("opencode", opencode_activities),
    simple("aider", aider_activities),
    simple("goose", goose_activities),
    # 0.15 backfill + hot agents
    simple("cline", cline_activities),
    simple("roo", roo_activities),
    simple("continue", continue_activities),
    simple("copilot", copilot_activities),
    simple("amazon_q", amazon_q_activities),
    (("cascade", "windsurf"), cascade_block),
    simple("augment", augment_activities),
    simple("zed_agent", zed_agent_activities),
    simple("trae", trae_activities),
    simple("warp_agent", warp_agent_activities),
    simple("openhands", openhands_activities),
    simple("kilo", kilo_activities),
    simple("devin", devin_activities),
    simple("kiro", kiro_activities),
    simple("junie", junie_activities),
    simple("replit", replit_activities),
    simple("droid", droid_activities),
    simple("command_code", command_code_activities),
    simple("kimi", kimi_activities),
    simple("antigravity", antigravity_activities),
)


def main() -> None:
    for label, body in HARVESTERS:
        guard(label, body)


if __name__ == "__main__":
    main()
