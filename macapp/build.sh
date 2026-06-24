#!/usr/bin/env bash
# Build zero.app — a native SwiftUI menu-bar app.
# No Xcode project needed: compiles main.swift with swiftc and assembles a
# minimal .app bundle, then copies a runtime payload into Resources/.
# Output: macapp/build/zero.app
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
APP="$HERE/build/zero.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
PAYLOAD="$RES/payload"

echo "Building zero.app ..."
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

# macOS 26 (Tahoe) target: the panel uses the native SwiftUI Liquid Glass API
# (.glassEffect) on a masked vibrancy base, hosted in a native menu-bar shell.
swiftc -O \
  -target arm64-apple-macosx26.0 \
  -framework AppKit -framework SwiftUI \
  -o "$MACOS/zero" \
  "$HERE"/Sources/*.swift

cp "$HERE/Info.plist" "$APP/Contents/Info.plist"

# App icon: draw it natively (deterministic, on-brand, no external image gen),
# compile the .iconset into AppIcon.icns, and drop it in Resources.
echo "Drawing app icon ..."
ICONSET="$HERE/build/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$HERE/make_icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"

# ---------------------------------------------------------------------------
# Payload assembly — runtime code bundled for first-launch copy to
# ~/Library/Application Support/zero/
# Only explicit allowlisted paths are copied so personal data can't leak.
# ---------------------------------------------------------------------------
echo "Assembling payload ..."
mkdir -p "$PAYLOAD"

# --- lib/ (only .py / .sh; terminal --exclude='*' makes the includes actually gate) ---
mkdir -p "$PAYLOAD/lib"
rsync -a --include='*/' --include='*.py' --include='*.sh' --exclude='*' \
  "$REPO/lib/" "$PAYLOAD/lib/"

# --- bin/ ---
rsync -a "$REPO/bin/" "$PAYLOAD/bin/"

# --- top-level config and policy files ---
cp "$REPO/config.py"              "$PAYLOAD/config.py"
cp "$REPO/config.sh"              "$PAYLOAD/config.sh"
cp "$REPO/keep-policy.md"         "$PAYLOAD/keep-policy.md"
cp "$REPO/categories.json"        "$PAYLOAD/categories.json"
cp "$REPO/TRIAGE.md"              "$PAYLOAD/TRIAGE.md"
cp "$REPO/accounts.json.example"  "$PAYLOAD/accounts.json.example"

# --- knowledge/ — ONLY the generic example template, never personal profiles ---
mkdir -p "$PAYLOAD/knowledge"
cp "$REPO/knowledge/profile.example.md" "$PAYLOAD/knowledge/profile.example.md"

# ---------------------------------------------------------------------------
# Leak guard — abort if any personal/secret file crept into the payload.
# ---------------------------------------------------------------------------
echo "Running payload leak guard ..."
LEAKS="$(find "$PAYLOAD" \
  \( -name 'accounts.json' \
     -o -name 'drewl.md' \
     -o -name 'config.env' \
     -o -name '*.pyc' \
     -o -name '.DS_Store' \
  \) 2>/dev/null)"

if [ -n "$LEAKS" ]; then
  echo ""
  echo "ERROR: Personal or secret files found in payload — aborting build!"
  echo "$LEAKS"
  exit 1
fi

# Content guard: never ship a real account address. Read the addresses straight
# from the (gitignored) accounts.json at build time so no personal data is baked
# into this public script, then grep the payload for any of them.
if [ -f "$REPO/accounts.json" ]; then
  EMAILS="$(python3 -c "import json;[print(a.get('email','')) for a in json.load(open('$REPO/accounts.json'))]" 2>/dev/null | grep -E '@' || true)"
  for e in $EMAILS; do
    if grep -rIlF "$e" "$PAYLOAD" >/dev/null 2>&1; then
      echo ""
      echo "ERROR: real account address ($e) found in payload — aborting build!"
      exit 1
    fi
  done
fi
echo "  Leak guard passed."

# ---------------------------------------------------------------------------
# Ad-hoc code signature so Gatekeeper lets a locally built app run.
# ---------------------------------------------------------------------------
codesign --force --deep --sign - "$APP" 2>/dev/null || \
  echo "  (codesign skipped — app still runs locally)"

echo ""
echo "Built: $APP"
echo "Payload contents:"
ls -1 "$PAYLOAD"
echo ""
echo "Launch with:  open \"$APP\""
