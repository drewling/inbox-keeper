#!/usr/bin/env bash
# Build inbox-keeper.app — a tiny native menu-bar shell around the web panel.
# No Xcode project needed: compiles main.swift with swiftc and assembles a
# minimal .app bundle. Output: macapp/build/inbox-keeper.app
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HERE/build/inbox-keeper.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

echo "Building inbox-keeper.app ..."
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

# macOS 26 (Tahoe) target: the panel uses the real Liquid Glass API
# (NSGlassEffectView) and SwiftUI, hosted in a native menu-bar shell.
swiftc -O \
  -target arm64-apple-macosx26.0 \
  -framework AppKit -framework SwiftUI \
  -o "$MACOS/inbox-keeper" \
  "$HERE"/Sources/*.swift

cp "$HERE/Info.plist" "$APP/Contents/Info.plist"

# App icon: draw it natively (deterministic, on-brand, no external image gen),
# compile the .iconset into AppIcon.icns, and drop it in Resources.
echo "Drawing app icon ..."
ICONSET="$HERE/build/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$HERE/make_icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"

# Ad-hoc code signature so Gatekeeper lets a locally built app run.
codesign --force --deep --sign - "$APP" 2>/dev/null || \
  echo "  (codesign skipped — app still runs locally)"

echo "Built: $APP"
echo "Launch with:  open \"$APP\""
