#!/usr/bin/env python3
"""Pulse hook receiver — Claude Code / Codex → attention.tsv

Usage:
  pulse_hook.py <agent> [kind]          # kind from argv or stdin JSON
  echo '{...}' | pulse_hook.py claude

TSV columns (Attention Protocol v1):
  agent \\t kind \\t ms \\t message \\t session \\t cwd

Exit 0 always so agent hooks never block the agent.
Unknown kinds soft-fail (no write) — same gate as PulseBar --hook.
"""
from __future__ import annotations

import base64
import fcntl
import hashlib
import hmac
import json
import os
import re
import socket
import sys
import time
from pathlib import Path

MAX_LINES = 80
HEADER = "# pulse-attention v1 (agent\\tkind\\tms\\tmessage\\tsession\\tcwd)\n"
WAITING_KINDS = frozenset({"permission", "idle_prompt", "waiting"})
CLEAR_KINDS = frozenset({"done", "stop"})
LIFECYCLE_KINDS = frozenset({"subagent_start", "subagent_stop"})
ACCEPTED_KINDS = WAITING_KINDS | CLEAR_KINDS | LIFECYCLE_KINDS

# Hooks receive untrusted agent payloads. Redacting only in Swift would leave
# the same credential in attention.tsv on disk and in any copied diagnostics.
# Keep this small and dependency-free because the hook runs inside vendor
# processes and must never block them on importing Pulse's UI code.
_SENSITIVE_RULES = (
    (re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{12,}\b", re.I), "••••"),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{12,}\b", re.I), "••••"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{12,}\b", re.I), "••••"),
    (re.compile(r"\bxox[a-z]-[A-Za-z0-9-]{12,}\b", re.I), "••••"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "••••"),
    (re.compile(r"\b(Bearer\s+)[A-Za-z0-9._~+/\-=]{8,}", re.I), r"\1••••"),
    (
        re.compile(
            r"\b((?:api[_-]?key|access[_-]?token|auth[_-]?token|secret|password|passwd|token)\s*[:=]\s*['\"]?)[^\s'\";,]{8,}",
            re.I,
        ),
        r"\1••••",
    ),
    (re.compile(r"(https?://[^/\s:@]+:)[^@\s/]+@", re.I), r"\1••••@"),
    (re.compile(r"(\b(?:ssh\s+)?-i\s+)(?:~|/)[^\s'\"]+", re.I), r"\1••••"),
    (
        re.compile(
            r"-----BEGIN[ A-Z0-9_-]*PRIVATE KEY-----.*?-----END[ A-Z0-9_-]*PRIVATE KEY-----",
            re.I | re.S,
        ),
        "••••",
    ),
)


def redact_sensitive(value: str) -> str:
    result = value or ""
    for pattern, replacement in _SENSITIVE_RULES:
        result = pattern.sub(replacement, result)
    return result


def clean_field(value: object, limit: int) -> str:
    """Bound and sanitize one TSV field before it is persisted."""
    return (
        redact_sensitive(str(value or ""))
        .replace("\t", " ")
        .replace("\n", " ")
        .replace("\r", " ")
        .strip()[:limit]
    )


def pulse_dir() -> Path:
    override = os.environ.get("PULSE_HOME")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "Pulse"


def attention_path() -> Path:
    return pulse_dir() / "attention.tsv"


def parse_kind_from_json(payload: dict) -> str:
    ntype = payload.get("notification_type") or payload.get("notificationType") or ""
    if ntype:
        return str(ntype)
    event = payload.get("hook_event_name") or payload.get("hookEventName") or ""
    if event in ("Stop", "SubagentStop"):
        return "stop"
    if event == "Notification":
        return str(payload.get("notification_type") or "waiting")
    if event == "PermissionRequest":
        return "permission"
    t = payload.get("type") or payload.get("event") or payload.get("method") or ""
    if t:
        return str(t)
    return "waiting"


def normalize_kind(kind: str) -> str:
    k = (kind or "").strip()
    low = k.lower().replace("-", "_")
    # Codex / OpenAI notify + rollout-adjacent event names
    mapping = {
        "agent-turn-complete": "done",
        "agent_turn_complete": "done",
        "agent_completed": "done",
        "turn_complete": "done",
        "task_complete": "done",
        "exec_approval_request": "permission",
        "apply_patch_approval_request": "permission",
        "approval_request": "permission",
        "pending_approval": "permission",
        "request_user_input": "idle_prompt",
        "user_input_request": "idle_prompt",
        "elicitation_dialog": "idle_prompt",
        "permission_prompt": "permission",
        "idle_prompt": "idle_prompt",
        "idle": "idle_prompt",
        "agent_needs_input": "idle_prompt",
        "needs_input": "idle_prompt",
        "subagent_start": "subagent_start",
        "subagent_stop": "subagent_stop",
        "subagent": "subagent_start",
        "permission": "permission",
        "stop": "stop",
        "done": "done",
        "waiting": "waiting",
    }
    if low in mapping:
        return mapping[low]
    if "approval" in low and "response" not in low and "decision" not in low:
        return "permission"
    if "user_input" in low and "response" not in low:
        return "idle_prompt"
    return "waiting" if not k else low


def accepts_write(kind: str) -> bool:
    return normalize_kind(kind) in ACCEPTED_KINDS


def message_from_json(payload: dict) -> str:
    for key in (
        "last_assistant_message",
        "message",
        "body",
        "reason",
        "title",
        "content",
        "prompt",
    ):
        v = payload.get(key)
        if isinstance(v, str) and v.strip():
            return v.strip().replace("\t", " ").replace("\n", " ")[:200]
    return tool_descriptor(payload)


def condense_one_line(raw: str, limit: int = 140) -> str:
    """A banner, a tray row and a TSV field are all single-line."""
    folded = " ".join(raw.split())
    return folded if len(folded) <= limit else folded[: limit - 1] + "…"


def tool_descriptor(payload: dict) -> str:
    """What is actually being asked, when the vendor sends no prose.

    Claude's PermissionRequest payload has no ``message``: the ask *is* the
    tool call. Field priority mirrors the vendor's own permission label
    (command -> file_path -> url), and mirrors
    ``PulseHookReceiver.toolDescriptor`` line for line — the two ends must
    describe one approval the same way.
    """
    tool = str(payload.get("tool_name") or "").strip()
    if not tool:
        return ""
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return tool
    for key in ("command", "file_path", "url", "path", "notebook_path", "pattern", "query"):
        raw = tool_input.get(key)
        if isinstance(raw, str):
            target = condense_one_line(raw)
            if target:
                return f"{tool}: {target}"
    return tool


def session_from_json(payload: dict) -> str:
    for key in (
        "session_id",
        "sessionId",
        "thread_id",
        "threadId",
        "conversation_id",
        "conversationId",
    ):
        v = payload.get(key)
        if isinstance(v, str) and v.strip():
            return v.strip().replace("\t", " ")[:80]
    # transcript_path → basename without .jsonl
    for key in ("transcript_path", "transcriptPath", "rollout_path", "session_file"):
        v = payload.get(key)
        if isinstance(v, str) and v.strip():
            name = Path(v).name
            if name.endswith(".jsonl"):
                name = name[: -len(".jsonl")]
            return name[:80]
    return ""


def cwd_from_json(payload: dict) -> str:
    for key in ("cwd", "workdir", "working_directory", "workspace_root", "directory"):
        v = payload.get(key)
        if isinstance(v, str) and v.strip().startswith("/"):
            return v.strip().replace("\t", " ")[:240]
    return ""


# ---------------------------------------------------------------------------
# Respond — remote permission answering (docs/plan-respond.md, protocol v1)
#
# Opt-in only: the hold path runs when <pulse_dir>/respond-secret.key exists
# and is non-empty. The hook writes the request (verbatim stdin bytes) under
# respond.d/requests/ and polls respond.d/verdicts/ for an HMAC-signed
# verdict ferried back by the user's own sync tooling. Everything fails open:
# no key, no id, bad verdict, timeout or any exception all end in silence and
# exit 0, leaving the vendor's own permission prompt in charge.
# ---------------------------------------------------------------------------

RESPOND_SECRET_NAME = "respond-secret.key"
# Generated by Pulse when "answer this Mac's agents" is switched on, and never
# carried anywhere. `respond.d/verdicts/` is exactly the directory a partner
# Mac's answers sync *into*, so a locally-decided verdict is signed rather than
# trusted: an unsigned file accepted there would let a compromised share inject
# an allow. This key cannot reach that share, so nothing arriving over it can
# carry the signature.
RESPOND_LOCAL_SECRET_NAME = "respond-local.key"
RESPOND_POLL_SECONDS = 0.25
RESPOND_DEFAULT_HOLD_SECONDS = 60
RESPOND_MIN_HOLD_SECONDS = 5
RESPOND_MAX_HOLD_SECONDS = 300
# Verdict timestamps come from another machine's clock. Tolerance is ±5 min,
# chosen in the direction that keeps a genuinely fresh verdict usable: a
# verdict counts as unexpired while now < expires_at_ms + 300000 (and as
# plausibly decided while decided_at_ms - 300000 <= now). The cost is that a
# verdict may outlive its stated expiry by up to 5 minutes against a
# fast-running local clock — bounded, and the exactly-once .used rename means
# even that verdict can only ever answer this one held request. The
# alternative (now < expires_at_ms - 300000) would silently reject every
# verdict from a Mac whose clock runs a few minutes behind, which fails the
# user constantly to defend against a replay the single-use rename already
# prevents.
RESPOND_CLOCK_SKEW_MS = 300_000
RESPOND_USED_TTL_MS = 3_600_000  # .used remnants older than 1 h are removed
RESPOND_REQUEST_GRACE_MS = 3_600_000  # requests linger 1 h past their expiry
RESPOND_DIR_MAX_FILES = 64


def _wall_ms() -> int:
    return int(time.time() * 1000)


def respond_secret_path() -> Path:
    return pulse_dir() / RESPOND_SECRET_NAME


def respond_local_secret_path() -> Path:
    return pulse_dir() / RESPOND_LOCAL_SECRET_NAME


def respond_requests_dir() -> Path:
    return pulse_dir() / "respond.d" / "requests"


def respond_verdicts_dir() -> Path:
    return pulse_dir() / "respond.d" / "verdicts"


def load_respond_key() -> bytes | None:
    """Shared secret, or None when Respond is not opted in.

    Key bytes are the file's raw bytes with trailing newlines trimmed, so
    `echo secret > respond-secret.key` and a no-newline write agree.
    """
    keys = load_respond_keys()
    return keys[0] if keys else None


def load_respond_keys() -> list[bytes]:
    """Every key this machine holds, shared first.

    Either proves a verdict was minted by someone holding a key that lives
    here; neither can be forged from a synced directory alone.
    """
    keys: list[bytes] = []
    for path in (respond_secret_path(), respond_local_secret_path()):
        try:
            data = path.read_bytes()
        except OSError:
            continue
        key = data.rstrip(b"\r\n")
        if key:
            keys.append(key)
    return keys


def respond_host() -> str:
    """Machine label — PULSE_HOST override, else hostname, normalized.

    Same rules as the attention-protocol host column: separators that would
    break file names or TSV become '-', a trailing '.local' is dropped, and
    the label is capped at 32 chars.
    """
    raw = os.environ.get("PULSE_HOST") or ""
    if not raw.strip():
        try:
            raw = socket.gethostname() or ""
        except OSError:
            raw = ""
    for ch in ("|", "/", "\t", "\n", "\r"):
        raw = raw.replace(ch, "-")
    raw = raw.strip()
    if raw.endswith(".local"):
        raw = raw[: -len(".local")]
    return raw[:32]


def sanitize_request_id(request_id: str) -> str:
    """File-name form of a vendor request id: [A-Za-z0-9._-] only, ≤120."""
    return re.sub(r"[^A-Za-z0-9._-]", "_", request_id or "")[:120]


def max_hold_seconds() -> int:
    raw = (os.environ.get("PULSE_RESPOND_MAX_HOLD_SECONDS") or "").strip()
    try:
        value = int(float(raw))
    except ValueError:
        value = RESPOND_DEFAULT_HOLD_SECONDS
    return max(RESPOND_MIN_HOLD_SECONDS, min(RESPOND_MAX_HOLD_SECONDS, value))


def is_permission_request(payload: dict, kind: str) -> bool:
    event = payload.get("hook_event_name") or payload.get("hookEventName") or ""
    if event == "PermissionRequest":
        return True
    return normalize_kind(kind) == "permission" and "tool_input" in payload


def canonical_verdict_message(
    request_id: str,
    digest: str,
    agent: str,
    host: str,
    allow: bool,
    decided_at_ms: int,
    expires_at_ms: int,
) -> bytes:
    """Protocol-v1 canonical string the verdict HMAC is computed over.

    Frozen with the Swift side — do not reorder or reformat.
    """
    return (
        "v1\n"
        + request_id
        + "\n"
        + digest
        + "\n"
        + agent
        + "\n"
        + host
        + "\n"
        + ("allow" if allow else "deny")
        + "\n"
        + str(decided_at_ms)
        + "\n"
        + str(expires_at_ms)
    ).encode("utf-8")


def verify_verdict(
    verdict: object,
    key_bytes: bytes | list[bytes],
    request_id: str,
    digest: str,
    agent: str,
    host: str,
    now_ms: int,
) -> bool:
    """All bindings must hold; any one alone is replayable.

    request_id + digest bind the verdict to this exact request and its exact
    content; agent + host stop a verdict synced to the wrong machine (or a
    colliding vendor id) from answering; the timestamps bound its life; the
    HMAC proves it came from someone holding the shared secret.
    """
    if not isinstance(verdict, dict):
        return False
    if verdict.get("v") != 1:
        return False
    if verdict.get("request_id") != request_id:
        return False
    if verdict.get("digest") != digest:
        return False
    if verdict.get("agent") != agent:
        return False
    if verdict.get("host") != host:
        return False
    allow = verdict.get("allow")
    if not isinstance(allow, bool):
        return False
    decided = verdict.get("decided_at_ms")
    expires = verdict.get("expires_at_ms")
    if not isinstance(decided, int) or isinstance(decided, bool):
        return False
    if not isinstance(expires, int) or isinstance(expires, bool):
        return False
    # Clock-skew tolerance: see RESPOND_CLOCK_SKEW_MS for why the window
    # leans toward accepting rather than rejecting at the ±5 min boundary.
    if now_ms >= expires + RESPOND_CLOCK_SKEW_MS:
        return False
    if decided - RESPOND_CLOCK_SKEW_MS > now_ms:
        return False
    provided = verdict.get("hmac")
    if not isinstance(provided, str):
        return False
    message = canonical_verdict_message(
        request_id, digest, agent, host, allow, decided, expires
    )
    candidates = key_bytes if isinstance(key_bytes, list) else [key_bytes]
    given = provided.strip().lower()
    ok = False
    for key in candidates:
        expected = hmac.new(key, message, hashlib.sha256).hexdigest()
        # No early exit: comparing every candidate keeps the work independent
        # of which key matched.
        if hmac.compare_digest(expected, given):
            ok = True
    return ok


def hold_for_verdict(
    verdict_path: Path,
    key_bytes: bytes | list[bytes],
    request_id: str,
    digest: str,
    agent: str,
    host: str,
    truncated: bool,
    deadline_ms: int,
    clock_ms=None,
    sleep=time.sleep,
    poll_seconds: float = RESPOND_POLL_SECONDS,
) -> dict | None:
    """Poll for a valid verdict until deadline. Returns the verdict or None.

    Exactly-once: a verdict file is claimed by renaming it to *.used first;
    only a successful rename may be read and acted on. A rename that fails
    (file absent, or another process claimed it) counts as no verdict. A
    claimed verdict that fails verification stays consumed — the loop keeps
    waiting for a fresh file rather than re-reading a bad one.
    """
    if clock_ms is None:
        clock_ms = _wall_ms
    used_path = verdict_path.with_name(verdict_path.name + ".used")
    while clock_ms() < deadline_ms:
        claimed = False
        try:
            os.rename(verdict_path, used_path)
            claimed = True
        except OSError:
            claimed = False
        if claimed:
            verdict: object = None
            try:
                verdict = json.loads(used_path.read_text(encoding="utf-8"))
            except (OSError, ValueError, UnicodeDecodeError):
                verdict = None
            if isinstance(verdict, dict) and verify_verdict(
                verdict, key_bytes, request_id, digest, agent, host, clock_ms()
            ):
                # An allow must never answer a request whose full content was
                # not captured. Deny stays available — refusing something you
                # have not fully read is the safe direction.
                if not (verdict["allow"] and truncated):
                    return verdict
        sleep(poll_seconds)
    return None


def _write_private_json(path: Path, record: dict) -> None:
    """0600 from the first byte, atomically renamed into place."""
    tmp = path.with_name("." + path.name + "." + str(os.getpid()) + ".tmp")
    data = json.dumps(record, separators=(",", ":"), sort_keys=True).encode("utf-8")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)


def _prune_oldest(directory: Path, keep: int) -> None:
    try:
        entries = [p for p in directory.iterdir() if p.is_file()]
    except OSError:
        return
    if len(entries) <= keep:
        return

    def mtime(p: Path) -> float:
        try:
            return p.stat().st_mtime
        except OSError:
            return 0.0

    entries.sort(key=mtime)
    for stale in entries[: len(entries) - keep]:
        try:
            stale.unlink()
        except OSError:
            pass


def cleanup_respond_dirs(requests_dir: Path, verdicts_dir: Path, now_ms: int) -> None:
    """Housekeeping done alongside each new request write.

    Requests older than their own expiry + 1 h go; .used verdict remnants
    older than 1 h go; each directory is capped at 64 files, oldest first.
    """
    try:
        requests = list(requests_dir.glob("*.json"))
    except OSError:
        requests = []
    for path in requests:
        expires: object = None
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                expires = data.get("expires_at_ms")
        except (OSError, ValueError, UnicodeDecodeError):
            pass
        try:
            if isinstance(expires, int) and not isinstance(expires, bool):
                if now_ms > expires + RESPOND_REQUEST_GRACE_MS:
                    path.unlink()
            elif now_ms - int(path.stat().st_mtime * 1000) > RESPOND_REQUEST_GRACE_MS:
                path.unlink()
        except OSError:
            pass
    try:
        used = list(verdicts_dir.glob("*.used"))
    except OSError:
        used = []
    for path in used:
        try:
            if now_ms - int(path.stat().st_mtime * 1000) > RESPOND_USED_TTL_MS:
                path.unlink()
        except OSError:
            pass
    _prune_oldest(requests_dir, RESPOND_DIR_MAX_FILES)
    _prune_oldest(verdicts_dir, RESPOND_DIR_MAX_FILES)


def respond_decision_json(
    agent: str,
    payload: dict,
    raw_bytes: bytes,
    kind: str,
    clock_ms=None,
    sleep=time.sleep,
) -> str | None:
    """Full hold path. Returns the stdout decision JSON, or None for silence.

    None on every path that is not a verified, in-time verdict: not a
    PermissionRequest, no opt-in key, no vendor request id, empty stdin,
    timeout. Callers print the result verbatim when it is not None.
    """
    if not is_permission_request(payload, kind):
        return None
    if not raw_bytes:
        # Without the verbatim request bytes there is nothing the user could
        # actually review, so there is nothing Pulse may hold for.
        return None
    keys = load_respond_keys()
    if not keys:
        return None
    request_id = str(payload.get("tool_use_id") or "").strip()
    if not request_id:
        # No stable id → a verdict could not be bound to this request.
        return None
    if clock_ms is None:
        clock_ms = _wall_ms
    host = respond_host()
    digest = hashlib.sha256(raw_bytes).hexdigest()
    truncated = False  # payload_b64 carries the verbatim stdin; nothing is cut
    now = clock_ms()
    deadline = now + max_hold_seconds() * 1000
    requests_dir = respond_requests_dir()
    verdicts_dir = respond_verdicts_dir()
    for directory in (requests_dir.parent, requests_dir, verdicts_dir):
        directory.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(directory, 0o700)
        except OSError:
            pass
    name = sanitize_request_id(request_id)
    record = {
        "v": 1,
        "request_id": request_id,
        "agent": agent,
        "host": host,
        "session": session_from_json(payload),
        "cwd": cwd_from_json(payload),
        "tool_name": str(payload.get("tool_name") or ""),
        "raised_at_ms": now,
        "expires_at_ms": deadline,
        "payload_b64": base64.b64encode(raw_bytes).decode("ascii"),
        "digest": digest,
        "truncated": truncated,
    }
    _write_private_json(requests_dir / (name + ".json"), record)
    cleanup_respond_dirs(requests_dir, verdicts_dir, now)
    verdict = hold_for_verdict(
        verdicts_dir / (name + ".json"),
        keys,
        request_id,
        digest,
        agent,
        host,
        truncated,
        deadline,
        clock_ms=clock_ms,
        sleep=sleep,
    )
    if verdict is None:
        return None
    decision = {
        "behavior": "allow" if verdict["allow"] else "deny",
        "message": "Answered via Pulse from " + host,
    }
    return json.dumps(
        {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}
    )


def open_private(path):
    """attention.tsv, read/write, 0600 from creation.

    Every line here is either a command an agent asked to run or the directory
    it asked from, so it belongs to this user alone — the same rule the respond
    spool beside it has always followed. A creation mode only covers a file
    that does not exist yet, so an install that already has an attention.tsv
    is brought down through the descriptor we already hold. A file owned by
    somebody else is left exactly as it is.
    """
    fd = os.open(str(path), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        info = os.fstat(fd)
        if info.st_uid == os.getuid() and (info.st_mode & 0o777) != 0o600:
            os.fchmod(fd, 0o600)
    except OSError:
        pass
    return os.fdopen(fd, "r+", encoding="utf-8")


def append_event(agent: str, kind: str, message: str, session: str = "", cwd: str = "") -> None:
    path = attention_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    ts = int(time.time() * 1000)
    # agent \t kind \t ms \t message \t session \t cwd
    line = "\t".join(
        (
            clean_field(agent, 48),
            clean_field(kind, 64),
            str(ts),
            clean_field(message, 200),
            clean_field(session, 80),
            clean_field(cwd, 240),
        )
    )
    with open_private(path) as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        try:
            f.seek(0)
            existing = f.read()
            lines = [ln for ln in existing.splitlines() if ln.strip() and not ln.startswith("#")]
            lines.append(line)
            lines = lines[-MAX_LINES:]
            f.seek(0)
            f.truncate()
            f.write(HEADER)
            f.write("\n".join(lines) + "\n")
            f.flush()
            os.fsync(f.fileno())
        finally:
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)


def main(argv: list[str]) -> int:
    agent = (argv[1] if len(argv) > 1 else "claude").lower().strip()
    kind_arg = argv[2] if len(argv) > 2 else ""
    payload: dict = {}
    raw_bytes = b""
    try:
        if not sys.stdin.isatty():
            # Bytes, not text: Respond signs and forwards the verbatim stdin,
            # so the digest must be over exactly what the vendor wrote.
            raw_bytes = sys.stdin.buffer.read()
    except (OSError, ValueError, AttributeError):
        raw_bytes = b""
    raw = raw_bytes.decode("utf-8", "replace")
    if raw.strip():
        try:
            parsed = json.loads(raw)
            payload = parsed if isinstance(parsed, dict) else {"message": raw.strip()}
        except json.JSONDecodeError:
            payload = {"message": raw.strip()}

    if not payload and len(argv) > 2:
        try:
            payload = json.loads(argv[-1])
            if not kind_arg or kind_arg.startswith("{"):
                kind_arg = ""
        except (json.JSONDecodeError, ValueError):
            pass

    # Codex sometimes nests event
    if isinstance(payload.get("msg"), dict) and not payload.get("type"):
        payload = {**payload, **payload["msg"]}

    kind = normalize_kind(kind_arg or parse_kind_from_json(payload) or "waiting")
    if not accepts_write(kind):
        return 0
    msg = message_from_json(payload)
    session = session_from_json(payload)
    cwd = cwd_from_json(payload)
    try:
        append_event(agent, kind, msg, session, cwd)
    except OSError:
        pass
    # Respond hold (opt-in, docs/plan-respond.md). Runs after the attention
    # write so the lamp is already lit while the agent waits. Fail-open: any
    # problem whatsoever ends in silence + exit 0 so the vendor agent falls
    # back to its own prompt instead of blocking on Pulse.
    try:
        decision = respond_decision_json(agent, payload, raw_bytes, kind)
        if decision:
            sys.stdout.write(decision + "\n")
            sys.stdout.flush()
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
