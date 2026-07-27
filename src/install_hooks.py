#!/usr/bin/env python3
"""Install Pulse v2 hooks into Claude Code + Codex configs (best-effort merge)."""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path


def pulse_dir() -> Path:
    override = os.environ.get("PULSE_HOME")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "Pulse"


def hook_cmd(agent: str, kind: str = "") -> str:
    py = sys.executable or "python3"
    hook = pulse_dir() / "pulse_hook.py"
    # Quote path for spaces in Application Support
    if kind:
        return f'{py} "{hook}" {agent} {kind}'
    return f'{py} "{hook}" {agent}'


def ensure_pulse_hook_script() -> None:
    # install_hooks is invoked after Pulse wrote pulse_hook.py next to it
    d = pulse_dir()
    d.mkdir(parents=True, exist_ok=True)
    hook = d / "pulse_hook.py"
    if not hook.exists():
        print("missing pulse_hook.py — open Pulse once so it can install assets", file=sys.stderr)
        sys.exit(1)
    hook.chmod(hook.stat().st_mode | 0o111)


def install_claude() -> str:
    settings = Path.home() / ".claude" / "settings.json"
    settings.parent.mkdir(parents=True, exist_ok=True)
    data: dict = {}
    if settings.exists():
        try:
            data = json.loads(settings.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            data = {}
    hooks = data.setdefault("hooks", {})
    notify_cmd = hook_cmd("claude")
    stop_cmd = hook_cmd("claude", "stop")
    sub_start = hook_cmd("claude", "subagent_start")
    sub_stop = hook_cmd("claude", "subagent_stop")
    permission_cmd = hook_cmd("claude", "permission")

    def ensure_event(event: str, command: str, matcher: str | None = None, marker: str | None = None) -> None:
        entries = hooks.setdefault(event, [])
        blob = json.dumps(entries)
        token = marker or "pulse_hook.py"
        if token in blob:
            return
        entry: dict = {
            "hooks": [{"type": "command", "command": command, "timeout": 5}],
        }
        if matcher:
            entry["matcher"] = matcher
        entries.append(entry)

    ensure_event("Notification", notify_cmd, "permission_prompt|idle_prompt|agent_needs_input")
    ensure_event("Stop", stop_cmd, marker="claude stop")
    ensure_event("SubagentStart", sub_start, marker="subagent_start")
    ensure_event("SubagentStop", sub_stop, marker="subagent_stop")
    ensure_event("PermissionRequest", permission_cmd, marker=" claude permission")
    settings.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return str(settings)


def install_codex() -> str:
    cfg = Path.home() / ".codex" / "config.toml"
    cfg.parent.mkdir(parents=True, exist_ok=True)
    text = cfg.read_text(encoding="utf-8") if cfg.exists() else ""
    py = sys.executable or "python3"
    hook = pulse_dir() / "pulse_hook.py"
    line = f'notify = ["{py}", "{hook}", "codex"]\n'
    if "pulse_hook.py" in text and "notify" in text:
        return str(cfg) + " (already present)"
    # Replace existing notify = ... line or append
    if re.search(r"(?m)^\s*notify\s*=", text):
        text = re.sub(r"(?m)^\s*notify\s*=.*$", line.rstrip(), text, count=1)
        if not text.endswith("\n"):
            text += "\n"
    else:
        if text and not text.endswith("\n"):
            text += "\n"
        text += "\n# Pulse v2 attention hooks\n" + line
    cfg.write_text(text, encoding="utf-8")
    return str(cfg)


def main() -> int:
    ensure_pulse_hook_script()
    paths = []
    try:
        paths.append("claude: " + install_claude())
    except OSError as e:
        paths.append(f"claude: failed ({e})")
    try:
        paths.append("codex: " + install_codex())
    except OSError as e:
        paths.append(f"codex: failed ({e})")
    print("installed hooks:\n" + "\n".join(paths))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
