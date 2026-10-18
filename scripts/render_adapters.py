#!/usr/bin/env python3
"""Render the two hook modules Pulse owns whole — the Pi extension and the
OpenCode plugin — from their Swift templates, without a Swift compiler.

    python3 scripts/render_adapters.py <out-dir> [--launcher /path/to/stub]

writes `<out-dir>/pi.js` and `<out-dir>/opencode.js`, exactly as
`HooksInstaller.ownedFile` renders them (`Pi.module`, `OpenCode.plugin`,
`HookModules.orderedSendFunction`), with the contract's event list.

It is a test helper (scripts/js_adapters_test.mjs), not a second source:
on macOS CI the QA driver writes the same files from the compiled code
(`PulseQA --write-adapters=<dir>`) and the job fails when the two differ.
It understands only the interpolations the templates use today and stops
on any other one, so a template change can never be rendered silently
wrong.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AGENTS = ROOT / "PulseBar" / "Sources" / "PulseKit" / "Agents"
MODULES = ROOT / "PulseBar" / "Sources" / "PulseKit" / "HookModules.swift"


def literal(text: str) -> str:
    """`HookModules.literal`: JSONEncoder with `.withoutEscapingSlashes`."""
    return json.dumps(text, ensure_ascii=False)


def multiline(source: str, start: int, raw: bool) -> tuple[str, int]:
    """The Swift multiline string literal whose opening delimiter ends at
    `start` (just after `#\"\"\"` or `\"\"\"` and its newline): its text with the
    closing delimiter's indentation removed from every line, and where the
    literal ends."""
    close = '"""#' if raw else '"""'
    body_end = source.index(close, start)
    # The closing delimiter's own line gives the indentation.
    line_start = source.rindex("\n", 0, body_end) + 1
    indent = source[line_start:body_end]
    if indent.strip():
        raise SystemExit("render_adapters: closing delimiter is not on a line of its own")
    lines = source[start:line_start].split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    out = []
    for line in lines:
        if line.strip() == "":
            out.append("")
        elif line.startswith(indent):
            out.append(line[len(indent):])
        else:
            raise SystemExit(f"render_adapters: a line is indented less than its delimiter: {line!r}")
    return "\n".join(out), body_end + len(close)


def template(path: Path, func: str, raw: bool) -> str:
    source = path.read_text(encoding="utf-8")
    m = re.search(rf"static func {func}\(", source)
    if not m:
        raise SystemExit(f"render_adapters: {path.name}: func {func} not found")
    opener = '#"""\n' if raw else '"""\n'
    start = source.index(opener, m.end()) + len(opener)
    text, _ = multiline(source, start, raw)
    return text


def events(path: Path) -> list[str]:
    code = re.sub(r"//[^\n]*", "", path.read_text(encoding="utf-8"))
    return re.findall(r'HookEvent\("([^"]+)"', code)


def kept(path: Path) -> list[str]:
    source = path.read_text(encoding="utf-8")
    m = re.search(r"static let kept = \[(.*?)\]", source, re.S)
    if not m:
        raise SystemExit("render_adapters: OpenCode.kept not found")
    return re.findall(r'"([^"]+)"', m.group(1))


def ordered_send(launcher: str, agent: str, keep: list[str]) -> str:
    text = template(MODULES, "orderedSendFunction", raw=False)
    if "\\" in text.replace("\\(", ""):
        raise SystemExit("render_adapters: orderedSendFunction has an escape this helper does not render")
    subs = {
        r"\(literal(launcher))": literal(launcher),
        r"\(kept)": ", ".join(literal(k) for k in keep),
        r"\(literal(agent))": literal(agent),
    }
    return substitute(text, subs, r"\(")


def substitute(text: str, subs: dict[str, str], marker: str) -> str:
    for key, value in subs.items():
        if key not in text:
            raise SystemExit(f"render_adapters: expected interpolation {key} is gone")
        text = text.replace(key, value)
    if marker in text:
        at = text.index(marker)
        raise SystemExit(f"render_adapters: unknown interpolation {text[at:at + 60]!r}")
    return text


def render(launcher: str) -> dict[str, str]:
    pi_file = AGENTS / "Pi.swift"
    oc_file = AGENTS / "OpenCode.swift"
    pi = substitute(template(pi_file, "module", raw=True), {
        r"\#(HookModules.literal(launcher))": literal(launcher),
        r"\#(list)": ", ".join(literal(e) for e in events(pi_file)),
    }, r"\#(")
    oc = substitute(template(oc_file, "plugin", raw=True), {
        r'\#(HookModules.orderedSendFunction(launcher: launcher, agent: "opencode", keep: kept))':
            ordered_send(launcher, "opencode", kept(oc_file)),
        r"\#(list)": ", ".join(literal(e) for e in events(oc_file)),
    }, r"\#(")
    return {"pi.js": pi, "opencode.js": oc}


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    out = Path(argv[0])
    launcher = "/tmp/pulse-hook"
    if "--launcher" in argv:
        launcher = argv[argv.index("--launcher") + 1]
    out.mkdir(parents=True, exist_ok=True)
    for name, text in render(launcher).items():
        (out / name).write_text(text, encoding="utf-8")
    print(f"rendered pi.js and opencode.js into {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
