#!/usr/bin/env python3
"""20.0 Drift: every agent's parser names where its format came from.

Pulse reads 31 vendors' private session files. When a vendor changes its
format Pulse does not fail — it quietly reads less: no title, no last word,
a missed pending. 18.0 found Codex's paginated rollouts that way and 20.0
found Gemini's JSONL chats, both by reading the vendor's own source.

`docs/vendor-formats.json` records, per agent, what the parser was checked
against:

- ``source: "repo"`` — an open-source vendor: the repository, the exact
  commit read, the vendor files that define the format (``watch``; the
  weekly drift sentinel diffs these), and the Pulse tests whose fixtures
  were built from that source.
- ``source: "docs"`` — a closed-source vendor: the documentation URLs and
  the date they were read, plus the tests.
- ``source: "unverified"`` — nothing public describes the format; the
  entry says so and why, rather than implying a check that never happened.

This gate fails when an agent in the catalog has no entry, an entry names a
test file that does not exist or does not mention the agent, a repo entry
lacks a full commit or watch list, or the manifest names an agent the
catalog no longer has.

Run: python3 scripts/vendor_formats_check.py
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "docs" / "vendor-formats.json"
CATALOG = ROOT / "PulseBar" / "Sources" / "PulseCore" / "AgentCatalog.swift"
TESTS = ROOT / "PulseBar" / "Tests" / "PulseBarTests"
SELF_TEST = ROOT / "PulseBar" / "Sources" / "PulseBar" / "NativeHarvestSelfTest.swift"
SOURCES = {"repo", "docs", "unverified"}
SHA = re.compile(r"^[0-9a-f]{40}$")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def roster() -> dict[str, str]:
    """Raw value → display name, from the catalog."""
    text = CATALOG.read_text(encoding="utf-8")
    block = re.search(r"enum AgentID[^{]*\{(.*?)\n\n", text, re.S)
    raws: list[str] = []
    for line in block.group(1).splitlines():
        line = line.strip()
        if not line.startswith("case "):
            continue
        for item in line[5:].split(","):
            item = item.strip()
            if not item:
                continue
            if "=" in item:
                raws.append(item.split("=", 1)[1].strip().strip('"'))
            else:
                raws.append(item.rstrip("_"))
    names: dict[str, str] = {}
    for spec in text.split("AgentSpec(\n")[1:]:
        ident = re.search(r"id: \.(\w+)", spec)
        name = re.search(r'displayName: "([^"]+)"', spec)
        if ident and name:
            names[ident.group(1)] = name.group(1)
    out: dict[str, str] = {}
    for raw in raws:
        camel = re.sub(r"_(\w)", lambda m: m.group(1).upper(), raw)
        out[raw] = names.get(camel) or names.get(camel + "_") or raw
    return out


def mentions(path: Path, raw: str, name: str) -> bool:
    text = path.read_text(encoding="utf-8").lower()
    needles = {raw.lower(), name.lower(), raw.replace("_", "").lower()}
    return any(n in text for n in needles)


def main() -> int:
    errors: list[str] = []
    try:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"::error::{MANIFEST.relative_to(ROOT)}: {error}")
        return 1
    agents = manifest.get("agents", {})
    catalog = roster()

    for raw, name in catalog.items():
        entry = agents.get(raw)
        if entry is None:
            errors.append(f"{raw}: no entry — say where its format was checked (repo, docs) or that it was not (unverified)")
            continue
        source = entry.get("source")
        if source not in SOURCES:
            errors.append(f"{raw}: source must be one of {sorted(SOURCES)}")
            continue
        if source == "repo":
            if not str(entry.get("repo", "")).startswith("https://github.com/"):
                errors.append(f"{raw}: repo must be a https://github.com/ URL")
            if not SHA.match(str(entry.get("commit", ""))):
                errors.append(f"{raw}: commit must be the full 40-hex SHA that was read")
            if not entry.get("watch"):
                errors.append(f"{raw}: watch must list the vendor files that define the format")
        if source == "docs" and not entry.get("urls"):
            errors.append(f"{raw}: docs entries list the URLs read")
        if source in {"repo", "docs"}:
            if not DATE.match(str(entry.get("checked", ""))):
                errors.append(f"{raw}: checked must be the YYYY-MM-DD the source was read")
            tests = entry.get("tests", [])
            if not tests:
                errors.append(f"{raw}: name at least one test whose fixture follows this source")
            for test in tests:
                path = SELF_TEST if test == "NativeHarvestSelfTest.swift" else TESTS / test
                if not path.exists():
                    errors.append(f"{raw}: test file {test} does not exist")
                elif not mentions(path, raw, name):
                    errors.append(f"{raw}: {test} never mentions {name}")
        if source == "unverified" and not entry.get("why"):
            errors.append(f"{raw}: say why the format could not be checked")

    for raw in agents:
        if raw not in catalog:
            errors.append(f"{raw}: in the manifest but not in the catalog")

    for error in errors:
        print(f"::error::vendor formats — {error}")
    if errors:
        return 1
    counts: dict[str, int] = {}
    for raw in catalog:
        counts[agents[raw]["source"]] = counts.get(agents[raw]["source"], 0) + 1
    summary = ", ".join(f"{counts.get(s, 0)} {s}" for s in ("repo", "docs", "unverified"))
    print(f"vendor formats OK — {len(catalog)} agents: {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
