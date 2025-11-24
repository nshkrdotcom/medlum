#!/usr/bin/env bash
# Provision a US/CA RTX 3090 (<= $0.18/hr) with 16GB disk.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VAST_API_KEY:?Set VAST_API_KEY}"

MIX_ENV=dev VAST_API_KEY="$VAST_API_KEY" mix run -e "IO.inspect(Lumainus.VastAI.provision(max_price: 0.18, disk_gb: 16, geolocation: [\"US\",\"CA\"], label: \"docling-dev\"))"
