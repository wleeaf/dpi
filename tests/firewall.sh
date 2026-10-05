#!/usr/bin/env bash
# Run only inside an isolated network namespace: sudo unshare --net bash tests/firewall.sh
set -euo pipefail
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
chmod 755 "$WORK"
trap 'rm -rf -- "$WORK"' EXIT
export DPI_CONFIG="$WORK/dpi.conf" DPI_STATE="$WORK/state"
mkdir -p "$WORK/runtime/bin" "$WORK/runtime/scripts"
cp "$BASE/scripts/runtime.sh" "$WORK/runtime/scripts/"
ln -s "$BASE/nfq/nfqws" "$WORK/runtime/bin/nfqws"
ln -s "$BASE/profiles" "$WORK/runtime/profiles"
ln -s "$BASE/files" "$WORK/runtime/files"
RUNTIME="$WORK/runtime/scripts/runtime.sh"

# A separate table proves stop never flushes unrelated firewall configuration.
nft add table inet dpi_test_other
for voice in yes no; do
    printf 'PROFILE=discord\nSTRATEGY=default\nVOICE=%s\n' "$voice" > "$DPI_CONFIG"
    "$RUNTIME" rules | nft --check -f -
    "$RUNTIME" firewall-start
    nft list table inet dpi
    # Real queue listener, not just dry-run: verify the engine stays alive.
    "$RUNTIME" start > "$WORK/engine.log" 2>&1 &
    ENGINE_PID=$!
    sleep 1
    if ! kill -0 "$ENGINE_PID" 2>/dev/null; then
        cat "$WORK/engine.log"
        exit 1
    fi
    kill "$ENGINE_PID"
    wait "$ENGINE_PID" || true
    "$RUNTIME" firewall-stop
    if nft list table inet dpi >/dev/null 2>&1; then
        echo 'dpi table was not removed' >&2
        exit 1
    fi
    nft list table inet dpi_test_other
done
nft delete table inet dpi_test_other
