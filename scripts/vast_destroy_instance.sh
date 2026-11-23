#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VAST_API_KEY:?Set VAST_API_KEY}"
INSTANCE_ID=${1:?Usage: $0 <instance_id>}

MIX_ENV=dev VAST_API_KEY="$VAST_API_KEY" mix run -e "IO.inspect(Medlum.VastAI.destroy(\"${INSTANCE_ID}\"))"
