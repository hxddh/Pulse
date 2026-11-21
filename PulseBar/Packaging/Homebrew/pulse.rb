cask "pulse" do
  version "37.0.0"
  sha256 :no_check # Each GitHub Release also ships a rendered pulse.rb with the exact DMG SHA-256

  url "https://github.com/hxddh/Pulse/releases/download/v#{version}/pulse-#{version}-macos-PulseBar.dmg"
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
