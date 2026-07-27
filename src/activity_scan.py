#!/usr/bin/env python3
"""Best-effort local harvest of agent task/tokens/tools/skills for Pulse.
Prints one TSV line per session/agent:
  agent_id<TAB>task<TAB>tokens_in<TAB>tokens_out<TAB>last_tool<TAB>last_skill<TAB>project<TAB>cwd
"""
from __future__ import annotations

import glob
import json
import os
import re
import sys
import time
from pathlib import Path

HOME = Path.home()


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
        im = re.search(r'"input_tokens"\s*:\s*(\d+)', block)
        om = re.search(r'"output_tokens"\s*:\s*(\d+)', block)
        cm = re.search(r'"cache_read_input_tokens"\s*:\s*(\d+)', block)
        if im:
            tin = int(im.group(1))
            if cm:
                tin += int(cm.group(1))
        if om:
            tout = int(om.group(1))
    return tin, tout


def sum_int_fields(text: str, key: str) -> int:
    total = 0
    for m in re.finditer(rf'"{re.escape(key)}"\s*:\s*(\d+)', text):
        total += int(m.group(1))
    return total


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


def last_skill_name(text: str) -> str:
    m = re.findall(r'"name"\s*:\s*"Skill"[\s\S]{0,300}?"skill"\s*:\s*"([^"]+)"', text)
    if m:
        return m[-1]
    m = re.findall(r'"name"\s*:\s*"Skill"[\s\S]{0,300}?"name"\s*:\s*"([^"]+)"', text)
    if m:
        return m[-1]
    m = re.findall(r"skills?/([A-Za-z0-9_./-]+)", text)
    if m:
        return m[-1].split("/")[-1][:48]
    return ""


def session_title_from_text(text: str) -> str:
    for key in ("aiTitle", "customTitle", "title", "summary", "lastPrompt"):
        v = extract_field(text, key)
        if v and len(v.strip()) >= 3:
            return v.strip().replace("\n", " ")[:160]
    return ""


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
    """Up to 2 recent Claude sessions (distinct session files / projects).

    Tuple: task, tin, tout, tool, skill, project, cwd, mtime_ms, sub_run, sub_total
    """
    paths = glob.glob(str(HOME / ".claude" / "projects" / "*" / "*.jsonl"))
    files = newest(paths, 8)
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
        tool = last_tool_name(text)
        skill = last_skill_name(text)
        if checklist and not skill:
            skill = checklist
        elif checklist and skill and "tasks " not in skill:
            skill = f"{skill} · {checklist}"
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
                )
            )
        if len(out) >= 2:
            break
    return out

def codex_activities() -> list[tuple[str, int, int, str, str, str, str]]:
    paths = glob.glob(str(HOME / ".codex" / "sessions" / "*" / "*" / "*" / "rollout-*.jsonl"))
    files = newest(paths, 4)
    out: list[tuple[str, int, int, str, str, str, str]] = []
    seen: set[str] = set()
    for f in files:
        text = tail_bytes(f, 600_000)
        task = session_title_from_text(text)
        if not task:
            msgs = re.findall(r'"last_agent_message"\s*:\s*"((?:\\.|[^"\\])*)"', text)
            if msgs:
                task = decode_json_string(msgs[-1]).replace("\n", " ")[:160]
        tin = tout = 0
        for m in re.finditer(
            r'"type"\s*:\s*"token_count"[\s\S]{0,400}?"total_token_usage"\s*:\s*\{([^}]+)\}',
            text,
        ):
            block = m.group(1)
            im = re.search(r'"input_tokens"\s*:\s*(\d+)', block)
            om = re.search(r'"output_tokens"\s*:\s*(\d+)', block)
            if im:
                tin = int(im.group(1))
            if om:
                tout = int(om.group(1))
        tool = last_tool_name(text)
        skill = last_skill_name(text)
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
                )
            )
        if len(out) >= 2:
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
    """Active Cursor Agent sessions from local DB — not Cursor.app process count.

    Sources:
      - ItemTable cursor/glass.selectedAgent
      - composerHeaders (name, pending, recency, workspaceId)
    Active if: selected, or hasBlockingPendingActions, or updated within 30 minutes.
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
        active_window_ms = 30 * 60 * 1000
        selected = ""
        row = con.execute(
            "SELECT value FROM ItemTable WHERE key='cursor/glass.selectedAgent'"
        ).fetchone()
        if row and row[0]:
            selected = str(row[0]).strip().strip('"')

        rows = con.execute(
            """
            SELECT composerId, workspaceId, lastUpdatedAt, value
            FROM composerHeaders
            WHERE IFNULL(isArchived, 0) = 0 AND IFNULL(isSubagent, 0) = 0
            ORDER BY lastUpdatedAt DESC
            LIMIT 24
            """
        ).fetchall()
        out: list[tuple[str, int, int, str, str, str, str]] = []
        seen: set[str] = set()
        for cid, ws_id, lu, val in rows:
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
            age_ok = bool(lu and (now_ms - int(lu)) <= active_window_ms)
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
            hm = int(lu)
            out.append((task, 0, 0, "", skill, project[:48], (cwd or "")[:240], hm, str(cid)))
            if len(out) >= 2:
                break
        return out
    except Exception:
        return []
    finally:
        try:
            con.close()
        except Exception:
            pass


def grok_activity() -> tuple:
    active = HOME / ".grok" / "active_sessions.json"
    task = ""
    if active.is_file():
        try:
            sessions = json.loads(active.read_text(encoding="utf-8"))
            if sessions:
                sid = sessions[0].get("session_id", "")
                cwd = sessions[0].get("cwd") or sessions[0].get("workspace") or sessions[0].get("path") or ""
                project = short_project(str(cwd)) if cwd else ""
                for d in (HOME / ".grok" / "sessions").rglob(sid):
                    if d.is_dir():
                        if not project:
                            project = short_project(d.name) or short_project(d.parent.name)
                        plan = d / "plan.md"
                        goal = d / "goal" / "plan.md"
                        summary = d / "summary.json"
                        if plan.is_file():
                            task = plan.read_text(encoding="utf-8", errors="replace").strip().splitlines()[0][:160]
                        elif goal.is_file():
                            task = goal.read_text(encoding="utf-8", errors="replace").strip().splitlines()[0][:160]
                        elif summary.is_file():
                            try:
                                obj = json.loads(summary.read_text(encoding="utf-8", errors="replace"))
                                task = str(obj.get("title") or obj.get("summary") or "")[:160]
                            except Exception:
                                pass
                        hist = d / "chat_history.jsonl"
                        tools = skill = ""
                        if hist.is_file():
                            htext = tail_bytes(hist, 200_000)
                            if not task:
                                ms = re.findall(r'"content"\s*:\s*"((?:\\.|[^"\\]){10,200})"', htext)
                                if ms:
                                    task = decode_json_string(ms[-1])[:160]
                            tools = last_tool_name(htext)
                            skill = last_skill_name(htext)
                            if text_looks_pending(htext):
                                skill = "pending"
                        return task, 0, 0, tools, skill, project[:48], str(cwd)[:240], file_mtime_ms(hist if hist.is_file() else active), str(sid)[:80]
        except Exception:
            pass
    # Fall through empty with no mtime
    return "", 0, 0, "", "", "", "", 0, ""


def pi_activity() -> tuple:
    paths = glob.glob(str(HOME / ".pi" / "agent" / "sessions" / "*" / "*.jsonl"))
    files = newest(paths, 1)
    if not files:
        return "", 0, 0, "", "", "", "", 0, ""
    f = files[0]
    text = tail_bytes(f)
    task = session_title_from_text(text) or extract_field(text, "text") or extract_field(text, "content") or ""
    tin = sum_int_fields(text, "input_tokens")
    tout = sum_int_fields(text, "output_tokens")
    tool = last_tool_name(text)
    skill = last_skill_name(text)
    if text_looks_pending(text):
        skill = "pending"
    cwd = extract_field(text, "cwd") or extract_field(text, "workingDirectory") or ""
    project = short_project(cwd) if cwd else short_project(f.parent.name)
    sid = f.stem
    return task[:160], tin, tout, tool[:48], skill[:48], project[:48], (cwd or "")[:240], file_mtime_ms(f), sid[:80]


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
            project = short_project(cwd) if cwd else short_project(f.stem)
            key = f"{project}|{title[:40]}"
            if key in seen:
                continue
            seen.add(key)
            skill = "pending" if (json_looks_pending(obj) or text_looks_pending(json.dumps(obj)[-8000:])) else ""
            out.append((title[:160] or "Amp thread", 0, 0, "", skill, project[:48], (cwd or "")[:240], file_mtime_ms(f)))
            if len(out) >= 2:
                return out

    # Modern Amp: ~/.local/share/amp/session.json + history.jsonl (no local threads/)
    hist = share / "history.jsonl"
    session = share / "session.json"
    title = cwd = sid = ""
    ms = 0
    if hist.is_file():
        text = tail_bytes(hist, 80_000)
        lines = [ln for ln in text.splitlines() if ln.strip()]
        if lines:
            try:
                obj = json.loads(lines[-1])
                if isinstance(obj, dict):
                    title = str(obj.get("prompt") or obj.get("text") or obj.get("content") or "")[:160]
                    cwd = str(obj.get("cwd") or obj.get("workdir") or "")
            except Exception:
                pass
        ms = file_mtime_ms(hist)
    if session.is_file():
        try:
            sobj = json.loads(session.read_text(encoding="utf-8", errors="replace"))
            if isinstance(sobj, dict):
                sid = str(sobj.get("lastThreadId") or "")[:80]
                # Prefer cwd from last terminal binding if history lacked it
                by_tty = sobj.get("lastThreadByTerminal")
                if isinstance(by_tty, dict) and not cwd:
                    # no cwd in session; keep history cwd
                    pass
                ms = max(ms, file_mtime_ms(session))
                if not title:
                    mode = str(sobj.get("agentMode") or "")
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
        row = (title[:160] or "Amp session", 0, 0, "", skill, project[:48], (cwd or "")[:240], ms or int(time.time() * 1000))
        # Prefer 9-tuple with session when available
        if sid:
            out.append((*row, sid))
        else:
            out.append(row)
    return out[:2]


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
    # Cap walk cost: newest() already sorts by mtime
    if len(paths) > 200:
        paths = paths[:200]
    return newest(paths, limit)


def task_from_json_obj(obj: dict) -> tuple[str, str, str]:
    """Return (task, cwd, session)."""
    task = ""
    for k in ("task", "title", "name", "summary", "prompt", "query", "lastMessage", "text"):
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


def harvest_extension_storage(agent: str, *needles: str, limit: int = 2) -> list[tuple]:
    """Generic VS Code/Cursor globalStorage harvest → up to `limit` rows."""
    out: list[tuple] = []
    for store in vscode_global_storage_dirs(*needles):
        files = recent_files_under(store, ("*.json", "*.jsonl"), limit=10)
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
            task = cwd = sid = ""
            if isinstance(obj, dict):
                task, cwd, sid = task_from_json_obj(obj)
                pending = json_looks_pending(obj)
            elif isinstance(obj, list) and obj:
                last = obj[-1] if isinstance(obj[-1], dict) else {}
                task, cwd, sid = task_from_json_obj(last) if isinstance(last, dict) else ("", "", "")
                pending = json_looks_pending(obj)
            else:
                pending = text_looks_pending(text)
            if not pending:
                pending = text_looks_pending(text)
            if not task:
                task = session_title_from_text(text) or f"{agent} session"
            project = short_project(cwd) if cwd else short_project(store.name)
            skill = "pending" if pending else ""
            if not (task or pending or cwd):
                continue
            out.append((task[:160], 0, 0, "", skill, project[:48], cwd[:240], file_mtime_ms(f), sid or f.stem[:80]))
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
        files.extend(recent_files_under(root, ("*.json", "*.jsonl"), limit=10))
    files = newest([str(f) for f in files], 8)
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
        out.append((task[:160], 0, 0, "", skill, project[:48], (cwd or "")[:240], file_mtime_ms(f), f.stem[:80]))
        if len(out) >= 2:
            break
    return out


def copilot_activities() -> list[tuple]:
    """GitHub Copilot CLI: ~/.copilot/session-state/<id>/events.jsonl + workspace.yaml."""
    home = Path(os.environ.get("COPILOT_HOME") or (HOME / ".copilot"))
    state = home / "session-state"
    out: list[tuple] = []
    if not state.is_dir():
        # Fallback legacy roots
        return home_dir_activities("copilot", [home, HOME / ".config" / "copilot"], limit=2)

    sessions = []
    try:
        for d in state.iterdir():
            if d.is_dir():
                sessions.append(d)
    except OSError:
        return out
    sessions.sort(key=lambda p: p.stat().st_mtime if p.exists() else 0, reverse=True)

    for sdir in sessions[:6]:
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
        out.append((title[:160], 0, 0, "", skill, project[:48], (cwd or "")[:240], mtime, sdir.name[:80]))
        if len(out) >= 2:
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
            files.extend(str(p) for p in recent_files_under(root, ("*.json", "*.jsonl", "*.md", "*.txt"), limit=10))
    for f in newest(files, 10):
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
        out.append((task[:160], 0, 0, "", skill, project[:48], (cwd or "")[:240], file_mtime_ms(Path(f)), Path(f).stem[:80]))
        if len(out) >= 2:
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
    for f in newest(files, 10):
        text = tail_bytes(Path(f), 120_000)
        low = text.lower()
        if not any(x in low for x in ("agent", "tool", "message", "thread", "assistant", "ask")):
            continue
        task = session_title_from_text(text) or extract_field(text, "title") or "Zed Agent"
        cwd = extract_field(text, "cwd") or extract_field(text, "project_path") or extract_field(text, "worktree") or ""
        project = short_project(cwd) if cwd else short_project(Path(f).stem)
        skill = "pending" if text_looks_pending(text) else ""
        out.append((task[:160], 0, 0, "", skill, project[:48], (cwd or "")[:240], file_mtime_ms(Path(f)), Path(f).stem[:80]))
        if len(out) >= 2:
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
            files.extend(str(p) for p in recent_files_under(root, ("*.json", "*.jsonl", "*.md"), limit=12))
    for f in newest(files, 10):
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
        out.append((task[:160], 0, 0, "", skill, project[:48], (cwd or "")[:240], file_mtime_ms(Path(f)), Path(f).stem[:80]))
        if len(out) >= 2:
            break
    return out


def antigravity_activities() -> list[tuple]:
    """Antigravity IDE/2.0 — B 尽力；Waiting 通常 none。"""
    out = harvest_extension_storage("antigravity", "antigravity", "google.antigravity", limit=2)
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
    if len(out) >= 2:
        return out
    more = home_dir_activities("antigravity", roots, limit=2 - len(out))
    # Prefer rows that look agent-ish
    filtered = []
    for row in more:
        blob = " ".join(str(x) for x in row).lower()
        if any(x in blob for x in ("agent", "chat", "thread", "task", "pending", "antigravity")):
            filtered.append(row)
    return (out + (filtered or more))[:2]


def roo_activities() -> list[tuple]:
    """Roo: deepen ask/approval like Cline."""
    out = harvest_extension_storage("roo", "roo-cline", "roo-code", "rooveterinary", "RooCode", limit=2)
    if len(out) >= 2 and any(r[4] == "pending" for r in out):
        return out
    for store in vscode_global_storage_dirs("roo-cline", "roo-code", "rooveterinary", "RooCode"):
        for f in recent_files_under(store, ("*.json", "*.jsonl"), limit=8):
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
            row = (task[:160], 0, 0, "", skill, project[:48], (cwd or "")[:240], file_mtime_ms(f), f.stem[:80])
            if pending:
                out = [row] + [r for r in out if (len(r) < 9 or r[8] != row[8])]
            elif not out:
                out.append(row)
            if len(out) >= 2:
                return out[:2]
    return out[:2]


def kilo_activities() -> list[tuple]:
    out = harvest_extension_storage("kilo", "kilocode", "kilo-code", "kilo.code", limit=2)
    if any(r[4] == "pending" for r in out):
        return out
    for store in vscode_global_storage_dirs("kilocode", "kilo-code", "kilo.code"):
        for f in recent_files_under(store, ("*.json", "*.jsonl"), limit=6):
            text = tail_bytes(f, 100_000)
            pending = text_looks_pending(text)
            task = session_title_from_text(text) or "Kilo session"
            cwd = extract_field(text, "cwd") or extract_field(text, "workspacePath") or ""
            project = short_project(cwd) if cwd else short_project(store.name)
            skill = "pending" if pending else ""
            if not (task or pending):
                continue
            out.append((task[:160], 0, 0, "", skill, project[:48], (cwd or "")[:240], file_mtime_ms(f), f.stem[:80]))
            if len(out) >= 2:
                return out[:2]
    return out[:2]


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
    out.extend(harvest_extension_storage("cascade", "codeium.cascade", "codeium", "windsurf", limit=2))
    files: list[str] = []
    for root in roots:
        if root.is_dir():
            files.extend(str(p) for p in recent_files_under(root, ("*.json", "*.jsonl"), limit=10))
    for f in newest(files, 8):
        if len(out) >= 2:
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
        agent = "cascade"
        out.append((task[:160], 0, 0, "", skill, project[:48], (cwd or "")[:240], file_mtime_ms(Path(f)), Path(f).stem[:80], agent))
    # Normalize to 9-tuples without agent tag for emit_row; agent chosen in main
    norm: list[tuple] = []
    for row in out[:2]:
        if len(row) >= 10:
            norm.append(row[:9])
        else:
            norm.append(row if len(row) >= 9 else row)
    return norm[:2]


def augment_activities() -> list[tuple]:
    out = harvest_extension_storage("augment", "augment", "auggie", limit=2)
    roots = [HOME / ".augment", HOME / ".auggie", HOME / "Library" / "Application Support" / "Augment"]
    if len(out) >= 2:
        return out
    files: list[str] = []
    for root in roots:
        if root.is_dir():
            files.extend(str(p) for p in recent_files_under(root, ("*.json", "*.jsonl"), limit=8))
    for f in newest(files, 6):
        text = tail_bytes(Path(f), 80_000)
        task = session_title_from_text(text) or "Augment session"
        cwd = extract_field(text, "cwd") or ""
        project = short_project(cwd) if cwd else short_project(Path(f).stem)
        skill = "pending" if text_looks_pending(text) else ""
        out.append((task[:160], 0, 0, "", skill, project[:48], (cwd or "")[:240], file_mtime_ms(Path(f)), Path(f).stem[:80]))
        if len(out) >= 2:
            break
    return out


def trae_activities() -> list[tuple]:
    out = harvest_extension_storage("trae", "trae", "bytedance.trae", limit=2)
    roots = [
        HOME / "Library" / "Application Support" / "Trae",
        HOME / "Library" / "Application Support" / "Trae" / "User" / "globalStorage",
        HOME / ".trae",
    ]
    if len(out) >= 2:
        return out
    for root in roots:
        if not root.is_dir():
            continue
        for f in recent_files_under(root, ("*.json", "*.jsonl"), limit=8):
            text = tail_bytes(f, 100_000)
            low = text.lower()
            if "agent" not in low and "agent" not in str(f).lower() and "chat" not in low:
                continue
            task = session_title_from_text(text) or "Trae Agent"
            cwd = extract_field(text, "cwd") or extract_field(text, "workspacePath") or ""
            project = short_project(cwd) if cwd else short_project(f.stem)
            skill = "pending" if text_looks_pending(text) else ""
            out.append((task[:160], 0, 0, "", skill, project[:48], (cwd or "")[:240], file_mtime_ms(f), f.stem[:80]))
            if len(out) >= 2:
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
    for f in newest(files, 10):
        text = tail_bytes(Path(f), 100_000)
        low = text.lower()
        if not any(x in low for x in ("agent", "warp ai", "tool_call", "approval", "ask", "permission")):
            continue
        task = session_title_from_text(text) or "Warp Agent"
        cwd = extract_field(text, "cwd") or extract_field(text, "working_directory") or ""
        project = short_project(cwd) if cwd else short_project(Path(f).stem)
        skill = "pending" if text_looks_pending(text) else ""
        out.append((task[:160], 0, 0, "", skill, project[:48], (cwd or "")[:240], file_mtime_ms(Path(f)), Path(f).stem[:80]))
        if len(out) >= 2:
            break
    return out


def home_dir_activities(agent: str, roots: list[Path], limit: int = 2) -> list[tuple]:
    out: list[tuple] = []
    files: list[str] = []
    for root in roots:
        if root.is_dir():
            files.extend(str(p) for p in recent_files_under(root, ("*.json", "*.jsonl", "*.md"), limit=8))
    for f in newest(files, 8):
        text = tail_bytes(Path(f), 100_000)
        task = session_title_from_text(text) or extract_field(text, "title") or f"{agent} session"
        cwd = extract_field(text, "cwd") or extract_field(text, "workspace") or ""
        project = short_project(cwd) if cwd else short_project(Path(f).stem)
        skill = "pending" if text_looks_pending(text) else ""
        out.append((task[:160], 0, 0, "", skill, project[:48], (cwd or "")[:240], file_mtime_ms(Path(f)), Path(f).stem[:80]))
        if len(out) >= limit:
            break
    return out


def cline_activities() -> list[tuple]:
    """Cline: VS Code globalStorage — deepen ask/approval pending."""
    out = harvest_extension_storage("cline", "saoudrizwan.claude-dev", "claude-dev", "cline", limit=2)
    # Extra pass: task history often stores ask_followup_question / api_req pending
    if len(out) >= 2 and any(r[4] == "pending" for r in out):
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
        for f in recent_files_under(store, ("*.json", "*.jsonl"), limit=8):
            text = tail_bytes(f, 120_000)
            low = text.lower()
            pending = text_looks_pending(text) or any(n in low for n in extra_needles)
            if not pending and "task" not in low and "conversation" not in low:
                continue
            task = session_title_from_text(text) or extract_field(text, "task") or "Cline task"
            cwd = extract_field(text, "cwd") or extract_field(text, "workspacePath") or ""
            project = short_project(cwd) if cwd else short_project(store.name)
            skill = "pending" if pending else ""
            row = (task[:160], 0, 0, "", skill, project[:48], (cwd or "")[:240], file_mtime_ms(f), f.stem[:80])
            # Prefer pending rows
            if pending:
                out = [row] + [r for r in out if r[8:] != row[8:]]
            elif not out:
                out.append(row)
            if len(out) >= 2:
                return out[:2]
    return out[:2]


def droid_activities() -> list[tuple]:
    """Factory Droid: ~/.factory/sessions/<encoded-cwd>/*.jsonl"""
    root = HOME / ".factory" / "sessions"
    out: list[tuple] = []
    if not root.is_dir():
        return out
    files = newest([str(p) for p in root.rglob("*.jsonl") if p.is_file()], 8)
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
        out.append((title[:160], 0, 0, "", skill, project[:48], (cwd or "")[:240], file_mtime_ms(f), sid or f.stem[:80]))
        if len(out) >= 2:
            break
    return out


def command_code_activities() -> list[tuple]:
    """Command Code: ~/.commandcode/projects/**/*.jsonl + *.meta.json"""
    root = HOME / ".commandcode" / "projects"
    out: list[tuple] = []
    if not root.is_dir():
        return out
    metas = newest([str(p) for p in root.rglob("*.meta.json") if p.is_file()], 8)
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
        seen.add(sid)
        out.append((title[:160], 0, 0, "", skill, project[:48], (cwd or "")[:240], mtime, sid[:80]))
        if len(out) >= 2:
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
                if len(candidates) >= 6:
                    break
        except OSError:
            pass
    if not candidates and sessions_root.is_dir():
        try:
            for p in sessions_root.rglob("state.json"):
                candidates.append(p.parent)
        except OSError:
            pass
        candidates = sorted(candidates, key=lambda p: p.stat().st_mtime if p.exists() else 0, reverse=True)[:6]

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
        out.append((title[:160], 0, 0, "", skill, project[:48], (cwd or "")[:240], mtime, sid or sdir.name[:80]))
        if len(out) >= 2:
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
    out = harvest_extension_storage("kiro", "kiro", "amazon.kiro", limit=2)
    if len(out) < 2:
        out.extend(
            home_dir_activities(
                "kiro",
                [
                    HOME / ".kiro",
                    HOME / "Library" / "Application Support" / "Kiro",
                ],
                limit=2 - len(out),
            )
        )
    return out[:2]


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
    return home_dir_activities("windsurf", roots, limit=1)


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
    files = newest(paths, 8)
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
        project = short_project(cwd) if cwd else short_project(slug)
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
            )
        )
        if len(out) >= 2:
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
            rows = con.execute(
                """
                SELECT id, title, directory, tokens_input, tokens_output, time_updated
                FROM session
                WHERE IFNULL(time_archived, 0) = 0
                ORDER BY time_updated DESC
                LIMIT 6
                """
            ).fetchall()
        finally:
            con.close()
    except Exception:
        return []

    out: list[tuple] = []
    seen: set[str] = set()
    pending_skill = opencode_pending_skill()
    for sid, title, directory, tin, tout, tupd in rows:
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
        out.append(
            (
                title_s[:160],
                int(tin or 0),
                int(tout or 0),
                "",
                pending_skill if len(out) == 0 else "",  # attach wait to newest session only
                project[:48],
                cwd[:240],
                ms,
            )
        )
        if len(out) >= 2:
            break
    return out


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
) -> None:
    def clean(s: str) -> str:
        return (s or "").replace("\t", " ").replace("\n", " ").replace("\r", " ").strip()

    now_ms = int(time.time() * 1000)
    if mtime_ms > 0 and sub_run == 0 and now_ms - mtime_ms > FRESH_SEC * 1000:
        return
    # Refuse harvest-only rows with no mtime (prevents eternal "running" ghosts).
    if mtime_ms <= 0 and sub_run == 0 and sub_total == 0:
        return

    print(
        f"{agent}\t{clean(task)}\t{tin}\t{tout}\t{clean(tool)}\t{clean(skill)}\t"
        f"{clean(project)}\t{clean(cwd)}\t{mtime_ms}\t{sub_run}\t{sub_total}\t{clean(session_id)}"
    )


def emit_row(agent: str, row: tuple, path: Path | None = None) -> None:
    """Accept 7/8/10/11/12-tuple activity rows; stamp mtime from path when needed."""
    if len(row) >= 12:
        emit(agent, *row[:12])
        return
    if len(row) >= 11:
        # 10-tuple + session OR 11 with subs already
        emit(agent, *row[:11])
        return
    if len(row) >= 10:
        emit(agent, *row[:10])
        return
    if len(row) >= 9:
        # 8-tuple + session_id
        task, tin, tout, tool, skill, project, cwd, ms, sid = row[:9]
        emit(agent, task, tin, tout, tool, skill, project, cwd, int(ms or 0), 0, 0, str(sid or ""))
        return
    if len(row) >= 8:
        task, tin, tout, tool, skill, project, cwd, ms = row[:8]
        emit(agent, task, tin, tout, tool, skill, project, cwd, int(ms or 0), 0, 0)
        return
    task, tin, tout, tool, skill, project, cwd = row[:7]
    ms = file_mtime_ms(path) if path is not None else 0
    emit(agent, task, tin, tout, tool, skill, project, cwd, ms, 0, 0)


def aider_activities() -> list[tuple]:
    """Aider: recent .aider.chat.history.md — ask/confirm at tail → pending."""
    paths: list[Path] = []
    roots = [
        HOME / "Documents",
        HOME / "Desktop",
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
        if not root.is_dir() or len(paths) >= 6:
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
                    if len(paths) >= 6:
                        return
        except OSError:
            return

    for root in roots:
        scan_root(root)
        if len(paths) >= 6:
            break
    files = newest([str(p) for p in paths], 4)
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
        out.append((task or "Aider session", 0, 0, "", skill, project[:48], cwd[:240], file_mtime_ms(Path(f)), Path(f).parent.name))
        if len(out) >= 2:
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
    files = [Path(p) for p in newest([str(f) for f in files if f.is_file()], 8)]
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
        out.append((title[:160] or "Goose session", 0, 0, "", skill, project[:48], cwd[:240], file_mtime_ms(f), sid[:80]))
        if len(out) >= 2:
            break
    return out


def guard(label: str, body) -> None:
    """Run one agent's harvest in isolation.

    Every harvester touches other tools' private files, so any of them can hit a
    vanished path, a locked sqlite db, or unexpected JSON. Without this, one bad
    agent raised out of main(), the script exited non-zero, and Pulse threw away
    the whole scan (`harvestUnreliable`) — a single broken harvester blinded all
    32 agents.
    """
    try:
        body()
    except Exception as exc:  # harvest is best-effort by design
        print(f"# pulse: {label} harvest failed: {type(exc).__name__}: {exc}", file=sys.stderr)


def emit_all(agent: str, rows) -> None:
    for row in rows:
        emit_row(agent, row)


def claude_block() -> None:
    for row in claude_activities():
        emit("claude", *row)


def grok_pi_block() -> None:
    for name, fn in (("grok", grok_activity), ("pi", pi_activity)):
        row = fn()
        if any(row[:7]):
            emit_row(name, row)


def amp_block() -> None:
    amp_skill, amp_sid, amp_ms = amp_pending_from_logs()
    amp_rows = amp_activities()
    if amp_rows:
        for i, row in enumerate(amp_rows):
            if i == 0 and amp_skill:
                # inject pending into skill field (index 4)
                lst = list(row)
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
                emit_row("amp", tuple(lst))
            else:
                emit_row("amp", row)
    elif amp_skill:
        emit("amp", "Amp thread", 0, 0, "", amp_skill, "", "", amp_ms or int(time.time() * 1000), 0, 0, amp_sid)


def cascade_block() -> None:
    cascade_rows = cascade_windsurf_activities()
    for row in cascade_rows:
        emit_row("cascade", row)
    if not cascade_rows:
        for row in windsurf_shell_activities():
            emit_row("windsurf", row)


def simple(agent: str, fn):
    """One agent whose harvester is a plain `() -> list[row]`."""
    return (agent, lambda: emit_all(agent, fn()))


# Emission order is preserved from the pre-0.21.1 inline main(); each entry now
# runs under `guard` so one failure cannot take the rest of the scan with it.
HARVESTERS = (
    ("claude", claude_block),
    simple("codex", codex_activities),
    simple("cursor", cursor_activities),
    ("grok/pi", grok_pi_block),
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
    ("cascade/windsurf", cascade_block),
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
