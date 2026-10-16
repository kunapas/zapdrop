#!/usr/bin/env bash
# Packages dist/Ferry.app into dist/Ferry-<version>.dmg (drag-to-Applications layout).
set -euo pipefail
source "$(dirname "$0")/config.sh"

APP="$DIST_DIR/$APP_NAME.app"
DMG="$DIST_DIR/$APP_NAME-$APP_VERSION.dmg"
[[ -d "$APP" ]] || { echo "Build the app first: Scripts/build-app.sh" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT_DIR/README.md" "$STAGE/Read Me.md"
cp "$ROOT_DIR/PRIVACY.md" "$STAGE/Privacy.md"
mkdir -p "$STAGE/Licenses"
cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$STAGE/Licenses/"
cp "$VENDOR_BUILD"/licenses/*.txt "$VENDOR_BUILD/SOURCES.txt" "$STAGE/Licenses/" 2>/dev/null || true

rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
if [[ -n "${FERRY_SIGN_IDENTITY:-}" && "${FERRY_SIGN_IDENTITY}" != "-" ]]; then
  codesign --force --timestamp --sign "$FERRY_SIGN_IDENTITY" "$DMG"
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Created $DMG"
