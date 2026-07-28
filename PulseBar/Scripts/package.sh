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

python3 "$ROOT/scripts/version_check.py"
python3 "$ROOT/scripts/coverage_check.py"
python3 "$ROOT/scripts/matrix_check.py"
python3 "$ROOT/scripts/make_agent_icons.py" --check
python3 "$ROOT/scripts/appearance_check.py"

# Build identity stamped into Info.plist — PulseVersion reads it at runtime.
GIT_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git -C "$ROOT" diff --quiet HEAD 2>/dev/null; then
  GIT_COMMIT="${GIT_COMMIT}+"
fi
BUILD_DATE="$(date -u +%Y-%m-%d)"

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
# SwiftPM resource bundle. This is not optional: the app resolves icons and the
# bundled Python through it, so shipping without it ships a broken app.
#
# The bundle SwiftPM builds is *flat* — Info.plist and the resource directories
# sit at its root, with no Contents/. Do not "helpfully" add Contents/Resources
# inside it: CFBundle switches to the modern layout the moment it sees a
# Contents/ directory, stops looking at the root, and — with no
# Contents/Info.plist to find — refuses to open the bundle at all. Every release
# up to 0.23.0 did exactly that, and the app died on launch.
RES_BUNDLE="$(dirname "$BIN")/PulseBar_PulseBar.bundle"
if [[ ! -d "$RES_BUNDLE" ]]; then
  echo "error: SwiftPM resource bundle missing at $RES_BUNDLE" >&2
  echo "       the packaged app cannot resolve its resources without it" >&2
  exit 1
fi
rm -rf "$APP/Contents/Resources/PulseBar_PulseBar.bundle"
cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"

# A bundle directory without an Info.plist is not a bundle — Bundle(url:)
# returns nil and the compiler-generated Bundle.module accessor calls
# fatalError(). SwiftPM usually writes one; make sure, rather than find out
# from a crash report.
BUNDLE_PLIST="$APP/Contents/Resources/PulseBar_PulseBar.bundle/Info.plist"
if [[ ! -f "$BUNDLE_PLIST" ]]; then
  echo "note: SwiftPM emitted no Info.plist for the resource bundle — writing one"
  cat > "$BUNDLE_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.pulse.app.resources</string>
  <key>CFBundleName</key><string>PulseBar_PulseBar</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
</dict>
</plist>
PLIST
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
  <key>PulseGitCommit</key><string>${GIT_COMMIT}</string>
  <key>PulseBuildDate</key><string>${BUILD_DATE}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# The app is assembled — check it can find its own resources before we sign it
# into a DMG. Source-level gates cannot see this: every release up to 0.23.0
# passed all of them and still crashed on launch.
python3 "$ROOT/scripts/package_check.py" "$APP"

# And then ask the app itself, which is the only check that does not depend on
# our own assumptions about where the runtime looks. Runs the real binary from
# inside the real bundle; --selftest returns before AppKit starts, so this
# works headless.
echo "running --selftest inside the packaged app..."
"$APP/Contents/MacOS/PulseBar" --selftest

# Signing. Ad-hoc (`-`) is fine for local use but Gatekeeper blocks the DMG on
# any other Mac. Set these to produce something actually distributable:
#   PULSE_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
#   PULSE_NOTARY_PROFILE=<notarytool keychain profile>   # optional
SIGN_IDENTITY="${PULSE_SIGN_IDENTITY:--}"
# `--deep` is deprecated by Apple; sign nested code first, then the bundle.
find "$APP/Contents" -type f -perm +111 -not -path "*/MacOS/PulseBar" -print0 2>/dev/null \
  | xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" {} 2>/dev/null || true
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
  echo "warning:  ad-hoc signed — Gatekeeper will block this on other Macs."
  echo "          set PULSE_SIGN_IDENTITY to a Developer ID to distribute."
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --verbose=2 "$APP"

DMG="$ROOT/zig-out/package/pulse-${VERSION}-macos-PulseBar.dmg"
rm -f "$DMG"
hdiutil create -volname "Pulse ${VERSION}" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null

if [[ -n "${PULSE_NOTARY_PROFILE:-}" && "$SIGN_IDENTITY" != "-" ]]; then
  echo "notarizing ${DMG}..."
  xcrun notarytool submit "$DMG" --keychain-profile "$PULSE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "notarized: stapled ticket attached"
fi

echo "version:  ${VERSION} (${GIT_COMMIT} · ${BUILD_DATE})"
echo "packaged: ${APP}"
echo "archive:  ${DMG}"
echo "run:      open \"${APP}\""
