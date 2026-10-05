#!/bin/bash
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { echo 'Build on macOS with Xcode Command Line Tools.' >&2; exit 1; }
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$BASE/macos/bin"
cd "$BASE/tpws"
# Use only SDK libraries; the download needs neither Homebrew nor Rosetta.
/usr/bin/xcrun clang -std=gnu99 -Os -flto -Wno-address-of-packed-member -mmacosx-version-min=15.0 \
    -arch arm64 -arch x86_64 -Iepoll-shim/include -Imacos \
    "-DZAPRET_GH_VER=${DPI_VERSION_NAME:-dev}" "-DZAPRET_GH_HASH=${BUILD_COMMIT:-local}" \
    ./*.c epoll-shim/src/*.c -lz -lpthread -o "$BASE/macos/bin/tpws"
/usr/bin/strip "$BASE/macos/bin/tpws"
/usr/bin/codesign --force --sign - "$BASE/macos/bin/tpws"
/usr/bin/lipo -verify_arch arm64 x86_64 "$BASE/macos/bin/tpws"
echo 'Built universal macOS engine.'
