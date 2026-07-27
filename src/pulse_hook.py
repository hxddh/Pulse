#!/usr/bin/env python3
"""Pulse hook receiver — Claude Code / Codex → attention.tsv

Usage:
  pulse_hook.py <agent> [kind]          # kind from argv or stdin JSON
  echo '{...}' | pulse_hook.py claude

TSV columns (v3, backward compatible):
  agent \\t kind \\t ms \\t message \\t session \\t cwd

Exit 0 always so agent hooks never block the agent.
"""
from __future__ import annotations

import fcntl
import json
import os
import sys
import time
from pathlib import Path

MAX_LINES = 80


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
        "agent_needs_input": "idle_prompt",
        "needs_input": "idle_prompt",
    }
    if low in mapping:
        return mapping[low]
    if "approval" in low and "response" not in low and "decision" not in low:
        return "permission"
    if "user_input" in low and "response" not in low:
        return "idle_prompt"
    return k or "waiting"


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
    return ""


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


def append_event(agent: str, kind: str, message: str, session: str = "", cwd: str = "") -> None:
    path = attention_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    ts = int(time.time() * 1000)
    # agent \t kind \t ms \t message \t session \t cwd
    line = f"{agent}\t{kind}\t{ts}\t{message}\t{session}\t{cwd}"
    with path.open("a+", encoding="utf-8") as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        try:
            f.seek(0)
            existing = f.read()
            lines = [ln for ln in existing.splitlines() if ln.strip() and not ln.startswith("#")]
            lines.append(line)
            lines = lines[-MAX_LINES:]
            f.seek(0)
            f.truncate()
            f.write("# Pulse attention log (agent\\tkind\\tms\\tmessage\\tsession\\tcwd)\n")
            f.write("\n".join(lines) + "\n")
            f.flush()
            os.fsync(f.fileno())
        finally:
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)


def main(argv: list[str]) -> int:
    agent = (argv[1] if len(argv) > 1 else "claude").lower().strip()
    kind_arg = argv[2] if len(argv) > 2 else ""
    payload: dict = {}
    try:
        if not sys.stdin.isatty():
            raw = sys.stdin.read()
            if raw.strip():
                try:
                    payload = json.loads(raw)
                except json.JSONDecodeError:
                    payload = {"message": raw.strip()}
    except OSError:
        pass

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
    msg = message_from_json(payload)
    session = session_from_json(payload)
    cwd = cwd_from_json(payload)
    try:
        append_event(agent, kind, msg, session, cwd)
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
