#!/usr/bin/env python3
"""Render the two hook modules Pulse owns whole — the Pi extension and the
OpenCode plugin — directly from their `.js` templates in `PulseKit/Agents/JS/`.

    python3 scripts/render_adapters.py <out-dir> [--launcher /path/to/stub]

writes `<out-dir>/pi.js` and `<out-dir>/opencode.js`, matching
`HooksInstaller.ownedFile` (`Pi.module`, `OpenCode.plugin`,
`HookModules.orderedSendFunction`) byte for byte. On macOS CI,
`PulseQA --write-adapters=<dir>` is diffed against this output.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AGENTS = ROOT / "PulseBar" / "Sources" / "PulseKit" / "Agents"
JS_DIR = AGENTS / "JS"


def literal(text: str) -> str:
    """`HookModules.literal`: JSONEncoder with `.withoutEscapingSlashes`."""
    return json.dumps(text, ensure_ascii=False)


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
    text = (JS_DIR / "ordered_send.js").read_text(encoding="utf-8").rstrip("\n")
    subs = {
        '/*__PULSE_HOOK__*/"/tmp/pulse-hook"': literal(launcher),
        "/*__KEEP__*/": ", ".join(literal(k) for k in keep),
        '/*__AGENT__*/"opencode"': literal(agent),
    }
    return substitute(text, subs)


def substitute(text: str, subs: dict[str, str]) -> str:
    for key, value in subs.items():
        if key not in text:
            raise SystemExit(f"render_adapters: expected placeholder {key} is missing")
        text = text.replace(key, value)
    if "/*__" in text:
        at = text.index("/*__")
        raise SystemExit(f"render_adapters: unresolved placeholder {text[at:at + 40]!r}")
    return text


def render(launcher: str) -> dict[str, str]:
    pi_file = AGENTS / "Pi.swift"
    oc_file = AGENTS / "OpenCode.swift"
    pi = substitute((JS_DIR / "pi.js").read_text(encoding="utf-8"), {
        '/*__PULSE_HOOK__*/"/tmp/pulse-hook"': literal(launcher),
        "/*__EVENTS__*/": ", ".join(literal(e) for e in events(pi_file)),
    })
    oc = substitute((JS_DIR / "opencode.js").read_text(encoding="utf-8"), {
        "/*__ORDERED_SEND__*/": ordered_send(launcher, "opencode", kept(oc_file)),
        "/*__EVENTS__*/": ", ".join(literal(e) for e in events(oc_file)),
    })
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
