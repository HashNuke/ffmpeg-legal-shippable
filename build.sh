#!/usr/bin/env bash
set -euo pipefail

# Portable, non-GPL, non-nonfree FFmpeg+FFprobe build for macOS:
# - Builds UNIVERSAL binaries (arm64 + x86_64)
# - Targets macOS >= 14.0 (works on macOS 14.0+)
# - Tries hard to avoid depending on Homebrew/MacPorts dylibs:
#   * disables shared libs
#   * disables autodetection of external libs
#   * builds a single ffmpeg/ffprobe that should only depend on system libs/frameworks
#
# Requirements on build machine:
#   - Xcode Command Line Tools: xcode-select --install
#   - git, make
#
# Usage:
#   ./build_ffmpeg_portable_macos.sh
#
# Output:
#   ./dist/ffmpeg-universal/bin/ffmpeg
#   ./dist/ffmpeg-universal/bin/ffprobe

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/work}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
SRC_DIR="$WORK_DIR/ffmpeg"

# Target minimum macOS version for portability
MIN_MACOS="${MIN_MACOS:-14.0}"

# Optional: pin a tag, e.g. n7.1.1. Leave empty for default branch.
FFMPEG_REF="${FFMPEG_REF:-}"

# Configure extra knobs
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

mkdir -p "$WORK_DIR" "$DIST_DIR"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }
}

need git
need make
need xcrun
need lipo
need otool

SDK="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --sdk macosx -f clang)"
CXX="$(xcrun --sdk macosx -f clang++)"

fetch_ffmpeg() {
  if [[ ! -d "$SRC_DIR/.git" ]]; then
    echo "Cloning FFmpeg source..."
    git clone https://github.com/FFmpeg/FFmpeg.git "$SRC_DIR"
  fi

  pushd "$SRC_DIR" >/dev/null
  git fetch --tags origin
  if [[ -n "$FFMPEG_REF" ]]; then
    echo "Checking out FFmpeg ref: $FFMPEG_REF"
    git checkout -f "$FFMPEG_REF"
  else
    echo "Checking out latest origin/master..."
    git checkout -f master
    git pull --ff-only
  fi
  popd >/dev/null
}

build_one_arch() {
  local ARCH="$1"
  local PREFIX="$WORK_DIR/prefix-$ARCH"
  local BUILD_OUT="$WORK_DIR/build-$ARCH"

  rm -rf "$PREFIX" "$BUILD_OUT"
  mkdir -p "$PREFIX" "$BUILD_OUT"

  pushd "$SRC_DIR" >/dev/null
  make distclean >/dev/null 2>&1 || true

  # We explicitly force the arch + min OS, and avoid "helpful" environment leakage.
  export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
  export CC
  export CXX
  export PKG_CONFIG="/usr/bin/false"   # avoid pulling brew libs via pkg-config
  unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR CPATH LIBRARY_PATH DYLD_LIBRARY_PATH

  local CFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MIN_MACOS -O3"
  local LDFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MIN_MACOS"

  echo ""
  echo "==> Configuring for $ARCH (min macOS $MIN_MACOS)"
  echo ""

  ./configure \
    --prefix="$PREFIX" \
    --cc="$CC" \
    --extra-cflags="$CFLAGS" \
    --extra-ldflags="$LDFLAGS" \
    \
    --disable-debug \
    --disable-doc \
    \
    --disable-shared \
    --enable-static \
    --enable-pic \
    \
    --disable-autodetect \
    \
    --disable-gpl \
    --disable-nonfree \
    --disable-version3 \
    \
    --enable-videotoolbox \
    --enable-audiotoolbox \
    \
    --enable-zlib \
    \
    --enable-ffmpeg \
    --enable-ffprobe \
    --disable-ffplay \
    \
    --disable-programs=no \
    --disable-network=no

  echo ""
  echo "==> Building for $ARCH"
  echo ""
  make -j"$JOBS"
  make install

  popd >/dev/null
}

make_universal() {
  local OUT="$DIST_DIR/ffmpeg-universal"
  rm -rf "$OUT"
  mkdir -p "$OUT/bin"

  local FFMPEG_ARM="$WORK_DIR/prefix-arm64/bin/ffmpeg"
  local FFMPEG_X64="$WORK_DIR/prefix-x86_64/bin/ffmpeg"
  local FFPROBE_ARM="$WORK_DIR/prefix-arm64/bin/ffprobe"
  local FFPROBE_X64="$WORK_DIR/prefix-x86_64/bin/ffprobe"

  echo ""
  echo "==> Creating universal binaries"
  echo ""

  lipo -create "$FFMPEG_ARM" "$FFMPEG_X64" -output "$OUT/bin/ffmpeg"
  lipo -create "$FFPROBE_ARM" "$FFPROBE_X64" -output "$OUT/bin/ffprobe"

  chmod +x "$OUT/bin/ffmpeg" "$OUT/bin/ffprobe"

  echo ""
  echo "==> Verifying arch slices"
  file "$OUT/bin/ffmpeg"
  file "$OUT/bin/ffprobe"

  echo ""
  echo "==> Checking that we didn't accidentally link Homebrew/MacPorts dylibs"
  echo "    (You should NOT see /opt/homebrew, /usr/local, MacPorts, etc.)"
  echo ""
  echo "ffmpeg deps:"
  otool -L "$OUT/bin/ffmpeg" | sed 's/^/  /'
  echo ""
  echo "ffprobe deps:"
  otool -L "$OUT/bin/ffprobe" | sed 's/^/  /'

  echo ""
  echo "==> Printing build configuration (license flags sanity-check)"
  "$OUT/bin/ffmpeg" -buildconf | sed 's/^/  /'

  echo ""
  echo "Done."
  echo "Binaries are in: $OUT/bin"
}

main() {
  fetch_ffmpeg
  build_one_arch arm64
  build_one_arch x86_64
  make_universal

  cat <<EOF

Notes:
- macOS does not support fully static "everything" binaries like Linux; you will still depend on Apple system libraries/frameworks.
- This script avoids depending on third-party dynamic libraries by:
  * disabling shared FFmpeg libs
  * disabling autodetection of external libs
  * forcing pkg-config off
- If otool -L shows /opt/homebrew or /usr/local paths, something leaked in; re-run from a clean shell.

EOF
}

main "$@"
