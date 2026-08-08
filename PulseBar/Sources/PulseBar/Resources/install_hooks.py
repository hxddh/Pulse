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
    """Prefer native pulse-hook launcher; fall back to python3 pulse_hook.py."""
    d = pulse_dir()
    native = d / "pulse-hook"
    if native.exists() and os.access(native, os.X_OK):
        quoted = f'"{native}"' if " " in str(native) else str(native)
        if kind:
            return f"{quoted} {agent} {kind}"
        return f"{quoted} {agent}"
    py = sys.executable or "python3"
    hook = d / "pulse_hook.py"
    if kind:
        return f'{py} "{hook}" {agent} {kind}'
    return f'{py} "{hook}" {agent}'


def ensure_pulse_hook_script() -> None:
    # Preferred path is native pulse-hook (written by Pulse). Legacy python
    # remains for hosts that have not opened a 0.61+ build yet.
    d = pulse_dir()
    d.mkdir(parents=True, exist_ok=True)
    native = d / "pulse-hook"
    hook = d / "pulse_hook.py"
    if native.exists() and os.access(native, os.X_OK):
        return
    if not hook.exists():
        print(
            "missing pulse-hook / pulse_hook.py — open Pulse once so it can install assets",
            file=sys.stderr,
        )
        sys.exit(1)
    hook.chmod(hook.stat().st_mode | 0o111)


def install_claude() -> str:
    settings = Path.home() / ".claude" / "settings.json"
    settings.parent.mkdir(parents=True, exist_ok=True)
    data: dict = {}
    if settings.exists():
        raw = settings.read_text(encoding="utf-8")
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            # Never silently replace a config we could not read — that used to
            # wipe every unrelated Claude Code setting the user had.
            raise SystemExit(
                f"refusing to rewrite {settings}: not valid JSON ({exc}). "
                "Fix or move the file, then install hooks again."
            )
        if not isinstance(data, dict):
            raise SystemExit(f"refusing to rewrite {settings}: top level is not a JSON object.")
        # Keep one restore point next to the original before we touch it.
        backup = settings.with_suffix(".json.pulse-backup")
        if not backup.exists():
            backup.write_text(raw, encoding="utf-8")
    hooks = data.setdefault("hooks", {})
    notify_cmd = hook_cmd("claude")
    stop_cmd = hook_cmd("claude", "stop")
    sub_start = hook_cmd("claude", "subagent_start")
    sub_stop = hook_cmd("claude", "subagent_stop")
    permission_cmd = hook_cmd("claude", "permission")

    def ensure_event(event: str, command: str, matcher: str | None = None, marker: str | None = None) -> None:
        entries = hooks.setdefault(event, [])
        blob = json.dumps(entries)
        token = marker or "pulse-hook"
        if token in blob or "pulse-hook" in blob or "pulse_hook.py" in blob:
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


def root_table_end(text: str) -> int:
    """Offset where Codex's root table ends (start of the first `[section]`).

    `notify` is a root-level key. Appending it at EOF put it inside whatever
    table happened to be last (`[mcp_servers.x]`, a profile, …), where Codex
    never reads it — the hook looked installed but never fired.
    """
    m = re.search(r"(?m)^\s*\[", text)
    return len(text) if m is None else m.start()


def install_codex() -> str:
    cfg = Path.home() / ".codex" / "config.toml"
    cfg.parent.mkdir(parents=True, exist_ok=True)
    text = cfg.read_text(encoding="utf-8") if cfg.exists() else ""
    py = sys.executable or "python3"
    hook = pulse_dir() / "pulse_hook.py"
    line = f'notify = ["{py}", "{hook}", "codex"]\n'

    end = root_table_end(text)
    root, rest = text[:end], text[end:]

    if re.search(r"(?m)^\s*notify\s*=.*pulse_hook\.py", root):
        return str(cfg) + " (already present)"

    if re.search(r"(?m)^\s*notify\s*=", root):
        root = re.sub(r"(?m)^\s*notify\s*=.*$", line.rstrip(), root, count=1)
        if not root.endswith("\n"):
            root += "\n"
    else:
        if root and not root.endswith("\n"):
            root += "\n"
        root += "\n# Pulse v2 attention hooks\n" + line

    if rest:
        if not root.endswith("\n"):
            root += "\n"
        if not root.endswith("\n\n"):
            root += "\n"
    cfg.write_text(root + rest, encoding="utf-8")
    return str(cfg)


def uninstall_claude() -> str:
    """Strip Pulse hook entries, leaving every other setting untouched."""
    settings = Path.home() / ".claude" / "settings.json"
    removed = 0
    for target in (settings, settings.with_name("settings.local.json")):
        if not target.exists():
            continue
        raw = target.read_text(encoding="utf-8")
        if "pulse_hook.py" not in raw:
            continue
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"refusing to rewrite {target}: not valid JSON ({exc}).")
        if not isinstance(data, dict):
            continue
        hooks = data.get("hooks")
        if not isinstance(hooks, dict):
            continue
        for event in list(hooks):
            entries = hooks.get(event)
            if not isinstance(entries, list):
                continue
            kept = [e for e in entries if "pulse_hook.py" not in json.dumps(e)]
            removed += len(entries) - len(kept)
            if kept:
                hooks[event] = kept
            else:
                hooks.pop(event, None)
        if not hooks:
            data.pop("hooks", None)
        target.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return f"{settings} ({removed} hook entries removed)"


def uninstall_codex() -> str:
    cfg = Path.home() / ".codex" / "config.toml"
    if not cfg.exists():
        return f"{cfg} (absent)"
    text = cfg.read_text(encoding="utf-8")
    if "pulse_hook.py" not in text:
        return f"{cfg} (nothing to remove)"
    kept: list[str] = []
    for ln in text.splitlines():
        if "pulse_hook.py" in ln or ln.strip() == "# Pulse v2 attention hooks":
            continue
        # Don't leave a stack of blank lines where our block used to be.
        if not ln.strip() and kept and not kept[-1].strip():
            continue
        kept.append(ln)
    cfg.write_text("\n".join(kept).rstrip("\n") + "\n", encoding="utf-8")
    return str(cfg)


def main(argv: list[str] | None = None) -> int:
    args = list(argv if argv is not None else sys.argv[1:])
    if "--uninstall" in args:
        paths = []
        for label, fn in (("claude", uninstall_claude), ("codex", uninstall_codex)):
            try:
                paths.append(f"{label}: " + fn())
            except OSError as e:
                paths.append(f"{label}: failed ({e})")
        print("removed hooks:\n" + "\n".join(paths))
        return 0

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
