#!/usr/bin/env bash
# View production logs
# Usage: ./scripts/logs.sh

set -euo pipefail

SERVER="lu"

echo "📋 Lumainus production logs (Ctrl+C to exit)..."
echo

ssh "$SERVER" "sudo journalctl -u lumainus -f --since '10 minutes ago'"
