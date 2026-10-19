#!/usr/bin/env bash
# Single place for names, versions and pinned dependency commits.
# shellcheck disable=SC2034

APP_NAME="Zapdrop"
BUNDLE_ID="${FERRY_BUNDLE_ID:-io.github.zapdrop.Zapdrop}"   # change before publishing
APP_VERSION="0.1.0"
APP_BUILD="1"
MIN_MACOS="14.0"

# Pinned sources (LGPL-2.1-or-later). Tags are resolved and checked against these exact commits.
LIBUSB_REPO="https://github.com/libusb/libusb"
LIBUSB_TAG="v1.0.30"
LIBUSB_COMMIT="87a55632db62c9bdc58cd31d3ccfa673f1bb017f"

LIBMTP_REPO="https://github.com/libmtp/libmtp"
LIBMTP_TAG="v1.1.23"
LIBMTP_COMMIT="55fa074240b703adb48c78d31d156879cb9e4959"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_SRC="$ROOT_DIR/Vendor/src"
VENDOR_BUILD="$ROOT_DIR/Vendor/build"
DEPS_PREFIX="${FERRY_DEPS_PREFIX:-$VENDOR_BUILD/prefix}"
DIST_DIR="$ROOT_DIR/dist"

LIBUSB_DYLIB="libusb-1.0.0.dylib"
LIBMTP_DYLIB="libmtp.9.dylib"
