#!/usr/bin/env bash
# Build + package PulseBar (Swift MenuBarExtra shell) as Pulse.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT/PulseBar"

VERSION="$(python3 - <<'PY'
import re, pathlib
p = pathlib.Path("Sources/PulseBar/Models.swift")
text = p.read_text()
m = re.search(r'static let semver = "([^"]+)"', text)
print(m.group(1) if m else "0.0.0")
PY
)"

# Single source of truth: src/*.py → SPM Resources (avoid stale Bundle seed).
for py in activity_scan.py pulse_hook.py install_hooks.py; do
  cp "$ROOT/src/$py" "$ROOT/PulseBar/Sources/PulseBar/Resources/$py"
done

python3 "$ROOT/scripts/coverage_check.py"

echo "building PulseBar ${VERSION}..."
swift build -c release

BIN="$(swift build -c release --show-bin-path)/PulseBar"
APP="$ROOT/zig-out/package/Pulse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/PulseBar"
# Bundle harvest + hook scripts for runtime fallbacks.
for py in activity_scan.py pulse_hook.py install_hooks.py; do
  cp "$ROOT/src/$py" "$APP/Contents/Resources/$py"
done
# Brand marks (template PNGs + SVG sources)
if [[ -d "$ROOT/PulseBar/Sources/PulseBar/Resources/AgentIcons" ]]; then
  rm -rf "$APP/Contents/Resources/AgentIcons"
  cp -R "$ROOT/PulseBar/Sources/PulseBar/Resources/AgentIcons" "$APP/Contents/Resources/AgentIcons"
fi
if [[ -d "$ROOT/PulseBar/Sources/PulseBar/Resources/Brand" ]]; then
  rm -rf "$APP/Contents/Resources/Brand"
  cp -R "$ROOT/PulseBar/Sources/PulseBar/Resources/Brand" "$APP/Contents/Resources/Brand"
  if [[ -f "$ROOT/PulseBar/Sources/PulseBar/Resources/Brand/AppIcon.icns" ]]; then
    cp "$ROOT/PulseBar/Sources/PulseBar/Resources/Brand/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  fi
fi
# Copy SPM resource bundle if present (Bundle.module).
RES_BUNDLE="$(dirname "$BIN")/PulseBar_PulseBar.bundle"
if [[ -d "$RES_BUNDLE" ]]; then
  cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
fi

# Also place py where Bundle.module relative lookups may resolve in packaged apps.
mkdir -p "$APP/Contents/Resources/PulseBar_PulseBar.bundle/Contents/Resources" 2>/dev/null || true
for py in activity_scan.py pulse_hook.py install_hooks.py; do
  cp "$ROOT/src/$py" "$APP/Contents/Resources/PulseBar_PulseBar.bundle/Contents/Resources/$py" 2>/dev/null || true
done
if [[ -d "$ROOT/PulseBar/Sources/PulseBar/Resources/AgentIcons" ]]; then
  rm -rf "$APP/Contents/Resources/PulseBar_PulseBar.bundle/Contents/Resources/AgentIcons"
  cp -R "$ROOT/PulseBar/Sources/PulseBar/Resources/AgentIcons" \
    "$APP/Contents/Resources/PulseBar_PulseBar.bundle/Contents/Resources/AgentIcons" 2>/dev/null || true
fi
if [[ -d "$ROOT/PulseBar/Sources/PulseBar/Resources/Brand" ]]; then
  rm -rf "$APP/Contents/Resources/PulseBar_PulseBar.bundle/Contents/Resources/Brand"
  cp -R "$ROOT/PulseBar/Sources/PulseBar/Resources/Brand" \
    "$APP/Contents/Resources/PulseBar_PulseBar.bundle/Contents/Resources/Brand" 2>/dev/null || true
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>PulseBar</string>
  <key>CFBundleIdentifier</key><string>com.pulse.app</string>
  <key>CFBundleName</key><string>Pulse</string>
  <key>CFBundleDisplayName</key><string>Pulse</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
codesign --verify --verbose=2 "$APP"

DMG="$ROOT/zig-out/package/pulse-${VERSION}-macos-PulseBar.dmg"
rm -f "$DMG"
hdiutil create -volname "Pulse ${VERSION}" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null

echo "version:  ${VERSION}"
echo "packaged: ${APP}"
echo "archive:  ${DMG}"
echo "run:      open \"${APP}\""
