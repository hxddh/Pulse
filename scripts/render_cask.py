#!/usr/bin/env python3
"""Render a Homebrew Cask formula (`pulse.rb`) for a concrete release version
and DMG SHA-256 digest.

Usage:
    python3 scripts/render_cask.py <version> <sha256> <output-path>
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

TEMPLATE = """cask "pulse" do
  version "{version}"
  sha256 "{sha256}"

  url "https://github.com/hxddh/Pulse/releases/download/v#{{version}}/pulse-#{{version}}-macos-PulseBar.dmg"
  name "Pulse"
  desc "Quiet macOS menu-bar lamp for coding agents (Claude Code, Codex, Cursor, Pi, Copilot, OpenCode)"
  homepage "https://github.com/hxddh/Pulse"

  depends_on macos: ">= :sonoma"

  app "Pulse.app"

  zap trash: [
    "~/Library/Application Support/Pulse",
  ]

  caveats <<~EOS
    Preview builds are ad-hoc signed (not notarized). If macOS Gatekeeper blocks the first launch:
      xattr -dr com.apple.quarantine /Applications/Pulse.app
  EOS
end
"""


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    _, version, sha256, out_path = argv
    if not re.match(r"^\d+\.\d+\.\d+$", version):
        print(f"error: invalid semver {version!r}", file=sys.stderr)
        return 1
    if not re.match(r"^[0-9a-f]{64}$", sha256):
        print(f"error: invalid sha256 {sha256!r}", file=sys.stderr)
        return 1
    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(TEMPLATE.format(version=version, sha256=sha256), encoding="utf-8")
    print(f"rendered {out} ({version}, {sha256[:12]}…)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
