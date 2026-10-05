#!/bin/bash
set -euo pipefail
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sudo "$BASE/dpi" install
open /Applications/DPI.app
