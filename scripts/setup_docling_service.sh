#!/usr/bin/env bash
# Ubuntu helper to provision and optionally start the Docling REST microservice.
# Run from anywhere: it computes paths relative to this script.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SERVICE_DIR="$ROOT_DIR/docling_service"
RUN_SERVER=${RUN_SERVER:-true}
HOST=${HOST:-0.0.0.0}
PORT=${PORT:-8042}
PYTHON_BIN=${PYTHON_BIN:-python3}
APT_PACKAGES=(
  python3
  python3-venv
  python3-pip
  build-essential
  pkg-config
  libgl1
  libglib2.0-0
  libtesseract-dev
  tesseract-ocr
)

if [ ! -d "$SERVICE_DIR" ]; then
  echo "Docling service directory not found at $SERVICE_DIR" >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This script expects Ubuntu/Debian with apt-get." >&2
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required to install system packages." >&2
  exit 1
fi

if [ ! -f /etc/os-release ] || ! grep -qi ubuntu /etc/os-release; then
  echo "Warning: /etc/os-release does not report Ubuntu. Continuing anyway." >&2
fi

cat <<INFO
[Docling setup]
- Service root: $SERVICE_DIR
- Host/port: $HOST:$PORT
- Python: $PYTHON_BIN
INFO

echo "[+] Installing system dependencies via apt-get"
sudo apt-get update
sudo apt-get install -y "${APT_PACKAGES[@]}"

if [ "$RUN_SERVER" != "true" ]; then
  echo "System dependencies installed. Set RUN_SERVER=true to auto-start the service."
  exit 0
fi

echo "[+] Starting Docling REST service"
cd "$SERVICE_DIR"
PYTHON_BIN="$PYTHON_BIN" HOST="$HOST" PORT="$PORT" ./run.sh
