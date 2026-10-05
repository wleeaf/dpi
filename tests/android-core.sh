#!/usr/bin/env bash
set -euo pipefail
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
keytool -genkeypair -alias test -keyalg RSA -storetype PKCS12 -keystore "$WORK/test.p12" \
    -storepass test-password -keypass test-password -dname 'CN=localhost' -validity 1 -noprompt >/dev/null 2>&1
javac --release 8 -Xlint:-options -d "$WORK/classes" \
    "$BASE/android/app/src/main/java/io/github/wleeaf/dpi/FirstFlight.java" \
    "$BASE/android/app/src/main/java/io/github/wleeaf/dpi/LocalProxy.java" \
    "$BASE/android/app/src/main/java/io/github/wleeaf/dpi/HttpsDns.java" "$BASE/tests/AndroidCoreTest.java"
java -cp "$WORK/classes" io.github.wleeaf.dpi.AndroidCoreTest "$WORK/test.p12"
