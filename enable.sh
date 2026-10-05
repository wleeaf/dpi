#!/usr/bin/env bash
set -euo pipefail
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
echo "enable.sh now uses the dpi installer. See README.md."
exec "$BASE/dpi" install "$@"
