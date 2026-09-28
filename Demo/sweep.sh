#!/usr/bin/env bash
# v6 六版式原始像素验收：./sweep.sh UDID [delta=4] [chroma|luma]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/tools/sweep_demo.py" "$@"
