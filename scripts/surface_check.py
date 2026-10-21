#!/usr/bin/env python3
"""Surfaces render values, not the store — and QA code stays out of the app.

A view that reaches into StatusStore can only be seen by running the whole
app against real sessions. The rendering views listed here take a value
(`TrayRowModel`, `DetailModel`, `SettingsModel`…) and send intents; the
models they render are pure. This gate fails if either grows a store
reference back, if a surface fixture is missing from the capture list, if
a QA file (fixtures, captures, the preview window) moves back into the app
library — the shipping app links `PulseApp`, the QA driver is `PulseQA` — if
a pure model leaves the kernel (`PulseKit`, Foundation only), if
a row's why (`L10n` `explain*` and `step*`, either language) says "hook": the
tray speaks plain words ("Asked permission · 4m ago"), or if a step string
says it is still going: a step is what a hook reported, a past step ("Bash ·
swift test · 12m ago"), never "running" / "正在" — neither in the `step*`
copy nor in the words `TrayRowModel.stepText` / `stepLine` / `nowLine`
build. The one live line ("Now: Bash · npm test · 3m", `stepNow`) has its
own word and its own path: `nowLine` is called only with the tool the agent
said started and has not finished (`facts.running`), never with a finished
step — so nothing claims a tool runs from a step that ended.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "PulseBar/Sources/PulseApp"
KIT = ROOT / "PulseBar/Sources/PulseKit"
QA = ROOT / "PulseBar/Sources/PulseQA"
# The QA driver's files. None of them may live in the app library.
QA_FILES = [
    "SurfaceFixtures.swift", "SurfaceCapture.swift", "StatusStoreFixture.swift",
    "TrayPreviewWindowController.swift", "QADriver.swift", "ProofDriver.swift",
]

# (file, struct) pairs that must never see the store.
VIEWS = [
    # The tray: a row, the header, the notice.
    ("TrayView.swift", "TrayRowFace"),
    ("TrayView.swift", "TrayHeaderFace"),
    ("TrayView.swift", "TrayNoticeFace"),
    # One session in full, its facts; the lamp's shape.
    ("SessionDetailView.swift", "SessionDetailFace"),
    ("SessionDetailView.swift", "FactGrid"),
    ("SessionDetailView.swift", "TimelineGrid"),
    ("PulseTheme.swift", "LampShapeView"),
    # Settings (its Hooks section is the diagnostics).
    ("SettingsViews.swift", "SettingsFace"),
]
# Pure models: no store, no UI framework. They live in the kernel
# (`PulseKit`, which cannot import AppKit or the store); the fixtures live in
# the QA driver.
PURE_FILES = [
    "AgentRow.swift", "TrayRowModel.swift", "TrayModels.swift", "SettingsModel.swift",
    "TrayState.swift", "WaitLedger.swift", "WaitingDelivery.swift", "SessionBook.swift",
    "L10n.swift", "Connection.swift", "TurnDigest.swift",
]
QA_PURE_FILES = ["SurfaceFixtures.swift"]
STORE = re.compile(r"\b(StatusStore|store|AppServices)\b")
# Settings is redrawn by what it reads; a per-scan fact would redraw it
# every scan. It reads `store.settings` and a few flags, never the rows.
SCAN_FACT_FREE = [("SettingsViews.swift", re.compile(r"\bstore\.(snapshot|rows)\b"))]
# A step is a past step: none of its words says it is still going.
RUNNING_WORDS = re.compile(r"running|Running|正在")


def struct_body(source: str, name: str) -> str | None:
    match = re.search(r"\bstruct\s+" + re.escape(name) + r"\b[^{]*\{", source)
    if not match:
        return None
    depth, start = 1, match.end()
    for index in range(start, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index]
    return None


def code_only(text: str) -> str:
    """Drop comments so prose may mention the store."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(line.split("//", 1)[0] for line in text.splitlines())


def main() -> int:
    errors = []
    for file, name in VIEWS:
        body = struct_body((APP / file).read_text(), name)
        if body is None:
            errors.append(f"{file}: struct {name} not found")
        elif STORE.search(code_only(body)):
            errors.append(f"{file}: {name} references the store — render a value and send intents")
    for path in sorted(KIT.rglob("*.swift")):
        if re.search(r"^\s*import\s+(SwiftUI|AppKit|UserNotifications|ServiceManagement)\b",
                     path.read_text(), re.M):
            errors.append(f"{path.name}: the kernel is Foundation only — UI and system services are PulseApp's")
    for path in [KIT / f for f in PURE_FILES] + [QA / f for f in QA_PURE_FILES]:
        file = path.name
        if not path.exists():
            errors.append(f"{file}: missing from {path.parent.name} — a pure model lives in the kernel")
            continue
        source = code_only(path.read_text())
        if STORE.search(source):
            errors.append(f"{file}: surface models must not reach the store")
        if re.search(r"^\s*import\s+(SwiftUI|AppKit)\b", source, re.M):
            errors.append(f"{file}: surface models must not import a UI framework")
    for file, pattern in SCAN_FACT_FREE:
        if pattern.search(code_only((APP / file).read_text())):
            errors.append(f"{file}: reads a per-scan fact — every scan would redraw it")
    for file in QA_FILES:
        if (APP / file).exists():
            errors.append(f"{file}: QA code is in the app library — it belongs to PulseQA")
        if not (QA / file).exists():
            errors.append(f"{file}: missing from PulseQA")
    copy = (KIT / "L10n.swift").read_text()
    # One line per key, both languages: `case .key: return ("en", "zh")`.
    string = r'"((?:[^"\\]|\\.)*)"'
    pairs = re.findall(r'case \.((?:explain|step)\w+):\s*return \(' + string + r',\s*' + string + r'\)', copy)
    whys = [(key, value) for key, en, zh in pairs for value in (en, zh)]
    if not whys:
        errors.append("L10n.swift: no explain* strings found")
    for key, value in whys:
        if "hook" in value.lower():
            errors.append(f"L10n.swift: .{key} says \"hook\" — a why is said in plain words")
    steps = [(key, value) for key, value in whys if key.startswith("step")]
    if not steps:
        errors.append("L10n.swift: no step* strings found")
    words = code_only((KIT / "TrayRowModel.swift").read_text())
    for name in ("stepText", "stepLine", "nowLine"):
        body = re.search(r"static func " + name + r"\b.*?\n    \}\n", words, re.S)
        if body is None:
            errors.append(f"TrayRowModel.swift: static func {name} not found")
        else:
            steps.append((name, body.group(0)))
    for key, value in steps:
        if RUNNING_WORDS.search(value):
            errors.append(f"{key}: a step says it is still going — a step is a past step, never \"running\" or \"正在\"")
    # The live line reads only the agent's own "started, not finished".
    calls = re.findall(r"(?<!func )\bnowLine\((\w+)", words)
    live_from_running = re.search(r"\blet\s+live\s*=\s*facts\.running\b", words)
    if not calls or any(arg != "live" for arg in calls) or not live_from_running:
        errors.append("TrayRowModel.swift: nowLine must be called only with `live`, bound from `facts.running` — never a finished step")
    fixtures = (QA / "SurfaceFixtures.swift").read_text()
    names = re.search(r"static let names = \[(.*?)\]", fixtures, re.S)
    listed = re.findall(r'"([a-z0-9-]+)"', names.group(1)) if names else []
    built = re.findall(r'Fixture\(name: "([a-z0-9-]+)"', fixtures)
    if not listed or listed != built:
        errors.append(f"SurfaceFixtures: names {listed} differ from the fixtures built {built}")
    for error in errors:
        print(f"::error::{error}")
    if errors:
        return 1
    print(f"surface check OK — {len(VIEWS)} views render values, {len(listed)} fixtures captured")
    return 0


if __name__ == "__main__":
    sys.exit(main())
