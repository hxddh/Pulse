#!/usr/bin/env python3
"""Keep the real `.js` hook module templates in `PulseKit/Agents/JS/` synced
with `PulseKit/Agents/HookModules+Generated.swift`.

Run:
    python3 scripts/sync_js_modules.py          # regenerate Swift constants
    python3 scripts/sync_js_modules.py --check  # verify sync (and JS syntax if node exists)
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AGENTS = ROOT / "PulseBar" / "Sources" / "PulseKit" / "Agents"
JS_DIR = AGENTS / "JS"
OUT = AGENTS / "HookModules+Generated.swift"

FILES = [
    ("orderedSendTemplate", JS_DIR / "ordered_send.js"),
    ("piModuleTemplate", JS_DIR / "pi.js"),
    ("openCodePluginTemplate", JS_DIR / "opencode.js"),
]


def swift_raw_literal(text: str) -> str:
    """Wrap text in a Swift raw multiline string literal with enough `#` delimiters."""
    hashes = 1
    while ('"' * 3 + "#" * hashes) in text or ("\\" + "#" * hashes) in text:
        hashes += 1
    delim = "#" * hashes
    return f'{delim}"""\n{text}"""{delim}'


def generate() -> str:
    lines = [
        "// Generated from PulseKit/Agents/JS/*.js by scripts/sync_js_modules.py.",
        "// Edit the real .js files directly, then run `python3 scripts/sync_js_modules.py`.",
        "",
        "extension HookModules {",
    ]
    for name, path in FILES:
        text = path.read_text(encoding="utf-8")
        if not text.endswith("\n"):
            text += "\n"
        lines.append(f"    package static let {name} = {swift_raw_literal(text)}")
        lines.append("")
    lines.pop()
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def check_js_syntax() -> list[str]:
    node = shutil.which("node")
    if not node:
        return []
    errors: list[str] = []
    for _, path in FILES:
        if path.name == "ordered_send.js":
            proc = subprocess.run([node, "--check", str(path)], capture_output=True, text=True)
        else:
            # ES module syntax check via stdin with --input-type=module
            proc = subprocess.run(
                [node, "--input-type=module", "--check"],
                input=path.read_text(encoding="utf-8"),
                capture_output=True,
                text=True,
            )
        if proc.returncode != 0:
            errors.append(f"{path.name}: JS syntax check failed:\n{proc.stderr.strip()}")
    return errors


def main(argv: list[str]) -> int:
    check_only = "--check" in argv
    rendered = generate()
    if check_only:
        errors = check_js_syntax()
        if not OUT.exists() or OUT.read_text(encoding="utf-8") != rendered:
            errors.append(
                f"{OUT.relative_to(ROOT)} is out of sync with PulseKit/Agents/JS/*.js — "
                "run `python3 scripts/sync_js_modules.py`"
            )
        if errors:
            for e in errors:
                print(f"::error::{e}", file=sys.stderr)
            return 1
        print(f"js modules OK — {len(FILES)} .js templates synced and valid")
        return 0
    OUT.write_text(rendered, encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
