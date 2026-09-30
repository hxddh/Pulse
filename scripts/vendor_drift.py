#!/usr/bin/env python3
"""Drift sentinel: has a vendor changed the files its hooks live in?

For every ``source: "repo"`` hooks block in docs/vendor-formats.json (only
each agent's hook contract is kept; Pulse reads no vendor file) this makes a
blob-less clone of the vendor repository (history only, no file contents)
and lists the commits since the pinned one that touched a ``watch`` path.
Any such commit fails the run and is printed — vendor, path, commit, date,
subject — so the weekly job goes red exactly when a hook contract may have gone
stale. It never edits anything: it reads public repositories and prints.

A changed file is not proof the contract changed. The fix is to read the
commits, update the receiver and its test if needed, and move the pin.

Run: python3 scripts/vendor_drift.py [--only gemini,codex] [--workdir DIR]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "docs" / "vendor-formats.json"


def git(*args: str, cwd: Path | None = None) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True, timeout=600
    ).stdout


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", default="")
    parser.add_argument("--workdir", default="")
    options = parser.parse_args()
    only = {item for item in options.only.split(",") if item}

    agents = json.loads(MANIFEST.read_text(encoding="utf-8"))["agents"]
    work = Path(options.workdir or tempfile.mkdtemp(prefix="vendor-drift-"))
    work.mkdir(parents=True, exist_ok=True)

    drifted: list[str] = []
    failed: list[str] = []
    clones: dict[str, Path] = {}
    # Only the hook contract is pinned.
    pins = [(f"{raw} hooks", entry["hooks"]) for raw, entry in sorted(agents.items())
            if isinstance(entry.get("hooks"), dict)]
    for raw, entry in pins:
        if entry.get("source") != "repo" or (only and raw.split()[0] not in only):
            continue
        repo, pin, watch = entry["repo"], entry["commit"], entry["watch"]
        try:
            if repo not in clones:
                target = work / repo.rstrip("/").split("/")[-2] / repo.rstrip("/").split("/")[-1]
                if not target.exists():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    git("clone", "--quiet", "--filter=blob:none", "--no-checkout", repo, str(target))
                clones[repo] = target
            clone = clones[repo]
            log = git("log", "--format=%h %cs %s", f"{pin}..HEAD", "--", *watch, cwd=clone).strip()
        except subprocess.CalledProcessError as error:
            failed.append(f"{raw}: {repo} — {error.stderr.strip() or error}")
            continue
        except subprocess.TimeoutExpired:
            failed.append(f"{raw}: {repo} — timed out")
            continue
        if log:
            lines = log.splitlines()
            drifted.append(raw)
            print(f"::warning::{raw}: {len(lines)} commit(s) since {pin[:12]} touch its hook files")
            for line in lines[:20]:
                print(f"    {line}")
            if len(lines) > 20:
                print(f"    … {len(lines) - 20} more")
        else:
            print(f"{raw}: unchanged since {pin[:12]}")

    for failure in failed:
        print(f"::error::could not check {failure}")
    if drifted:
        print(f"::error::hook files moved for: {', '.join(drifted)} — read the commits, fix the receiver and test, move the pin")
    return 1 if drifted or failed else 0


if __name__ == "__main__":
    sys.exit(main())
