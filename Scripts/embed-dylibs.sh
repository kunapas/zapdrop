#!/usr/bin/env bash
# Copies libmtp/libusb into an app bundle's Frameworks folder and signs them.
# Used by the Xcode project (Run Script phase) and by build-app.sh.
#   embed-dylibs.sh <path/to/Ferry.app> [signing identity]   (identity defaults to ad-hoc "-")
set -euo pipefail
source "$(dirname "$0")/config.sh"

APP="${1:-${TARGET_BUILD_DIR:-}/${WRAPPER_NAME:-}}"
IDENTITY="${2:-${EXPANDED_CODE_SIGN_IDENTITY:--}}"
[[ -n "$IDENTITY" ]] || IDENTITY="-"

if [[ "${FERRY_MOCK_ONLY:-0}" == "1" ]]; then
  echo "FERRY_MOCK_ONLY=1: not embedding libmtp/libusb (demo build)."
  exit 0
fi
for lib in "$LIBUSB_DYLIB" "$LIBMTP_DYLIB"; do
  if [[ ! -f "$DEPS_PREFIX/lib/$lib" ]]; then
    echo "error: $DEPS_PREFIX/lib/$lib not found. Run Scripts/build-deps.sh first." >&2
    exit 1
  fi
done

runtime=(--options runtime)
[[ "$IDENTITY" == "-" ]] && runtime=()   # matches build-app.sh: no Hardened Runtime for ad-hoc builds

FW="$APP/Contents/Frameworks"
mkdir -p "$FW" "$APP/Contents/Resources/Licenses"
for lib in "$LIBUSB_DYLIB" "$LIBMTP_DYLIB"; do
  cp -f "$DEPS_PREFIX/lib/$lib" "$FW/$lib"
  chmod 755 "$FW/$lib"
  codesign --force --timestamp=none ${runtime[@]+"${runtime[@]}"} --sign "$IDENTITY" "$FW/$lib" >/dev/null
done
# Licence texts and the source offer travel inside the app (LGPL obligations; see THIRD_PARTY_NOTICES.md).
cp -f "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$ROOT_DIR/LICENSE" "$APP/Contents/Resources/Licenses/" 2>/dev/null || true
cp -f "$VENDOR_BUILD"/licenses/*.txt "$APP/Contents/Resources/Licenses/" 2>/dev/null || true
cp -f "$VENDOR_BUILD/SOURCES.txt" "$APP/Contents/Resources/Licenses/" 2>/dev/null || true
echo "Embedded $LIBMTP_DYLIB and $LIBUSB_DYLIB into $FW"
