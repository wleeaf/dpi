#!/usr/bin/env bash
set -euo pipefail
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ $(uname -s) == CYGWIN* ]] || { echo 'Build this engine using x64 Cygwin on Windows.' >&2; exit 1; }
CFLAGS="-DZAPRET_SERVICE_NAME=DpiBypass -DZAPRET_GH_VER=${DPI_VERSION_NAME:-dev} -DZAPRET_GH_HASH=${BUILD_COMMIT:-local}" make -C "$BASE/nfq" cygwin64
mkdir -p "$BASE/windows/bin"
cp "$BASE/nfq/winws.exe" /usr/bin/cygwin1.dll "$BASE/windows/bin/"
