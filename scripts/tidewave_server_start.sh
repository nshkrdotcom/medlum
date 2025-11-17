#!/usr/bin/env bash
# Tidewave Server Start Script
# Checks if Tidewave CLI is installed, installs if needed, then starts the server

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BIN_DIR="$PROJECT_ROOT/bin"
TIDEWAVE_CLI="$BIN_DIR/tidewave-cli"
INSTALL_SCRIPT="$SCRIPT_DIR/tidewave_server_install.sh"

# Check if Tidewave CLI is installed
if [ ! -x "$TIDEWAVE_CLI" ]; then
    echo "Tidewave CLI not found. Installing..."
    bash "$INSTALL_SCRIPT"
fi

# Start Tidewave server
echo "Starting Tidewave server..."
echo "Access at: http://localhost:9832"
echo "Press Ctrl+C to stop"
echo ""

cd "$PROJECT_ROOT"
exec "$TIDEWAVE_CLI"
