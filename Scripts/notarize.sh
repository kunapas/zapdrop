#!/usr/bin/env bash
# Notarises and staples the DMG. One-time setup (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials ferry-notary --apple-id you@example.com --team-id TEAMID
# Then: FERRY_NOTARY_PROFILE=ferry-notary Scripts/notarize.sh
set -euo pipefail
source "$(dirname "$0")/config.sh"

DMG="$DIST_DIR/$APP_NAME-$APP_VERSION.dmg"
PROFILE="${FERRY_NOTARY_PROFILE:?Set FERRY_NOTARY_PROFILE to a notarytool keychain profile}"
[[ -f "$DMG" ]] || { echo "Create the DMG first: Scripts/make-dmg.sh" >&2; exit 1; }

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Notarised: $DMG"
