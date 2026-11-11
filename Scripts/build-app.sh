#!/usr/bin/env bash
# Builds a universal Zapdrop.app with SwiftPM — the Command Line Tools are enough (no Xcode needed).
#   Scripts/build-app.sh                      ad-hoc signed app in dist/ (runs on this Mac)
#   ZAPDROP_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" Scripts/build-app.sh   release signing
#   ZAPDROP_MOCK_ONLY=1 Scripts/build-app.sh    demo build with the simulated phone only (no libmtp needed)
set -euo pipefail
source "$(dirname "$0")/config.sh"
cd "$ROOT_DIR"

IDENTITY="${ZAPDROP_SIGN_IDENTITY:--}"
MOCK="${ZAPDROP_MOCK_ONLY:-0}"
APP="$DIST_DIR/$APP_NAME.app"
ARCHS="${ZAPDROP_ARCHS:-arm64 x86_64}"

if [[ "$MOCK" != "1" && ! -f "$DEPS_PREFIX/lib/$LIBMTP_DYLIB" ]]; then
  echo "libmtp not built yet — running Scripts/build-deps.sh"
  "$ROOT_DIR/Scripts/build-deps.sh"
fi

binaries=()
for arch in $ARCHS; do
  echo "==> swift build ($arch)"
  swift build -c release --triple "$arch-apple-macosx$MIN_MACOS" --product ZapdropApp
  binaries+=("$ROOT_DIR/.build/$arch-apple-macosx/release/ZapdropApp")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
# Drop the development rpath to Vendor/ so the shipped app only looks inside its own bundle.
install_name_tool -delete_rpath "$DEPS_PREFIX/lib" "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
# …and make sure it's gone: a path into this machine's checkout must never ship.
if otool -l "$APP/Contents/MacOS/$APP_NAME" | awk '/LC_RPATH/{getline; getline; print $2}' | grep -qv '^@executable_path/'; then
  echo "error: the app still has a build-machine library path (LC_RPATH):" >&2
  otool -l "$APP/Contents/MacOS/$APP_NAME" | awk '/LC_RPATH/{getline; getline; print "  " $2}' >&2
  exit 1
fi

sed -e "s/\$(EXECUTABLE_NAME)/$APP_NAME/g" \
    -e "s/\$(PRODUCT_NAME)/$APP_NAME/g" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" \
    -e "s/\$(MARKETING_VERSION)/$APP_VERSION/g" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$APP_BUILD/g" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$MIN_MACOS/g" \
    -e "s|\$(ZAPDROP_SUPPORT_URL)|${SUPPORT_URL//&/\\&amp;}|g" \
    "$ROOT_DIR/App/Support/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
cp "$ROOT_DIR/App/Zapdrop/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns" # made by Scripts/make-icon.sh

if [[ "$MOCK" == "1" ]]; then
  ZAPDROP_MOCK_ONLY=1 "$ROOT_DIR/Scripts/embed-dylibs.sh" "$APP" "$IDENTITY"
else
  "$ROOT_DIR/Scripts/embed-dylibs.sh" "$APP" "$IDENTITY"
fi

signing=(--options runtime --timestamp)
# Ad-hoc signatures have no Team ID, so Hardened Runtime's library validation refuses the bundled dylibs.
[[ "$IDENTITY" == "-" ]] && signing=(--timestamp=none)
codesign --force "${signing[@]}" --entitlements "$ROOT_DIR/App/Support/Zapdrop.entitlements" \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
otool -L "$APP/Contents/MacOS/$APP_NAME" | grep -E "mtp|usb" || true
echo "Built $APP"
[[ "$IDENTITY" == "-" ]] && echo "Ad-hoc signed: fine on this Mac; use a Developer ID + Scripts/notarize.sh to distribute."
