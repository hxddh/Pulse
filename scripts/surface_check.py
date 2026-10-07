#!/usr/bin/env python3
"""Surfaces render values, not the store — and QA code stays out of the app.

A view that reaches into StatusStore can only be seen by running the whole
app against real sessions. The rendering views listed here take a value
(`TrayRowModel`, `DetailModel`, `SettingsModel`…) and send intents; the
models they render are pure. This gate fails if either grows a store
reference back, if a surface fixture is missing from the capture list, if
a QA file (fixtures, captures, the preview window) moves back into the app
library — the shipping app links `PulseApp`, the QA driver is `PulseQA` — if
a row's why (`L10n` `explain*` and `step*`, either language) says "hook": the
tray speaks plain words ("Claude asked for permission · 4m ago"), or if a
step string says it is still going: a step is what a hook reported, a past
step ("Bash · swift test · 12m ago"), never "running" / "正在" — neither in
the `step*` copy nor in the words `TrayRowModel.stepText` / `stepLine` build.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "PulseBar/Sources/PulseApp"
QA = ROOT / "PulseBar/Sources/PulseQA"
# The QA driver's files. None of them may live in the app library.
QA_FILES = [
    "SurfaceFixtures.swift", "SurfaceCapture.swift", "StatusStoreFixture.swift",
    "TrayPreviewWindowController.swift", "QADriver.swift",
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
    ("PulseTheme.swift", "LampShapeView"),
    # Settings (its Hooks section is the diagnostics).
    ("SettingsViews.swift", "SettingsFace"),
]
# Pure models: no store, no UI framework. Paths are relative to APP, except
# the fixtures, which live in the QA driver.
PURE_FILES = [
    "Models.swift", "TrayRowModel.swift", "TrayModels.swift", "SettingsModel.swift",
    "TrayState.swift", "WaitLedger.swift", "WaitingDelivery.swift",
]
QA_PURE_FILES = ["SurfaceFixtures.swift"]
STORE = re.compile(r"\b(StatusStore|store|AppServices)\b")
# The store is @Observable. A Combine-era wrapper coming back would
# silently restore whole-store invalidation for whatever view used it.
COMBINE_ERA = re.compile(r"\b(ObservableObject|@Published|@ObservedObject|@EnvironmentObject|@StateObject|objectWillChange)\b|^\s*import\s+Combine\b", re.M)
# Settings is redrawn by what it reads; a per-scan fact would redraw it
# every scan. It reads `store.settings` and a few flags, never the rows.
SCAN_FACT_FREE = [("SettingsViews.swift", re.compile(r"\bstore\.(snapshot|cachedAll)\b"))]
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
    for path in [APP / f for f in PURE_FILES] + [QA / f for f in QA_PURE_FILES]:
        file = path.name
        source = code_only(path.read_text())
        if STORE.search(source):
            errors.append(f"{file}: surface models must not reach the store")
        if re.search(r"^\s*import\s+(SwiftUI|AppKit)\b", source, re.M):
            errors.append(f"{file}: surface models must not import a UI framework")
    for path in sorted(list(APP.glob("*.swift")) + list(QA.glob("*.swift"))):
        if COMBINE_ERA.search(code_only(path.read_text())):
            errors.append(f"{path.name}: Combine-era observation — the store is @Observable")
    for file, pattern in SCAN_FACT_FREE:
        if pattern.search(code_only((APP / file).read_text())):
            errors.append(f"{file}: reads a per-scan fact — every scan would redraw it")
    for file in QA_FILES:
        if (APP / file).exists():
            errors.append(f"{file}: QA code is in the app library — it belongs to PulseQA")
        if not (QA / file).exists():
            errors.append(f"{file}: missing from PulseQA")
    copy = (APP / "L10n.swift").read_text()
    whys = re.findall(r'case \.((?:explain|step)\w+):\s*return "((?:[^"\\]|\\.)*)"', copy)
    if not whys:
        errors.append("L10n.swift: no explain* strings found")
    for key, value in whys:
        if "hook" in value.lower():
            errors.append(f"L10n.swift: .{key} says \"hook\" — a why is said in plain words")
    steps = [(key, value) for key, value in whys if key.startswith("step")]
    if not steps:
        errors.append("L10n.swift: no step* strings found")
    words = code_only((APP / "TrayRowModel.swift").read_text())
    for name in ("stepText", "stepLine"):
        body = re.search(r"static func " + name + r"\b.*?\n    \}\n", words, re.S)
        if body is None:
            errors.append(f"TrayRowModel.swift: static func {name} not found")
        else:
            steps.append((name, body.group(0)))
    for key, value in steps:
        if RUNNING_WORDS.search(value):
            errors.append(f"{key}: a step says it is still going — a step is a past step, never \"running\" or \"正在\"")
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
