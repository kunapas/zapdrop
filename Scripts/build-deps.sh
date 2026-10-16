#!/usr/bin/env bash
# Builds libusb and libmtp from pinned source as universal (arm64 + x86_64) dylibs with @rpath install names.
# Output: Vendor/build/prefix/{include,lib}, Vendor/build/licenses, Vendor/build/SOURCES.txt
# Needs (build machine only, never end users): Xcode or Command Line Tools, and
#   brew install autoconf automake libtool pkg-config gettext
set -euo pipefail
source "$(dirname "$0")/config.sh"

[[ "$(uname)" == "Darwin" ]] || { echo "build-deps.sh builds macOS libraries; run it on a Mac." >&2; exit 1; }
missing=()
command -v autoreconf >/dev/null || missing+=(autoconf)
command -v automake >/dev/null || missing+=(automake)
command -v glibtoolize >/dev/null || command -v libtoolize >/dev/null || missing+=(libtool)
command -v pkg-config >/dev/null || missing+=(pkg-config)
command -v autopoint >/dev/null || [[ -x "$(brew --prefix gettext 2>/dev/null)/bin/autopoint" ]] || missing+=(gettext)
if (( ${#missing[@]} )); then
  echo "Missing build tools: ${missing[*]}" >&2
  echo "Install with: brew install ${missing[*]}" >&2
  exit 1
fi

fetch() { # repo tag commit dir
  local repo=$1 tag=$2 commit=$3 dir=$4
  if [[ ! -d "$dir/.git" ]]; then
    git clone --quiet --depth 1 --branch "$tag" "$repo" "$dir"
  fi
  local actual
  actual=$(git -C "$dir" rev-parse HEAD)
  if [[ "$actual" != "$commit" ]]; then
    echo "Commit mismatch for $repo $tag: expected $commit, got $actual" >&2
    exit 1
  fi
}

mkdir -p "$VENDOR_SRC" "$VENDOR_BUILD"
fetch "$LIBUSB_REPO" "$LIBUSB_TAG" "$LIBUSB_COMMIT" "$VENDOR_SRC/libusb"
fetch "$LIBMTP_REPO" "$LIBMTP_TAG" "$LIBMTP_COMMIT" "$VENDOR_SRC/libmtp"

JOBS=$(sysctl -n hw.ncpu)
SDK=$(xcrun --sdk macosx --show-sdk-path)

build_arch() {
  local arch=$1 host=$2
  local prefix="$VENDOR_BUILD/$arch"
  local flags="-arch $arch -mmacosx-version-min=$MIN_MACOS -isysroot $SDK -O2"
  rm -rf "$prefix" "$VENDOR_BUILD/work-$arch"
  mkdir -p "$VENDOR_BUILD/work-$arch"
  cp -R "$VENDOR_SRC/libusb" "$VENDOR_BUILD/work-$arch/libusb"
  cp -R "$VENDOR_SRC/libmtp" "$VENDOR_BUILD/work-$arch/libmtp"

  echo "==> libusb ($arch)"
  ( cd "$VENDOR_BUILD/work-$arch/libusb"
    ./bootstrap.sh >/dev/null
    ./configure --quiet --host="$host" --prefix="$prefix" --disable-static --enable-shared \
      CFLAGS="$flags" LDFLAGS="$flags -Wl,-headerpad_max_install_names"
    make -j"$JOBS" >/dev/null
    make install >/dev/null )

  echo "==> libmtp ($arch)"
  ( cd "$VENDOR_BUILD/work-$arch/libmtp"
    ./autogen.sh >/dev/null 2>&1
    PKG_CONFIG_PATH="$prefix/lib/pkgconfig" PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" \
    ./configure --quiet --host="$host" --prefix="$prefix" --disable-static --enable-shared \
      --disable-mtpz --disable-doxygen \
      CFLAGS="$flags" LDFLAGS="$flags -Wl,-headerpad_max_install_names"
    make -j"$JOBS" -C src >/dev/null
    make -C src install >/dev/null
    make install-pkgconfigDATA >/dev/null )
}

build_arch arm64 aarch64-apple-darwin
build_arch x86_64 x86_64-apple-darwin

echo "==> universal"
OUT="$DEPS_PREFIX"
rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"
cp -R "$VENDOR_BUILD/arm64/include/." "$OUT/include/"
for lib in "$LIBUSB_DYLIB" "$LIBMTP_DYLIB"; do
  lipo -create "$VENDOR_BUILD/arm64/lib/$lib" "$VENDOR_BUILD/x86_64/lib/$lib" -output "$OUT/lib/$lib"
done
# @rpath install names so the app finds them in Contents/Frameworks.
install_name_tool -id "@rpath/$LIBUSB_DYLIB" "$OUT/lib/$LIBUSB_DYLIB"
install_name_tool -id "@rpath/$LIBMTP_DYLIB" "$OUT/lib/$LIBMTP_DYLIB"
for arch in arm64 x86_64; do
  install_name_tool -change "$VENDOR_BUILD/$arch/lib/$LIBUSB_DYLIB" "@rpath/$LIBUSB_DYLIB" "$OUT/lib/$LIBMTP_DYLIB" 2>/dev/null || true
done
# install_name_tool invalidates signatures; Apple Silicon refuses to load unsigned code, so re-sign ad hoc.
# (Release signing with a Developer ID happens later, in embed-dylibs.sh.)
codesign --force --sign - "$OUT/lib/$LIBUSB_DYLIB" "$OUT/lib/$LIBMTP_DYLIB"
ln -sf "$LIBUSB_DYLIB" "$OUT/lib/libusb-1.0.dylib"
ln -sf "$LIBMTP_DYLIB" "$OUT/lib/libmtp.dylib"

# Verify: universal, @rpath ids, no absolute build paths left.
for lib in "$LIBUSB_DYLIB" "$LIBMTP_DYLIB"; do
  lipo -info "$OUT/lib/$lib"
  if otool -L "$OUT/lib/$lib" | tail -n +2 | grep -q "$VENDOR_BUILD"; then
    echo "error: $lib still references the build directory:" >&2
    otool -L "$OUT/lib/$lib" >&2
    exit 1
  fi
done

mkdir -p "$VENDOR_BUILD/licenses"
cp "$VENDOR_SRC/libusb/COPYING" "$VENDOR_BUILD/licenses/libusb-COPYING.txt"
cp "$VENDOR_SRC/libmtp/COPYING" "$VENDOR_BUILD/licenses/libmtp-COPYING.txt"
cat > "$VENDOR_BUILD/SOURCES.txt" <<SRC
Corresponding source for the LGPL libraries bundled with $APP_NAME $APP_VERSION (unmodified):
  libusb $LIBUSB_TAG  $LIBUSB_REPO/tree/$LIBUSB_COMMIT
  libmtp $LIBMTP_TAG  $LIBMTP_REPO/tree/$LIBMTP_COMMIT
Built by Scripts/build-deps.sh in the $APP_NAME repository (configure flags are listed there).
SRC
echo "Done: $OUT"
