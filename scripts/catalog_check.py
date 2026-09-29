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
2. Harvest — the native descriptors are built from the catalog and every
   agent but the `cursor_agent` transport alias has harvest roots.
3. Process probe — Cursor's private worker daemon is denied, and `lsof`
   output is read independently of its exit status (0.99.2: status 1 still
   carries every resolved process).
4. Privacy — AppleScript only behind the Terminal/iTerm Automation opt-in;
   no enumeration of every running app.
5. README support matrix — each row's harvest and waiting cells equal the
   catalog, and every agent has a row.
6. Vendor formats — every agent has an entry in docs/vendor-formats.json
   (repo with a full commit and watch list, docs with URLs, or an honest
   `unverified` with a reason); a named test file exists and mentions the
   agent; and an `unverified` format has `waiting: .none` (23.0 — pending
   read from a format nobody checked is not evidence).

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
SELF_TEST = SOURCES / "PulseBar" / "NativeHarvestSelfTest.swift"
MAX_PER_CASE = 6
MAX_PER_FILE = 8
ALIAS = "cursor_agent"  # a transport alias of cursor: no roots, no README row


@dataclass
class Agent:
    case: str          # Swift case name, e.g. commandCode
    raw: str           # raw value, e.g. command_code
    display: str
    waiting: str       # hooks | harvestPending | none
    harvest: str       # structuredSession | bestEffortCache
    has_collector: bool


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
        out.append(Agent(
            case=case,
            raw=raw_of[case],
            display=field("displayName").strip('"'),
            waiting=field("waiting").lstrip("."),
            harvest=field("harvest").lstrip("."),
            has_collector=not field("harvestRoots").startswith("[]"),
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


# 2 · harvest ----------------------------------------------------------------

def check_harvest(roster: list[Agent], problems: list[str]) -> None:
    native = swift_file("NativeActivityHarvest.swift").read_text(encoding="utf-8")
    if "AgentCatalog.all" not in native or "harvestRoots" not in native:
        problems.append("NativeActivityHarvest.descriptors() must be built from AgentCatalog")
    missing = sorted(a.raw for a in roster if a.raw != ALIAS and not a.has_collector)
    if missing:
        problems.append(f"no native harvest roots: {', '.join(missing)}")


# 3 · process probe ----------------------------------------------------------

def check_probe(text: str, problems: list[str]) -> None:
    if '"worker start"' not in text or '"--worker-dir"' not in text:
        problems.append("Cursor's private worker daemon must be denied — it is infrastructure, not a session")
    probe = swift_file("ProcessProbe.swift").read_text(encoding="utf-8")
    if "workingDirectories(from:" not in probe or "shouldBackOff(" not in probe:
        problems.append("ProcessProbe must read lsof output independently of its exit status; "
                        "keep workingDirectories(from:) and shouldBackOff()")
    if re.search(r"lsof[\s\S]{0,400}?status == 0", probe):
        problems.append("lsof output must not be gated on a zero exit status")


# 4 · privacy ----------------------------------------------------------------

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


# 5 · README support matrix --------------------------------------------------

def readme_rows() -> list[tuple[str, str, str, int]]:
    """(names cell, harvest cell, waiting cell, line number)."""
    rows: list[tuple[str, str, str, int]] = []
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
            rows.append((cells[0], cells[2], cells[3], n))
    return rows


def waiting_kind(cell: str) -> str:
    low = cell.lower()
    if "none" in low:
        return "none"
    if "hooks" in low:
        return "hooks"
    if "pending" in low:
        return "harvestPending"
    return "?"


def harvest_kind(cell: str) -> str:
    low = cell.lower()
    if "structured" in low or "结构化" in low:
        return "structuredSession"
    if "best" in low or "尽力" in low:
        return "bestEffortCache"
    return "?"


def check_matrix(roster: list[Agent], problems: list[str]) -> int:
    by_case = {a.case: a for a in roster}
    by_display = {a.display: a for a in roster}
    # The short forms the README table uses.
    by_display.update({"Zed": by_case["zedAgent"], "Warp": by_case["warpAgent"]})
    rows = readme_rows()
    if not rows:
        problems.append("README has no support matrix (expected a '| Agent |' table)")
        return 0
    covered: set[str] = set()
    for names_cell, harvest_cell, waiting_cell, lineno in rows:
        want_wait, want_harvest = waiting_kind(waiting_cell), harvest_kind(harvest_cell)
        if want_wait == "?" or want_harvest == "?":
            problems.append(f"README:{lineno} unreadable cells {harvest_cell!r} / {waiting_cell!r}")
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
            if agent.harvest != want_harvest:
                problems.append(f"README:{lineno} {name}: harvest says {want_harvest}, catalog says {agent.harvest}")
    for case, agent in by_case.items():
        if agent.raw != ALIAS and case not in covered:
            problems.append(f"{agent.display}: absent from the README support matrix")
    return len(covered)


# 6 · vendor formats ---------------------------------------------------------

SHA = re.compile(r"^[0-9a-f]{40}$")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def check_vendor_formats(roster: list[Agent], problems: list[str]) -> dict[str, int]:
    try:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8")).get("agents", {})
    except (OSError, json.JSONDecodeError) as error:
        problems.append(f"{MANIFEST.relative_to(ROOT)}: {error}")
        return {}
    counts: dict[str, int] = {}
    for agent in roster:
        raw = agent.raw
        entry = manifest.get(raw)
        if entry is None:
            problems.append(f"vendor formats — {raw}: no entry; say where its format was checked or that it was not")
            continue
        source = entry.get("source")
        counts[source] = counts.get(source, 0) + 1
        if source not in {"repo", "docs", "unverified"}:
            problems.append(f"vendor formats — {raw}: source must be repo, docs or unverified")
            continue
        if source == "repo":
            if not str(entry.get("repo", "")).startswith("https://github.com/"):
                problems.append(f"vendor formats — {raw}: repo must be a https://github.com/ URL")
            if not SHA.match(str(entry.get("commit", ""))):
                problems.append(f"vendor formats — {raw}: commit must be the full 40-hex SHA that was read")
            if not entry.get("watch"):
                problems.append(f"vendor formats — {raw}: watch must list the vendor files that define the format")
        if source == "docs" and not entry.get("urls"):
            problems.append(f"vendor formats — {raw}: docs entries list the URLs read")
        if source in {"repo", "docs"}:
            if not DATE.match(str(entry.get("checked", ""))):
                problems.append(f"vendor formats — {raw}: checked must be the YYYY-MM-DD the source was read")
            tests = entry.get("tests", [])
            if not tests:
                problems.append(f"vendor formats — {raw}: name at least one test whose fixture follows this source")
            needles = {raw.lower(), agent.display.lower(), raw.replace("_", "").lower()}
            for test in tests:
                path = SELF_TEST if test == SELF_TEST.name else TESTS / test
                if not path.exists():
                    problems.append(f"vendor formats — {raw}: test file {test} does not exist")
                elif not any(n in path.read_text(encoding="utf-8").lower() for n in needles):
                    problems.append(f"vendor formats — {raw}: {test} never mentions {agent.display}")
        if source == "unverified":
            if not entry.get("why"):
                problems.append(f"vendor formats — {raw}: say why the format could not be checked")
            if agent.waiting != "none":
                problems.append(f"vendor formats — {raw}: an unverified format must have waiting: .none, "
                                f"not .{agent.waiting}")
    known = {a.raw for a in roster}
    for raw in manifest:
        if raw not in known:
            problems.append(f"vendor formats — {raw}: in the manifest but not in the catalog")
    return counts


def main() -> int:
    text = CATALOG.read_text(encoding="utf-8")
    roster = agents(text)
    problems: list[str] = []
    check_roster(text, roster, problems)
    check_harvest(roster, problems)
    check_probe(text, problems)
    check_privacy(problems)
    in_matrix = check_matrix(roster, problems)
    counts = check_vendor_formats(roster, problems)
    if problems:
        for problem in problems:
            print(f"::error::{problem}")
        return 1
    sources = ", ".join(f"{counts.get(s, 0)} {s}" for s in ("repo", "docs", "unverified"))
    print(f"catalog OK — {len(roster)} agents, one spec each; {in_matrix} in the README matrix; "
          f"vendor formats {sources}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
