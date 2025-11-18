#!/usr/bin/env bash
set -euo pipefail

API_URL=${API_URL:-http://localhost:4000/api/uploads}
PDF_PATH=${1:-docling_service/testPdf.pdf}

if [[ ! -f "$PDF_PATH" ]]; then
  echo "Sample PDF not found at $PDF_PATH" >&2
  exit 1
fi

curl -f -X POST "$API_URL" \
  -H "Accept: application/json" \
  -F "file=@${PDF_PATH};type=application/pdf"
echo ""
