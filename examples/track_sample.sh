#!/usr/bin/env bash
set -euo pipefail

API_BASE=${API_BASE:-http://localhost:4000}
UPLOAD_URL="$API_BASE/api/uploads"
STATUS_URL="$API_BASE/api/uploads"
PDF_PATH=${1:-docling_service/testPdf.pdf}
POLL_INTERVAL=${POLL_INTERVAL:-2}
PYTHON_BIN=${PYTHON_BIN:-python3}

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  if command -v python >/dev/null 2>&1; then
    PYTHON_BIN=python
  else
    echo "Python interpreter not found (expected python3 or python). Install it or set PYTHON_BIN." >&2
    exit 1
  fi
fi

if [[ ! -f "$PDF_PATH" ]]; then
  echo "Sample PDF not found at $PDF_PATH" >&2
  exit 1
fi

echo "Uploading $PDF_PATH to $UPLOAD_URL"
UPLOAD_RESPONSE=$(curl -s -f -X POST "$UPLOAD_URL" \
  -H "Accept: application/json" \
  -F "file=@${PDF_PATH};type=application/pdf")

if ! UPLOAD_ID=$(printf '%s' "$UPLOAD_RESPONSE" | "$PYTHON_BIN" -c 'import json, sys
try:
    data = json.load(sys.stdin)
    sys.stdout.write(data.get("upload_id",""))
except Exception as exc:
    sys.stderr.write(str(exc))
    sys.exit(1)
'); then
  echo "Upload response was not valid JSON:"
  echo "$UPLOAD_RESPONSE"
  exit 1
fi

if [[ -z "$UPLOAD_ID" ]]; then
  echo "Upload ID missing from response" >&2
  echo "$UPLOAD_RESPONSE"
  exit 1
fi

echo "Tracking ingestion for upload $UPLOAD_ID"

while true; do
  STATUS_RESPONSE=$(curl -s -f "$STATUS_URL/$UPLOAD_ID/status")
  if ! read -r STAGE PROGRESS JOB_STATUS MESSAGE < <(
    printf '%s' "$STATUS_RESPONSE" | "$PYTHON_BIN" -c 'import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
job = data.get("job") or {}
stage = job.get("stage") or "pending"
progress = job.get("progress")
progress = "0" if progress is None else str(progress)
status = job.get("status") or "pending"
message = (job.get("last_message") or "").replace("\n", " ").strip()
print(stage)
print(progress)
print(status)
print(message)
'
  ); then
    echo "Unable to parse status response:"
    echo "$STATUS_RESPONSE"
    exit 1
  fi

  PROGRESS=${PROGRESS:-0}
  timestamp=$(date +"%H:%M:%S")
  if [[ -n "$MESSAGE" ]]; then
    echo "[$timestamp] ${STAGE^^} - ${PROGRESS}% :: $MESSAGE"
  else
    echo "[$timestamp] ${STAGE^^} - ${PROGRESS}%"
  fi

  if [[ "$STAGE" == "completed" || "$JOB_STATUS" == "failed" ]]; then
    echo "Final status: $STAGE (progress ${PROGRESS}%)"
    break
  fi

  sleep "$POLL_INTERVAL"
done
