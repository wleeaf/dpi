#!/usr/bin/env bash
set -euo pipefail
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=${1:-dev}
[[ "$VERSION" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo "Invalid version: $VERSION" >&2; exit 1; }
case "$(uname -m)" in
    x86_64) ARCH=x86_64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo "Easy releases support Linux x86_64 and ARM64." >&2; exit 1 ;;
esac
[[ $(uname -s) == Linux ]] || { echo "Package on Linux." >&2; exit 1; }
# Use a freshly built binary, never checked-in binaries/my files.
[[ -x "$BASE/nfq/nfqws" ]] || { echo "Build first: make -C nfq" >&2; exit 1; }
"$BASE/nfq/nfqws" --version >/dev/null
NAME="dpi-$VERSION-linux-$ARCH"
DIST_DIR=${DPI_DIST:-"$BASE/dist"}
mkdir -p "$DIST_DIR"
DIST_DIR=$(cd -- "$DIST_DIR" && pwd)
STAGE=$(mktemp -d)
trap 'rm -rf -- "$STAGE"' EXIT
ROOT="$STAGE/$NAME"
mkdir -p "$ROOT/bin" "$ROOT/scripts" "$ROOT/packaging" "$ROOT/profiles" "$ROOT/files/fake" "$ROOT/docs"
install -m 755 "$BASE/nfq/nfqws" "$ROOT/bin/nfqws"
install -m 755 "$BASE/dpi" "$BASE/enable.sh" "$BASE/disable.sh" "$ROOT/"
install -m 755 "$BASE/scripts/runtime.sh" "$ROOT/scripts/runtime.sh"
install -m 644 "$BASE/README.md" "$BASE/LICENSE" "$BASE/dpi.conf.example" "$ROOT/"
install -m 644 "$BASE/docs/LINUX.md" "$BASE/docs/MACOS.md" "$BASE/docs/DEVELOPMENT.md" "$ROOT/docs/"
install -m 644 "$BASE/packaging/dpi.service" "$ROOT/packaging/"
install -m 644 "$BASE/profiles/discord.txt" "$ROOT/profiles/"
for payload in tls_clienthello_www_google_com quic_initial_www_google_com discord-ip-discovery-with-port; do
    install -m 644 "$BASE/files/fake/$payload.bin" "$ROOT/files/fake/"
done
DPI_CONFIG="$ROOT/dpi.conf.example" "$ROOT/scripts/runtime.sh" check
tar --sort=name --owner=0 --group=0 --numeric-owner -C "$STAGE" -czf "$DIST_DIR/$NAME.tar.gz" "$NAME"
(
    cd "$DIST_DIR"
    sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256"
)
echo "Created $DIST_DIR/$NAME.tar.gz"
