#!/usr/bin/env python3
"""Catalog gate: one agent roster, read from AgentCatalog.swift, and every
promise made about it.

The checks are the ones that guard a real fact; prose checks went.

1. Roster — `AgentCatalog.all` has one `AgentSpec` per `AgentID` case, in
   declaration order (process-rule precedence).
2. Processes — agent processes come from the kernel's table (libproc,
   `AgentProcesses.swift`): no `ps`, no `lsof`, no subprocess; and Cursor's
   private worker daemon is denied.
3. Privacy — AppleScript only behind the Terminal/iTerm Automation opt-in;
   no enumeration of every running app; and no tokens, context, cost or
   plan: no source reads `usage`, `token_count`, `rate_limits`, `cost` (or
   their cousins) from a payload or a module's event — an owner decision.
4. Vendor sources — every agent has an entry in
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
MANIFEST = ROOT / "docs" / "vendor-formats.json"
TESTS = ROOT / "PulseBar" / "Tests" / "PulseBarTests"
# The owner's roster. Adding an agent is a product decision.
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
            problems.append(f"{path.name}: no ps or lsof subprocess — the process table is libproc")


# 3 · privacy ----------------------------------------------------------------

def check_privacy(problems: list[str]) -> None:
    focus = swift_file("TerminalFocus.swift").read_text(encoding="utf-8")
    plan = swift_file("LandingPlan.swift").read_text(encoding="utf-8")
    # LandingPlan decides (pure), TerminalFocus runs. Every AppleScript
    # step is planned only behind the Automation opt-in.
    make = plan[plan.find("static func make("):]
    make = make[:make.find("\n    }\n")]
    gated = make[make.find("if allowAutomation"):] if "if allowAutomation" in make else ""
    for step in (".iTermSession(", ".ttyTab("):
        if step in make and step not in gated:
            problems.append(f"LandingPlan.make must plan {step[1:-1]} only behind allowAutomation")
    scripts = "/usr/bin/osascript" in focus or "tell application" in focus
    if scripts and "focusTTY" not in focus:
        problems.append("AppleScript is allowed only inside the opt-in Terminal/iTerm tab focus")
    for name in ("TerminalFocus.swift", "SingleInstanceGuard.swift"):
        source = swift_file(name).read_text(encoding="utf-8")
        if re.search(r"NSWorkspace\.shared\.runningApplications\b", source) or (
            "runningApplications" in source and not re.search(
            r"runningApplications\s*\(withBundleIdentifier:", source
        )):
            problems.append(f"{name} must not enumerate every running app")
    check_no_tokens(problems)


# Tokens, context, cost and plan are not shown — a decision. A payload key
# or a module's event field that carries them is never read. Legitimate
# unrelated uses of a word, if one ever appears, are listed here with why.
USAGE_KEYS = [
    "usage", "token_count", "tokenCount", "rate_limits", "rateLimits", "cost", "total_cost_usd",
    "cost_usd", "input_tokens", "output_tokens", "total_tokens", "cache_read_input_tokens",
    "context_window", "contextWindow", "plan_type", "planType",
]
USAGE_ALLOWED: dict[str, str] = {}
USAGE_LITERAL = re.compile(r"""["'](""" + "|".join(re.escape(k) for k in USAGE_KEYS) + r""")["']""")
USAGE_MEMBER = re.compile(r"\.(" + "|".join(re.escape(k) for k in USAGE_KEYS) + r")\b")


def check_no_tokens(problems: list[str]) -> None:
    for path in sorted(SOURCES.glob("*/*.swift")):
        code = re.sub(r"/\*.*?\*/", "", path.read_text(encoding="utf-8"), flags=re.S)
        code = re.sub(r"(?m)^\s*//.*$", "", code)
        code = re.sub(r"\s//[^\n\"]*$", "", code, flags=re.M)
        for pattern in (USAGE_LITERAL, USAGE_MEMBER):
            for match in pattern.finditer(code):
                if path.name in USAGE_ALLOWED:
                    continue
                number = code.count("\n", 0, match.start()) + 1
                problems.append(f"{path.name}:{number}: reads {match.group(1)!r} — tokens, context, cost and "
                                "plan are not shown (a decision); the last step comes from events only")


SHA = re.compile(r"^[0-9a-f]{40}$")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


# 4 · vendor sources: hook contracts ---------------------------------------------------------

def check_hooks(text: str, roster: list[Agent], problems: list[str]) -> None:
    raws = [a.raw for a in roster]
    if sorted(raws) != sorted(ROSTER):
        problems.append(f"roster must be exactly {ROSTER}, found {raws}")
    gating = re.search(r"gatingEvents: Set<String> = \[(.*?)\]", text, re.S)
    listed = set(re.findall(r'"([^"]+)"', gating.group(1))) if gating else set()
    for must in ("PreToolUse", "preToolUse", "beforeShellExecution", "beforeSubmitPrompt", "BeforeTool", "tool.execute.before"):
        if must not in listed:
            problems.append(f"HookContract.gatingEvents must list {must}")
    # A red lamp must have a way to go out besides the end of the turn: an
    # agent that can raise a block installs an event that answers it (a tool
    # ran after it, or the vendor's own "replied"). Per-tool activity is
    # what makes a stall meaningful, so it is never a gating event either.
    tool_block = re.search(r"toolActivityEvents: Set<String> = \[(.*?)\]", text, re.S)
    tool_events = set(re.findall(r'"([^"]+)"', tool_block.group(1))) if tool_block else set()
    answer_block = re.search(r"answerEvents: Set<String> = toolActivityEvents\.union\(\[(.*?)\]\)", text, re.S)
    answer_events = tool_events | (set(re.findall(r'"([^"]+)"', answer_block.group(1))) if answer_block else set())
    if not tool_events or not answer_block:
        problems.append("HookContract.toolActivityEvents / answerEvents not found in AgentCatalog.swift")
    for event in sorted(tool_events & listed):
        problems.append(f"HookContract.toolActivityEvents lists {event}, a gating event")
    for agent in roster:
        if agent.waiting == "hooks" and not set(agent.hook_events) & answer_events:
            problems.append(f"hooks — {agent.raw}: can raise a block but installs no event that answers it "
                            f"(one of {sorted(answer_events)})")
    for raw, needed in (("gemini", "AfterTool"), ("copilot", "postToolUse"), ("codex", "PostToolUse"), ("claude", "PostToolUse")):
        agent = next((a for a in roster if a.raw == raw), None)
        if agent and needed not in agent.hook_events:
            problems.append(f"hooks — {raw}: {needed} is its per-tool activity (the answer to a block, the stall rule)")
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
            problems.append(f"vendor sources — {agent.raw}: only a hooks block is kept (Pulse reads no vendor file); "
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
    check_hooks(text, roster, problems)
    if problems:
        for problem in problems:
            print(f"::error::{problem}")
        return 1
    print(f"catalog OK — {len(roster)} agents, one spec and one hook contract each; "
          "every hook contract has a source")
    return 0


if __name__ == "__main__":
    sys.exit(main())
