#!/usr/bin/env bash
# Build + package Pulse as a menu-bar agent (LSUIElement: no Dock icon).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Version from app.zon (single package source of truth with src/version.zig).
VERSION="$(python3 - <<'PY'
import re, pathlib
text = pathlib.Path("app.zon").read_text()
m = re.search(r'\.version\s*=\s*"([^"]+)"', text)
print(m.group(1) if m else "0.0.0")
PY
)"
# Guard: Zig product version must match app.zon (enforced in tests too).
ZIG_VER="$(python3 - <<'PY'
import re, pathlib
text = pathlib.Path("src/version.zig").read_text()
m = re.search(r'semver:\s*\[\]const u8\s*=\s*"([^"]+)"', text)
print(m.group(1) if m else "")
PY
)"
if [[ -n "$ZIG_VER" && "$ZIG_VER" != "$VERSION" ]]; then
  echo "version mismatch: app.zon=$VERSION src/version.zig=$ZIG_VER" >&2
  exit 1
fi

native build
native package --target macos --signing adhoc --archive

APP="$ROOT/zig-out/package/pulse.app"
PLIST="$APP/Contents/Info.plist"

# Agent-style: status item only in the menu bar; Preferences still works.
if /usr/libexec/PlistBuddy -c "Print :LSUIElement" "$PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$PLIST"
else
  /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$PLIST"
fi
# Ensure CFBundleShortVersionString matches product semver.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$PLIST"

# Ensure tray status-light icon is in the bundle (app.zon .icons only packs AppIcon source).
ASSETS_DIR="$APP/Contents/Resources/assets"
mkdir -p "$ASSETS_DIR"
cp -f "$ROOT/assets/tray.png" "$ASSETS_DIR/tray.png"

# Re-sign after Info.plist + asset change (adhoc).
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=2 "$APP"

# native package wrote the DMG before LSUIElement; rebuild so the archive matches.
DMG="$ROOT/zig-out/package/pulse-${VERSION}-macos-ReleaseFast.dmg"
# Remove any stale archives for this version.
rm -f "$DMG" "$ROOT/zig-out/package/pulse-"*"-macos-ReleaseFast.dmg"
hdiutil create -volname "Pulse ${VERSION}" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null

echo "version:  $VERSION"
echo "packaged: $APP"
echo "archive:  $DMG"
echo "run:      open \"$APP\""
