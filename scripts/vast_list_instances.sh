#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VAST_API_KEY:?Set VAST_API_KEY}"

MIX_ENV=dev VAST_API_KEY="$VAST_API_KEY" mix run -e "IO.inspect(Lumainus.VastAI.Instances.list())"
