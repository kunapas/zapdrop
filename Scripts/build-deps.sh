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

# Homebrew's gettext 1.0+ keeps its autoconf macros (needed by libmtp's autogen.sh) outside aclocal's search path.
if command -v brew >/dev/null; then
  gettext_prefix=$(brew --prefix gettext 2>/dev/null || true)
  if [[ -d "$gettext_prefix/share/gettext/m4" ]]; then
    export ACLOCAL_PATH="$gettext_prefix/share/gettext/m4${ACLOCAL_PATH:+:$ACLOCAL_PATH}"
  fi
  if ! command -v autopoint >/dev/null && [[ -x "$gettext_prefix/bin/autopoint" ]]; then
    export PATH="$PATH:$gettext_prefix/bin"
  fi
fi

# libtool cannot cope with whitespace in paths, so compile in a temporary directory that has none.
WORK=$(cd "$(mktemp -d /tmp/zapdrop-deps.XXXXXX)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

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
  # The pinned commit means nothing if tracked files were edited afterwards.
  if [[ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]]; then
    echo "Modified files in $dir: delete the folder and run this script again." >&2
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
  local prefix="$WORK/$arch"
  local flags="-arch $arch -mmacosx-version-min=$MIN_MACOS -isysroot $SDK -O2"
  mkdir -p "$WORK/src-$arch"
  cp -R "$VENDOR_SRC/libusb" "$WORK/src-$arch/libusb"
  cp -R "$VENDOR_SRC/libmtp" "$WORK/src-$arch/libmtp"

  echo "==> libusb ($arch)"
  ( cd "$WORK/src-$arch/libusb"
    ./bootstrap.sh >/dev/null
    ./configure --quiet --host="$host" --prefix="$prefix" --disable-static --enable-shared \
      CFLAGS="$flags" LDFLAGS="$flags -Wl,-headerpad_max_install_names"
    make -j"$JOBS" >/dev/null
    make install >/dev/null )

  echo "==> libmtp ($arch)"
  ( cd "$WORK/src-$arch/libmtp"
    ./autogen.sh >"$WORK/autogen-$arch.log" 2>&1 || { cat "$WORK/autogen-$arch.log" >&2; exit 1; }
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
cp -R "$WORK/arm64/include/." "$OUT/include/"
for lib in "$LIBUSB_DYLIB" "$LIBMTP_DYLIB"; do
  lipo -create "$WORK/arm64/lib/$lib" "$WORK/x86_64/lib/$lib" -output "$OUT/lib/$lib"
done
# @rpath install names so the app finds them in Contents/Frameworks.
install_name_tool -id "@rpath/$LIBUSB_DYLIB" "$OUT/lib/$LIBUSB_DYLIB"
install_name_tool -id "@rpath/$LIBMTP_DYLIB" "$OUT/lib/$LIBMTP_DYLIB"
for arch in arm64 x86_64; do
  install_name_tool -change "$WORK/$arch/lib/$LIBUSB_DYLIB" "@rpath/$LIBUSB_DYLIB" "$OUT/lib/$LIBMTP_DYLIB" 2>/dev/null || true
done
# install_name_tool invalidates signatures; Apple Silicon refuses to load unsigned code, so re-sign ad hoc.
# (Release signing with a Developer ID happens later, in embed-dylibs.sh.)
codesign --force --sign - "$OUT/lib/$LIBUSB_DYLIB" "$OUT/lib/$LIBMTP_DYLIB"
ln -sf "$LIBUSB_DYLIB" "$OUT/lib/libusb-1.0.dylib"
ln -sf "$LIBMTP_DYLIB" "$OUT/lib/libmtp.dylib"

# Verify: universal, @rpath ids, no absolute build paths left.
for lib in "$LIBUSB_DYLIB" "$LIBMTP_DYLIB"; do
  lipo -info "$OUT/lib/$lib"
  # otool prints a "<file> (architecture …):" header per slice; only the dependency lines matter.
  if otool -L "$OUT/lib/$lib" | grep -v ':$' | grep -qF "$WORK"; then
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
