#!/bin/bash
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { echo 'Package on macOS.' >&2; exit 1; }
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=${1:-dev}
[[ "$VERSION" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo 'Invalid version.' >&2; exit 1; }
NAME="dpi-$VERSION-macos-universal"
[[ "$VERSION" != dev ]] && PACKAGE_VERSION=${VERSION#v} || PACKAGE_VERSION=0.0.0
PACKAGE_VERSION=${PACKAGE_VERSION%%-*}
DIST="$BASE/dist"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
ROOT="$WORK/$NAME"
mkdir -p "$ROOT/bin" "$ROOT/macos" "$ROOT/packaging" "$ROOT/profiles" "$ROOT/docs" "$DIST"
install -m 755 "$BASE/macos/bin/tpws" "$ROOT/bin/"
install -m 755 "$BASE/dpi" "$ROOT/"
install -m 755 "$BASE/macos/dpi.sh" "$BASE/macos/runtime.sh" "$ROOT/macos/"
install -m 755 "$BASE/macos/Install.command" "$ROOT/macos/"
install -m 644 "$BASE/macos/dpi.conf.example" "$ROOT/macos/"
install -m 644 "$BASE/packaging/io.github.wleeaf.dpi.plist" "$ROOT/packaging/"
install -m 644 "$BASE/profiles/discord.txt" "$ROOT/profiles/"
install -m 644 "$BASE/docs/MACOS.md" "$BASE/docs/LINUX.md" "$BASE/docs/DEVELOPMENT.md" "$ROOT/docs/"
install -m 644 "$BASE/README.md" "$BASE/LICENSE" "$ROOT/"
/usr/bin/osacompile -o "$ROOT/DPI.app" "$BASE/macos/DPI.applescript"
/usr/bin/defaults write "$ROOT/DPI.app/Contents/Info" CFBundleIdentifier io.github.wleeaf.dpi.controls
/usr/bin/defaults write "$ROOT/DPI.app/Contents/Info" CFBundleShortVersionString "$PACKAGE_VERSION"
/usr/bin/plutil -lint "$ROOT/DPI.app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$ROOT/DPI.app"
mkdir -p "$WORK/payload/opt/dpi" "$WORK/payload/Applications"
/usr/bin/ditto "$ROOT" "$WORK/payload/opt/dpi"
rm -rf "$WORK/payload/opt/dpi/DPI.app"
/usr/bin/ditto "$ROOT/DPI.app" "$WORK/payload/Applications/DPI.app"
/usr/bin/pkgbuild --root "$WORK/payload" --identifier io.github.wleeaf.dpi \
    --version "$PACKAGE_VERSION" --scripts "$BASE/macos/pkg-scripts" --ownership recommended \
    --install-location / "$DIST/$NAME.pkg"
tar -C "$WORK" -czf "$DIST/$NAME.tar.gz" "$NAME"
cd "$DIST"
/usr/bin/shasum -a 256 "$NAME.pkg" > "$NAME.pkg.sha256"
/usr/bin/shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256"
echo "Created $DIST/$NAME.pkg and $DIST/$NAME.tar.gz"
