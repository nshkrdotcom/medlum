#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${1:-docling.service}"

if command -v journalctl >/dev/null 2>&1; then
  echo "Tailing ${SERVICE_NAME} (override by passing a different unit name)..."
  exec journalctl -u "${SERVICE_NAME}" -f -n 200
fi

echo "journalctl is not available on this system."
echo "If Docling writes to a file, tail it directly (e.g., tail -f /var/log/docling.log)."
