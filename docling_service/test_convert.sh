#!/bin/bash
# Test Docling conversion - uploads PDF and outputs markdown

set -e

DOCLING_URL="${DOCLING_URL:-http://127.0.0.1:8042}"
PDF_FILE="${1:-test.pdf}"

if [[ ! -f "$PDF_FILE" ]]; then
    echo "Usage: $0 <pdf_file>"
    echo "File not found: $PDF_FILE"
    exit 1
fi

echo "Uploading: $PDF_FILE" >&2
echo "Endpoint: $DOCLING_URL/convert" >&2
echo "---" >&2

RESPONSE=$(curl -s -X POST "$DOCLING_URL/convert" \
    -F "file=@$PDF_FILE" \
    -F "output_markdown=true")

# Check if we got valid JSON
if ! echo "$RESPONSE" | jq . >/dev/null 2>&1; then
    echo "ERROR: Invalid JSON response:" >&2
    echo "$RESPONSE" >&2
    exit 1
fi

# Extract markdown
MARKDOWN=$(echo "$RESPONSE" | jq -r '.markdown // empty')

if [[ -z "$MARKDOWN" ]]; then
    echo "ERROR: No markdown in response. Full response:" >&2
    echo "$RESPONSE" | jq . >&2
    exit 1
fi

echo "$MARKDOWN"
