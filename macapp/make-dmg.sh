#!/usr/bin/env bash
# Package zero.app into a distributable compressed DMG.
# Requires the app to already be built (run build.sh first).
# Output: macapp/build/zero.dmg
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/build"
APP="$BUILD/zero.app"
DMG="$BUILD/zero.dmg"
STAGING="$BUILD/dmg-staging"
VOLUME_NAME="zero"

# Sanity check
if [ ! -d "$APP" ]; then
  echo "ERROR: $APP not found. Run build.sh first."
  exit 1
fi

echo "Packaging $APP into $DMG ..."

# Clean up any previous run
rm -rf "$STAGING"
rm -f "$DMG"
mkdir -p "$STAGING"

# Populate staging: the app + an Applications symlink for drag-install
cp -R "$APP" "$STAGING/zero.app"
ln -s /Applications "$STAGING/Applications"

# Create a compressed, read-only DMG from the staging folder
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG"

# Clean up staging
rm -rf "$STAGING"

# Verify and report
echo ""
echo "Verifying DMG ..."
hdiutil verify "$DMG"

DMG_SIZE="$(du -sh "$DMG" | cut -f1)"
echo ""
echo "Done."
echo "  Path: $DMG"
echo "  Size: $DMG_SIZE"
