#!/usr/bin/env python3
"""Catalog gate: one agent roster, read from AgentCatalog.swift, and every
promise made about it.

23.0 merged four gates that each re-read the catalog (`agent_catalog_check`,
`coverage_check`, `matrix_check`, `vendor_formats_check`) and the roster
reader they shared (`agent_roster`). The checks are the ones that guard a
real fact; prose checks ("EXPERIENCE.md must say 32 visible Agents") went.

1. Roster — `AgentCatalog.all` has one `AgentSpec` per `AgentID` case, in
   declaration order (process-rule precedence), with unique monograms, and
   no per-agent table grows back elsewhere (12.0): outside the catalog no
   `case` line or list names more than MAX_PER_CASE agents and no file's
   `case` lines name more than MAX_PER_FILE.
2. Processes (24.0) — agent processes come from the kernel's table
   (libproc, `AgentProcesses.swift`): no `ps`, no `lsof`, no subprocess; and
   Cursor's private worker daemon is denied. No file-scraping collector
   grows back (`NativeActivityHarvest`, harvest roots).
3. Privacy — AppleScript only behind the Terminal/iTerm Automation opt-in;
   no enumeration of every running app.
4. README support matrix — each row's waiting cell equals the catalog, and
   every agent has a row.
5. Vendor sources (24.0) — every agent has an entry in
   docs/vendor-formats.json with a `hooks` block: the roster is exactly the
   seven supported agents; each has a `HookContract` whose events are never
   a gating event, and its manifest entry names the source it was read from
   (repo + full commit, or docs URLs), the date, the same event list and a
   test file that mentions the agent.

Run: python3 scripts/catalog_check.py
"""
from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "PulseBar" / "Sources"
CATALOG = SOURCES / "PulseCore" / "AgentCatalog.swift"
README = ROOT / "README.md"
MANIFEST = ROOT / "docs" / "vendor-formats.json"
TESTS = ROOT / "PulseBar" / "Tests" / "PulseBarTests"
MAX_PER_CASE = 6
MAX_PER_FILE = 8
# 24.0 (Exact): the owner's roster. Adding an agent is a product decision.
ROSTER = ["claude", "codex", "cursor", "pi", "gemini", "copilot", "opencode"]


@dataclass
class Agent:
    case: str          # Swift case name, e.g. commandCode
    raw: str           # raw value, e.g. command_code
    display: str
    waiting: str       # hooks | none
    hook_format: str   # HookFormat case
    hook_events: list[str]


def swift_file(name: str) -> Path:
    """A Swift source by file name, in whichever target holds it."""
    hits = sorted(SOURCES.glob(f"*/{name}"))
    if len(hits) != 1:
        raise SystemExit(f"catalog_check: expected one {name}, found {len(hits)}")
    return hits[0]


def cases(text: str) -> list[tuple[str, str]]:
    """(case name, raw value) of `AgentID`, in declaration order."""
    block = re.search(r"enum AgentID[^{]*\{(.*?)\n\n", text, re.S)
    if not block:
        raise SystemExit("catalog_check: enum AgentID not found in AgentCatalog.swift")
    out: list[tuple[str, str]] = []
    for line in block.group(1).splitlines():
        line = line.strip()
        if not line.startswith("case "):
            continue
        for part in line[len("case "):].split(","):
            part = part.strip()
            if not part:
                continue
            m = re.match(r'(\w+)\s*=\s*"([^"]+)"', part)
            out.append((m.group(1), m.group(2)) if m else (part, part.rstrip("_")))
    return out


def agents(text: str) -> list[Agent]:
    raw_of = dict(cases(text))
    starts = [m.start() for m in re.finditer(r"\n        AgentSpec\(\n", text)]
    out: list[Agent] = []
    for i, start in enumerate(starts):
        chunk = text[start:starts[i + 1] if i + 1 < len(starts) else len(text)]

        def field(name: str) -> str:
            m = re.search(rf"\n            {name}: ([^\n]*)", chunk)
            if not m:
                raise SystemExit(f"catalog_check: spec field {name} missing near {chunk[:80]!r}")
            return m.group(1).rstrip(",").strip()

        case = field("id").lstrip(".")
        fmt = re.search(r"hooks: HookContract\(format: \.(\w+)", chunk)
        out.append(Agent(
            case=case,
            raw=raw_of[case],
            display=field("displayName").strip('"'),
            waiting=field("waiting").lstrip("."),
            hook_format=fmt.group(1) if fmt else "",
            hook_events=re.findall(r'HookEvent\("([^"]+)"', chunk),
        ))
    return out


# 1 · roster -----------------------------------------------------------------

def check_roster(text: str, roster: list[Agent], problems: list[str]) -> None:
    names = [case for case, _ in cases(text)]
    specs = [agent.case for agent in roster]
    if sorted(specs) != sorted(names) or len(specs) != len(set(specs)):
        missing = sorted(set(names) - set(specs))
        extra = sorted(set(specs) - set(names))
        problems.append(f"catalog specs ≠ AgentID cases (missing {missing}, extra {extra})")
    if specs != names:
        problems.append("AgentCatalog.all must follow AgentID declaration order (process-rule precedence)")
    monograms = re.findall(r'monogram:\s*"([^"]+)"', text)
    if len(monograms) != len(set(monograms)):
        problems.append("monograms must be unique across the roster")

    agent_re = re.compile(r"\.(" + "|".join(re.escape(n) for n in names) + r")\b")
    for path in sorted(SOURCES.glob("*/*.swift")):
        if path == CATALOG:
            continue
        source = path.read_text(encoding="utf-8")
        seen: set[str] = set()
        for number, line in enumerate(source.splitlines(), 1):
            stripped = line.strip()
            if not stripped.startswith("case ."):
                continue
            hits = set(agent_re.findall(stripped.split(":")[0]))
            if len(hits) > MAX_PER_CASE:
                problems.append(f"{path.name}:{number}: a case naming {len(hits)} agents — "
                                "roster-wide facts belong in AgentCatalog")
            seen |= hits
        # A roster list is a roster table too: 12.0 missed an eleven-agent
        # `[.amp, .claude, …].contains(id)` that wrapped across two lines.
        code = re.sub(r"//[^\n]*", "", source)
        for match in re.finditer(r"\[([^\[\]]*)\]", code):
            listed = set(agent_re.findall(match.group(1)))
            if len(listed) > MAX_PER_CASE:
                number = code.count("\n", 0, match.start()) + 1
                problems.append(f"{path.name}:{number}: a list naming {len(listed)} agents — "
                                "roster-wide facts belong in AgentCatalog")
        if len(seen) > MAX_PER_FILE:
            problems.append(f"{path.name}: `case` lines name {len(seen)} agents — "
                            "an exhaustive per-agent table belongs in AgentCatalog")


# 2 · processes --------------------------------------------------------------

def check_processes(text: str, problems: list[str]) -> None:
    if '"worker start"' not in text or '"--worker-dir"' not in text:
        problems.append("Cursor's private worker daemon must be denied — it is infrastructure, not a session")
    scan = swift_file("AgentProcesses.swift").read_text(encoding="utf-8")
    if "proc_listallpids" not in scan or "KERN_PROCARGS2" not in scan:
        problems.append("AgentProcesses must read the process table through libproc and KERN_PROCARGS2")
    for path in sorted(SOURCES.glob("*/*.swift")):
        source = re.sub(r"//[^\n]*", "", path.read_text(encoding="utf-8"))
        if re.search(r'"/(usr/)?s?bin/(ps|lsof)"', source):
            problems.append(f"{path.name}: no ps or lsof subprocess — the process table is libproc (24.0)")
    for gone in ("NativeActivityHarvest.swift", "HarvestFacts.swift", "ProcessProbe.swift"):
        if list(SOURCES.glob(f"*/{gone}")):
            problems.append(f"{gone} is back — 24.0 deleted the file-scraping collector")
    if "harvestRoots" in text:
        problems.append("the catalog has harvest roots again — Pulse reads no vendor directory (24.0)")


# 3 · privacy ----------------------------------------------------------------

def check_privacy(problems: list[str]) -> None:
    focus = swift_file("TerminalFocus.swift").read_text(encoding="utf-8")
    scripts = "/usr/bin/osascript" in focus or "tell application" in focus
    if "allowTTYAutomation" not in focus:
        problems.append("TerminalFocus must gate TTY focus on allowTTYAutomation")
    if scripts and "focusTTY" not in focus:
        problems.append("AppleScript is allowed only inside the opt-in Terminal/iTerm tab focus")
    for name in ("TerminalFocus.swift", "SingleInstanceGuard.swift"):
        source = swift_file(name).read_text(encoding="utf-8")
        if re.search(r"NSWorkspace\.shared\.runningApplications\b", source) or (
            "runningApplications" in source and not re.search(
            r"runningApplications\s*\(withBundleIdentifier:", source
        )):
            problems.append(f"{name} must not enumerate every running app")


# 4 · README support matrix --------------------------------------------------

def readme_rows() -> list[tuple[str, str, int]]:
    """(names cell, waiting cell, line number)."""
    rows: list[tuple[str, str, int]] = []
    in_table = False
    for n, line in enumerate(README.read_text(encoding="utf-8").splitlines(), start=1):
        if line.startswith("| Agent |"):
            in_table = True
            continue
        if in_table:
            if not line.startswith("|"):
                break
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) < 4 or set(cells[0]) <= set("- "):
                continue
            rows.append((cells[0], cells[3], n))
    return rows


def waiting_kind(cell: str) -> str:
    low = cell.lower()
    if "none" in low:
        return "none"
    if "hooks" in low or "plugin" in low or "extension" in low:
        return "hooks"
    return "?"


def check_matrix(roster: list[Agent], problems: list[str]) -> int:
    by_case = {a.case: a for a in roster}
    by_display = {a.display: a for a in roster}
    rows = readme_rows()
    if not rows:
        problems.append("README has no support matrix (expected a '| Agent |' table)")
        return 0
    covered: set[str] = set()
    for names_cell, waiting_cell, lineno in rows:
        want_wait = waiting_kind(waiting_cell)
        if want_wait == "?":
            problems.append(f"README:{lineno} unreadable waiting cell {waiting_cell!r}")
            continue
        for raw in names_cell.split("/"):
            name = raw.strip().rstrip("*").strip()
            if not name:
                continue
            agent = by_display.get(name)
            if agent is None:
                problems.append(f"README:{lineno} unknown agent name {name!r}")
                continue
            covered.add(agent.case)
            if agent.waiting != want_wait:
                problems.append(f"README:{lineno} {name}: waiting says {want_wait}, catalog says {agent.waiting}")
    for case, agent in by_case.items():
        if case not in covered:
            problems.append(f"{agent.display}: absent from the README support matrix")
    return len(covered)


SHA = re.compile(r"^[0-9a-f]{40}$")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


# 5 · vendor sources: hook contracts ---------------------------------------------------------

def check_hooks(text: str, roster: list[Agent], problems: list[str]) -> None:
    raws = [a.raw for a in roster]
    if sorted(raws) != sorted(ROSTER):
        problems.append(f"roster must be exactly {ROSTER} (24.0), found {raws}")
    gating = re.search(r"gatingEvents: Set<String> = \[(.*?)\]", text, re.S)
    listed = set(re.findall(r'"([^"]+)"', gating.group(1))) if gating else set()
    for must in ("PreToolUse", "preToolUse", "beforeShellExecution", "beforeSubmitPrompt", "BeforeTool", "tool.execute.before"):
        if must not in listed:
            problems.append(f"HookContract.gatingEvents must list {must}")
    try:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8")).get("agents", {})
    except (OSError, json.JSONDecodeError):
        manifest = {}
    known = {a.raw for a in roster}
    for raw in manifest:
        if raw not in known:
            problems.append(f"vendor sources — {raw}: in the manifest but not in the catalog")
    for agent in roster:
        entry = manifest.get(agent.raw) or {}
        if set(entry) - {"hooks"}:
            problems.append(f"vendor sources — {agent.raw}: only a hooks block is kept (24.0 reads no session store); "
                            f"found {sorted(set(entry) - {'hooks'})}")
        if not agent.hook_format or not agent.hook_events:
            problems.append(f"hooks — {agent.raw}: no HookContract with events in the catalog")
            continue
        for event in agent.hook_events:
            if event in listed:
                problems.append(f"hooks — {agent.raw}: {event} is a gating event and is never installed")
        if agent.raw == "codex" and "PermissionRequest" in agent.hook_events:
            problems.append("hooks — codex: PermissionRequest fires before Codex's own auto-review (fake Waiting)")
        hooks = (manifest.get(agent.raw) or {}).get("hooks")
        if not isinstance(hooks, dict):
            problems.append(f"hooks — {agent.raw}: vendor-formats.json needs a hooks block (source, events)")
            continue
        source = hooks.get("source")
        if source == "repo":
            if not str(hooks.get("repo", "")).startswith("https://github.com/"):
                problems.append(f"hooks — {agent.raw}: repo must be a https://github.com/ URL")
            if not SHA.match(str(hooks.get("commit", ""))):
                problems.append(f"hooks — {agent.raw}: commit must be the full 40-hex SHA that was read")
            if not hooks.get("watch"):
                problems.append(f"hooks — {agent.raw}: watch must list the vendor files that define the hooks")
        elif source == "docs":
            if not hooks.get("urls"):
                problems.append(f"hooks — {agent.raw}: docs hooks list the URLs read")
        else:
            problems.append(f"hooks — {agent.raw}: hooks source must be repo or docs")
        if not DATE.match(str(hooks.get("checked", ""))):
            problems.append(f"hooks — {agent.raw}: checked must be the YYYY-MM-DD the source was read")
        if sorted(hooks.get("events", [])) != sorted(agent.hook_events):
            problems.append(f"hooks — {agent.raw}: manifest events {hooks.get('events')} ≠ catalog {agent.hook_events}")
        tests = hooks.get("tests", [])
        if not tests:
            problems.append(f"hooks — {agent.raw}: name at least one test that exercises this contract")
        needles = {agent.raw.lower(), agent.display.lower()}
        for test in tests:
            path = TESTS / test
            if not path.exists():
                problems.append(f"hooks — {agent.raw}: test file {test} does not exist")
            elif not any(n in path.read_text(encoding="utf-8").lower() for n in needles):
                problems.append(f"hooks — {agent.raw}: {test} never mentions {agent.display}")


def main() -> int:
    text = CATALOG.read_text(encoding="utf-8")
    roster = agents(text)
    problems: list[str] = []
    check_roster(text, roster, problems)
    check_processes(text, problems)
    check_privacy(problems)
    in_matrix = check_matrix(roster, problems)
    check_hooks(text, roster, problems)
    if problems:
        for problem in problems:
            print(f"::error::{problem}")
        return 1
    print(f"catalog OK — {len(roster)} agents, one spec and one hook contract each; "
          f"{in_matrix} in the README matrix; every hook contract has a source")
    return 0


if __name__ == "__main__":
    sys.exit(main())
