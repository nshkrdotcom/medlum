#!/usr/bin/env bash
# Quick Docling connectivity test. Usage: scripts/test_docling.sh [DOC_URL]
set -euo pipefail
DOC_URL=${DOC_URL:-"https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf"}
SERVICE_URL=${SERVICE_URL:-"http://127.0.0.1:8042"}
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
PDF_PATH="$TMP_DIR/docling-test.pdf"
RESPONSE_PATH="$TMP_DIR/docling-response.json"
export RESPONSE_PATH

curl -fsSL "$DOC_URL" -o "$PDF_PATH"
echo "Fetched sample PDF to $PDF_PATH"

HTTP_CODE=$(curl -s -w "%{http_code}" -o "$RESPONSE_PATH" -F output_markdown=true -F file=@"$PDF_PATH" "$SERVICE_URL/convert")

if [ "$HTTP_CODE" != "200" ]; then
  echo "Docling request failed with HTTP $HTTP_CODE"
  cat "$RESPONSE_PATH"
  exit 1
fi

echo "Docling responded with HTTP 200"
python3 - <<'PY'
import json, os
with open(os.environ['RESPONSE_PATH']) as fh:
    resp = json.load(fh)
print(f"Markdown chars: {len(resp.get('markdown',''))}")
print(f"Metadata: {resp.get('metadata')}")
PY
