#!/usr/bin/env bash
# Build + package the PulseBar executable (the app, and only the app) as Pulse.app.
# `PulseQA` — the QA driver with its fixtures and captures — is never built
# here and never shipped; `scripts/package_check.py` checks the binary for it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT/PulseBar"

VERSION="$(sed -n 's/.*static let semver = "\([^"]*\)".*/\1/p' Sources/PulseApp/Models.swift | head -1)"
VERSION="${VERSION:-0.0.0}"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "error: Pulse 0.48+ is built for Apple silicon (arm64); found $(uname -m)" >&2
  exit 1
fi

CHECK_PYTHON="$(command -v python3 || true)"
if [[ -n "$CHECK_PYTHON" ]]; then
  bash "$ROOT/scripts/gates.sh"
else
  # Python is an optional legacy/verification tool. The application and the
  # release artifact must still be buildable on a clean Swift-only machine;
  # the packaged Swift selftest below remains mandatory.
  echo "note: python3 unavailable — optional Python source gates skipped"
fi

# Build identity stamped into Info.plist — PulseVersion reads it at runtime.
GIT_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git -C "$ROOT" diff --quiet HEAD 2>/dev/null; then
  GIT_COMMIT="${GIT_COMMIT}+"
fi
BUILD_DATE="$(date -u +%Y-%m-%d)"
# Every build starts as `preview`; only a notarization that stapler validates
# upgrades it to `stable`. Never stamp "stable" earlier — that mislabels a
# build Gatekeeper blocks.
SIGN_IDENTITY="${PULSE_SIGN_IDENTITY:--}"
NOTARY_PROFILE="${PULSE_NOTARY_PROFILE:-}"
PULSE_NOTARIZED="false"
DISTRIBUTION_CHANNEL="preview"

echo "building PulseBar ${VERSION}..."
# The product, not the package: a plain `swift build -c release` would also
# build `PulseQA`, which reaches the app's internals through `@testable
# import` and only builds in the debug configuration.
swift build -c release --product PulseBar

BIN="$(swift build -c release --product PulseBar --show-bin-path)/PulseBar"
APP="$ROOT/zig-out/package/Pulse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/PulseBar"
# The Finder / Dock icon (CFBundleIconFile). Everything the app draws at
# runtime — the agent marks, the brand mark — lives in the SwiftPM resource
# bundle below and is found through PulseResources.
cp "$ROOT/PulseBar/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundle. This is not optional: the app resolves its icons
# through it, so shipping without it ships a broken app.
#
# The bundle SwiftPM builds is *flat* — Info.plist and the resource directories
# sit at its root, with no Contents/. Do not "helpfully" add Contents/Resources
# inside it: CFBundle switches to the modern layout the moment it sees a
# Contents/ directory, stops looking at the root, and — with no
# Contents/Info.plist to find — refuses to open the bundle at all, and the app
# dies on launch.
RES_BUNDLE="$(dirname "$BIN")/PulseBar_PulseApp.bundle"
if [[ ! -d "$RES_BUNDLE" ]]; then
  echo "error: SwiftPM resource bundle missing at $RES_BUNDLE" >&2
  echo "       the packaged app cannot resolve its resources without it" >&2
  exit 1
fi
rm -rf "$APP/Contents/Resources/PulseBar_PulseApp.bundle"
cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"

# A bundle directory without an Info.plist is not a bundle — Bundle(url:)
# returns nil and the compiler-generated Bundle.module accessor calls
# fatalError(). SwiftPM usually writes one; make sure, rather than find out
# from a crash report.
BUNDLE_PLIST="$APP/Contents/Resources/PulseBar_PulseApp.bundle/Info.plist"
if [[ ! -f "$BUNDLE_PLIST" ]]; then
  echo "note: SwiftPM emitted no Info.plist for the resource bundle — writing one"
  cat > "$BUNDLE_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.pulse.app.resources</string>
  <key>CFBundleName</key><string>PulseBar_PulseApp</string>
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
  <key>PulseDistributionChannel</key><string>${DISTRIBUTION_CHANNEL}</string>
  <key>PulseNotarized</key><string>${PULSE_NOTARIZED}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# The app is assembled — check it can find its own resources before we sign it
# into a DMG. Source-level gates cannot see this: a bundle can pass all of them
# and still crash on launch.
if [[ -n "$CHECK_PYTHON" ]]; then
  "$CHECK_PYTHON" "$ROOT/scripts/package_check.py" "$APP"
else
  test -x "$APP/Contents/MacOS/PulseBar"
  test -f "$APP/Contents/Info.plist"
  test -d "$APP/Contents/Resources/PulseBar_PulseApp.bundle"
  test -f "$APP/Contents/Resources/PulseBar_PulseApp.bundle/Info.plist"
  echo "package structure OK — Python package_check skipped"
fi

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
# `--deep` is deprecated by Apple; sign nested code first, then the bundle.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  find "$APP/Contents" -type f -perm +111 -not -path "*/MacOS/PulseBar" -print0 2>/dev/null \
    | xargs -0 -I{} codesign --force --options runtime --sign - {}
  codesign --force --options runtime --sign - "$APP"
  echo "warning:  ad-hoc signed — Gatekeeper will block this on other Macs."
  echo "          set PULSE_SIGN_IDENTITY to a Developer ID to distribute."
else
  if ! security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
    echo "error: signing identity is not present in the active keychains: $SIGN_IDENTITY" >&2
    exit 1
  fi
  find "$APP/Contents" -type f -perm +111 -not -path "*/MacOS/PulseBar" -print0 2>/dev/null \
    | xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" {}
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ -n "$NOTARY_PROFILE" && "$SIGN_IDENTITY" == "-" ]]; then
  echo "error: notarization requires a Developer ID signature" >&2
  exit 1
fi

# Notarize and staple the app itself before putting it in the DMG. Submitting
# only the DMG can pass Gatekeeper online but leaves the installed app without
# an offline ticket.
if [[ -n "$NOTARY_PROFILE" ]]; then
  APP_ZIP="$ROOT/zig-out/package/pulse-${VERSION}-notary.zip"
  rm -f "$APP_ZIP"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  echo "notarizing ${APP}..."
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl -a -vv --type execute "$APP"
  rm -f "$APP_ZIP"
  # Upgrade the channel only after stapler validates.
  DISTRIBUTION_CHANNEL="stable"
  PULSE_NOTARIZED="true"
  /usr/libexec/PlistBuddy -c "Set :PulseDistributionChannel ${DISTRIBUTION_CHANNEL}" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :PulseNotarized ${PULSE_NOTARIZED}" "$APP/Contents/Info.plist" \
    || /usr/libexec/PlistBuddy -c "Add :PulseNotarized string ${PULSE_NOTARIZED}" "$APP/Contents/Info.plist"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
fi

DMG="$ROOT/zig-out/package/pulse-${VERSION}-macos-PulseBar.dmg"
rm -f "$DMG"
# Keep the first-launch explanation next to the app in the DMG only when the
# build is not Gatekeeper-ready. A notarized stable build must not ship the
# ad-hoc recovery guide — that would contradict the channel stamp.
STAGE="$ROOT/zig-out/package/.pulse-dmg-staging"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Pulse.app"
if [[ "$PULSE_NOTARIZED" != "true" ]]; then
  GUIDE="$ROOT/zig-out/package/Pulse-${VERSION}-首次打开.txt"
  cat > "$GUIDE" <<TXT
Pulse ${VERSION} · 首次打开 / First launch

当前版本为 ${DISTRIBUTION_CHANNEL} 通道构建（未公证）。macOS 首次打开会拦截它，这是
Gatekeeper 的信任策略，不是 Pulse 运行时崩溃。请只对 Pulse 做一次明确放行：

1. 将 Pulse.app 拖入“应用程序”，双击打开一次；macOS 提示无法验证时点“完成”。
2. 打开 系统设置 → 隐私与安全性，滚动到“安全性”，点 Pulse 旁边的“仍要打开”，
   再输入密码确认。

或者在“终端”里，确认路径正确后，仅移除 Pulse 自己的下载隔离标记：
  xattr -dr com.apple.quarantine /Applications/Pulse.app

macOS 15 起，按住 Control 点“打开”不再能放行未公证的 App。
不要关闭“允许从以下位置下载的 App”或全局禁用 Gatekeeper。
需要 macOS 14 或更高版本；当前构建面向 Apple silicon（arm64）。

English: this DMG is channel=${DISTRIBUTION_CHANNEL} and not notarized. Drag Pulse to
Applications and open it once; when macOS blocks it, go to System Settings →
Privacy & Security, scroll to Security and click "Open Anyway". Or, in Terminal:
  xattr -dr com.apple.quarantine /Applications/Pulse.app
(macOS 15 removed the Control-click → Open shortcut.) Developer ID + notarization
removes this step.
TXT
  cp "$GUIDE" "$STAGE/"
fi
hdiutil create -volname "Pulse ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ -n "$NOTARY_PROFILE" ]]; then
  echo "notarizing ${DMG}..."
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -vv -t open --context context:primary-signature "$DMG"
  echo "notarized: app + DMG tickets stapled and Gatekeeper accepted"
fi

echo "version:  ${VERSION} (${GIT_COMMIT} · ${BUILD_DATE})"
echo "channel:  ${DISTRIBUTION_CHANNEL} (notarized=${PULSE_NOTARIZED})"
echo "packaged: ${APP}"
echo "archive:  ${DMG}"
echo "run:      open \"${APP}\""
