#!/usr/bin/env python3
"""15.0 Witness: surfaces render values, not the store.

17.0 added the tray row's face and the Observation rules below. 22.0
removed the Workbench's Mission board and working-copy card with the
orchestrator. 23.0 replaced the cards under a row and the Why card with one
detail page (`DetailModel`) and one explanation (`Explain`), and gave the
tray header, the notice, Settings and Diagnostics a value each.

A view that reaches into StatusStore can only be seen by running the whole
app against real sessions, which is how 13.0 and 14.0 shipped surfaces
nobody had looked at. The rendering views listed here take a value
(`TrayRowModel`, `DetailModel`) and send intents; the models they render
are pure. This gate fails if either grows a store reference back, and if a
surface fixture is missing from the capture list.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "PulseBar/Sources/PulseBar"

# (file, struct) pairs that must never see the store.
VIEWS = [
    # 17.0: the tray row's face. 23.0: the header, the notice, the filter.
    ("TrayPanelViews.swift", "TrayRowFace"),
    ("TrayPanelViews.swift", "TrayHeaderFace"),
    ("TrayPanelViews.swift", "TrayNoticeFace"),
    ("TrayPanelViews.swift", "TrayFilterField"),
    # 23.0: one session in full, its plan and facts.
    ("SessionDetailView.swift", "SessionDetailFace"),
    ("SessionDetailView.swift", "PlanFace"),
    ("SessionDetailView.swift", "FactGrid"),
    # 22.0: the session's last hour.
    ("SessionDetailView.swift", "TimelineStripView"),
    ("SessionDetailView.swift", "LampShapeView"),
    # 23.0: Settings and Diagnostics render values too.
    ("SettingsViews.swift", "SettingsFace"),
    ("DiagnosticsViews.swift", "DiagnosticsFace"),
    ("DiagnosticsViews.swift", "DiagnosticsAgentRow"),
    ("DiagnosticsViews.swift", "ActivityLogView"),
    # 19.0: the self-check.
    ("DoctorViews.swift", "DoctorReportView"),
]
PURE_FILES = [
    "SurfaceFixtures.swift", "TrayRowModel.swift", "DetailModel.swift", "Explain.swift",
    "LampExplanation.swift", "DoctorModel.swift",
    # 23.0
    "LampFace.swift", "TrayModels.swift", "TrayKeys.swift", "SettingsModel.swift",
    "DiagnosticsModel.swift",
]
STORE = re.compile(r"\b(StatusStore|store|AppServices)\b")
# 19.0: the store is @Observable. A Combine-era wrapper coming back would
# silently restore whole-store invalidation for whatever view used it.
COMBINE_ERA = re.compile(r"\b(ObservableObject|@Published|@ObservedObject|@EnvironmentObject|@StateObject|objectWillChange)\b|^\s*import\s+Combine\b", re.M)
# Settings is redrawn by what it reads; a per-scan fact would redraw it
# every scan. It reads `store.settings` and a few flags, never the rows.
SCAN_FACT_FREE = [("SettingsViews.swift", re.compile(r"\bstore\.(snapshot|cachedAll)\b"))]


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
    for file in PURE_FILES:
        source = code_only((APP / file).read_text())
        if STORE.search(source):
            errors.append(f"{file}: surface models must not reach the store")
        if re.search(r"^\s*import\s+(SwiftUI|AppKit)\b", source, re.M):
            errors.append(f"{file}: surface models must not import a UI framework")
    for path in sorted(APP.glob("*.swift")):
        if COMBINE_ERA.search(code_only(path.read_text())):
            errors.append(f"{path.name}: Combine-era observation — the store is @Observable (19.0)")
    for file, pattern in SCAN_FACT_FREE:
        if pattern.search(code_only((APP / file).read_text())):
            errors.append(f"{file}: reads a per-scan fact — every scan would redraw it")
    fixtures = (APP / "SurfaceFixtures.swift").read_text()
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
