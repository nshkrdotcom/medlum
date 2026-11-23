#!/usr/bin/env bash
# Build both layers of the service image. Pass a custom service tag as $1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -gt 0 ]; then
    export TAG="$1"
fi
exec "$SCRIPT_DIR/../scripts/docling-gpu.sh" build-all
