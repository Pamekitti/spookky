#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
exec python3 scripts/dev.py build --configuration "${1:-Debug}"
