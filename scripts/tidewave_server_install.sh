#!/usr/bin/env bash
# Tidewave Server Installation Script
# Installs Tidewave CLI to bin/tidewave-cli

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BIN_DIR="$PROJECT_ROOT/bin"
TIDEWAVE_CLI="$BIN_DIR/tidewave-cli"
DOWNLOAD_URL="https://github.com/tidewave-ai/tidewave_app/releases/latest/download/tidewave-cli-x86_64-unknown-linux-gnu"

echo "Installing Tidewave CLI..."

# Create bin directory if it doesn't exist
mkdir -p "$BIN_DIR"

# Download Tidewave CLI
echo "Downloading from $DOWNLOAD_URL..."
curl -L -o "$TIDEWAVE_CLI" "$DOWNLOAD_URL"

# Make executable
chmod +x "$TIDEWAVE_CLI"

# Verify installation
if [ -x "$TIDEWAVE_CLI" ]; then
    echo "Tidewave CLI installed successfully to $TIDEWAVE_CLI"
    "$TIDEWAVE_CLI" --version
else
    echo "Error: Installation failed"
    exit 1
fi
