#!/usr/bin/env bash
# View production logs
# Usage: ./scripts/logs.sh

set -euo pipefail

SERVER="lu"

echo "📋 Medlum production logs (Ctrl+C to exit)..."
echo

ssh "$SERVER" "sudo journalctl -u medlum -f --since '10 minutes ago'"
