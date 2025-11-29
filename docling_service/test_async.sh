#!/bin/bash
# Test async Docling conversion - shows full SSE completion event

set -e

DOCLING_URL="${DOCLING_URL:-http://127.0.0.1:8042}"
PDF_FILE="${1:-test.pdf}"

if [[ ! -f "$PDF_FILE" ]]; then
    echo "Usage: $0 <pdf_file>"
    exit 1
fi

echo "=== Submitting job ===" >&2

SUBMIT=$(curl -s -X POST "$DOCLING_URL/jobs" \
    -F "file=@$PDF_FILE" \
    -F "output_markdown=true" \
    -F "wait=false")

JOB_ID=$(echo "$SUBMIT" | jq -r '.job_id')
echo "Job ID: $JOB_ID" >&2

echo "=== Streaming SSE (waiting for completion) ===" >&2

# Stream and capture only the completed event
curl -s -N "$DOCLING_URL/jobs/$JOB_ID/stream" | while IFS= read -r line; do
    if [[ "$line" == data:* ]]; then
        JSON="${line#data: }"
        STATE=$(echo "$JSON" | jq -r '.state // empty' 2>/dev/null)

        if [[ "$STATE" == "completed" ]]; then
            echo "=== COMPLETED EVENT ===" >&2
            echo "$JSON" | jq .

            # Show if result/markdown exists
            echo "=== MARKDOWN CHECK ===" >&2
            echo "$JSON" | jq '{has_result: (.result != null), has_markdown: (.result.markdown != null), markdown_length: (.result.markdown | length // 0)}'
            break
        fi
    fi
done
