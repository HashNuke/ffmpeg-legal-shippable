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
#   - make, curl, tar
#
# Usage:
#   ./build.sh
#
# Output:
#   ./dist/ffmpeg-8.0.1-YYYYMMDDHHMM-macos-universal/bin/ffmpeg
#   ./dist/ffmpeg-8.0.1-YYYYMMDDHHMM-macos-universal/bin/ffprobe
#   ./dist/ffmpeg-8.0.1-YYYYMMDDHHMM-macos-universal.tar.gz

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/work}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"

# Target minimum macOS version for portability
MIN_MACOS="${MIN_MACOS:-14.0}"

FFMPEG_VERSION="${FFMPEG_VERSION:-8.0.1}"
FFMPEG_TARBALL_URL="${FFMPEG_TARBALL_URL:-https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz}"
FFMPEG_TARBALL_PATH="$WORK_DIR/ffmpeg-${FFMPEG_VERSION}.tar.xz"
SRC_DIR="$WORK_DIR/ffmpeg-${FFMPEG_VERSION}"

# Release naming:
# - BUILD_STAMP defaults to UTC YYYYMMDDHHMM
# - Optional BUILD_ID can be used to include a monotonically increasing build number from CI
BUILD_STAMP="${BUILD_STAMP:-$(date -u +%Y%m%d%H%M)}"
BUILD_ID="${BUILD_ID:-}"

# Configure extra knobs
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

mkdir -p "$WORK_DIR" "$DIST_DIR"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }
}

need make
need curl
need tar
need xcrun
need lipo
need otool

SDK="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --sdk macosx -f clang)"
CXX="$(xcrun --sdk macosx -f clang++)"

usage() {
  cat <<EOF
Usage:
  ./build.sh [--help] [--no-package]

Env vars:
  MIN_MACOS=14.0          Minimum target macOS (default: 14.0)
  FFMPEG_VERSION=8.0.1    FFmpeg version (default: 8.0.1)
  BUILD_STAMP=YYYYMMDDHHMM  Stamp used in output name (default: current UTC)
  BUILD_ID=123            Optional build number/id appended after version
  WORK_DIR=... DIST_DIR=... JOBS=...
EOF
}

OUT_BASENAME() {
  local base="ffmpeg-${FFMPEG_VERSION}"
  if [[ -n "${BUILD_ID}" ]]; then
    base="${base}-b${BUILD_ID}"
  fi
  base="${base}-${BUILD_STAMP}-macos-universal"
  echo "$base"
}

assert_no_third_party_dylibs() {
  local BIN="$1"
  local BAD
  BAD="$(otool -L "$BIN" | grep -E '(/opt/homebrew/|/usr/local/|/opt/local/)' || true)"
  if [[ -n "$BAD" ]]; then
    echo "ERROR: $BIN links against non-system libraries:" >&2
    echo "$BAD" >&2
    exit 1
  fi
}

package_release() {
  local OUT_DIR="$1"
  local BASENAME
  BASENAME="$(basename "$OUT_DIR")"
  local TARBALL="$DIST_DIR/${BASENAME}.tar.gz"
  local STAGE="$WORK_DIR/stage-${BASENAME}"

  echo ""
  echo "==> Packaging release tarball"
  echo ""

  rm -f "$TARBALL" "$TARBALL.sha256"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  cp -f "$OUT_DIR/bin/ffmpeg" "$STAGE/ffmpeg"
  cp -f "$OUT_DIR/bin/ffprobe" "$STAGE/ffprobe"
  tar -czf "$TARBALL" -C "$STAGE" ffmpeg ffprobe
  rm -rf "$STAGE"

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$TARBALL" > "$TARBALL.sha256"
  fi

  echo "Tarball: $TARBALL"
  if [[ -f "$TARBALL.sha256" ]]; then
    echo "SHA256:  $TARBALL.sha256"
  fi
}

fetch_ffmpeg() {
  if [[ -d "$SRC_DIR" && -f "$SRC_DIR/configure" ]]; then
    echo "Using existing FFmpeg source: $SRC_DIR"
    return 0
  fi

  rm -rf "$SRC_DIR"

  if [[ ! -f "$FFMPEG_TARBALL_PATH" ]]; then
    echo "Downloading FFmpeg ${FFMPEG_VERSION}..."
    echo "  $FFMPEG_TARBALL_URL"
    curl -fL --retry 3 --retry-delay 1 -o "$FFMPEG_TARBALL_PATH" "$FFMPEG_TARBALL_URL"
  else
    echo "Using cached tarball: $FFMPEG_TARBALL_PATH"
  fi

  echo "Extracting..."
  tar -xf "$FFMPEG_TARBALL_PATH" -C "$WORK_DIR"
  if [[ ! -d "$SRC_DIR" || ! -f "$SRC_DIR/configure" ]]; then
    echo "Extraction failed or unexpected tarball layout; expected $SRC_DIR/configure" >&2
    exit 1
  fi
}

build_one_arch() {
  local ARCH="$1"
  local PREFIX="$WORK_DIR/prefix-$ARCH"
  local BUILD_OUT="$WORK_DIR/build-$ARCH"
  local HOST_MACHINE
  HOST_MACHINE="$(uname -m)"

  rm -rf "$PREFIX" "$BUILD_OUT"
  mkdir -p "$PREFIX" "$BUILD_OUT"

  # We explicitly force the arch + min OS, and avoid "helpful" environment leakage.
  export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
  export CC
  export CXX
  export SDKROOT="$SDK"
  export HOSTCC="$CC"
  export HOSTCFLAGS="-isysroot $SDK"
  export HOSTLDFLAGS="-isysroot $SDK"
  export PKG_CONFIG="/usr/bin/false"   # avoid pulling brew libs via pkg-config
  unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR CPATH LIBRARY_PATH DYLD_LIBRARY_PATH

  local CFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MIN_MACOS -O3"
  local LDFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MIN_MACOS"

  local CROSS_CONFIG
  CROSS_CONFIG=()
  if [[ "$ARCH" != "$HOST_MACHINE" ]]; then
    if [[ "$ARCH" == "arm64" ]]; then
      CROSS_CONFIG+=(--enable-cross-compile --arch=aarch64 --target-os=darwin)
    else
      CROSS_CONFIG+=(--enable-cross-compile --arch="$ARCH" --target-os=darwin)
    fi
  fi

  local EXTRA_CONFIG
  EXTRA_CONFIG=()
  if [[ "$ARCH" == "x86_64" ]]; then
    if ! command -v nasm >/dev/null 2>&1 && ! command -v yasm >/dev/null 2>&1; then
      echo "Note: nasm/yasm not found; disabling x86 asm for the x86_64 build."
      EXTRA_CONFIG+=(--disable-x86asm)
    fi
  fi

  echo ""
  echo "==> Configuring for $ARCH (min macOS $MIN_MACOS)"
  echo ""

  pushd "$BUILD_OUT" >/dev/null

  "$SRC_DIR/configure" \
    --prefix="$PREFIX" \
    --cc="$CC" \
    --extra-cflags="$CFLAGS" \
    --extra-ldflags="$LDFLAGS" \
    ${CROSS_CONFIG[@]+"${CROSS_CONFIG[@]}"} \
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
    --enable-securetransport \
    \
    --enable-zlib \
    \
    --enable-ffmpeg \
    --enable-ffprobe \
    --disable-ffplay \
    \
    --enable-network \
    ${EXTRA_CONFIG[@]+"${EXTRA_CONFIG[@]}"}

  echo ""
  echo "==> Building for $ARCH"
  echo ""
  make -j"$JOBS"
  make install

  popd >/dev/null
}

make_universal() {
  local OUT="$DIST_DIR/$(OUT_BASENAME)"
  {
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

    if command -v strip >/dev/null 2>&1; then
      strip -x "$OUT/bin/ffmpeg" "$OUT/bin/ffprobe" || true
    fi

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
    assert_no_third_party_dylibs "$OUT/bin/ffmpeg"
    echo ""
    echo "ffprobe deps:"
    otool -L "$OUT/bin/ffprobe" | sed 's/^/  /'
    assert_no_third_party_dylibs "$OUT/bin/ffprobe"

    echo ""
    echo "==> Printing build configuration (license flags sanity-check)"
    "$OUT/bin/ffmpeg" -buildconf | sed 's/^/  /'
    echo ""
    echo "==> Printing version"
    "$OUT/bin/ffmpeg" -version | head -n 1 | sed 's/^/  /'

    cat >"$OUT/BUILDINFO.txt" <<EOF
name=$(basename "$OUT")
ffmpeg_version=$FFMPEG_VERSION
build_stamp_utc=$BUILD_STAMP
build_id=${BUILD_ID:-}
min_macos=$MIN_MACOS
sdk=$SDK
cc=$CC
date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

$( "$OUT/bin/ffmpeg" -buildconf )
EOF

    echo ""
    echo "Done."
    echo "Binaries are in: $OUT/bin"
  } >&2
  echo "$OUT"
}

main() {
  local DO_PACKAGE=1
  for arg in "$@"; do
    case "$arg" in
      -h|--help)
        usage
        exit 0
        ;;
      --no-package)
        DO_PACKAGE=0
        ;;
      *)
        echo "Unknown argument: $arg" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  fetch_ffmpeg
  build_one_arch arm64
  build_one_arch x86_64
  local OUT_DIR
  OUT_DIR="$(make_universal)"
  if [[ "$DO_PACKAGE" -eq 1 ]]; then
    package_release "$OUT_DIR"
  fi

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
