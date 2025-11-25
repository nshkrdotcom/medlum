#!/usr/bin/env bash
# Docling Native Service Setup
# =============================
# Ubuntu helper to provision and optionally start the Docling REST microservice
# running directly on the host (no Docker).
#
# Supports two modes:
#   native_cpu (port 8040) - CPU-only processing
#   native_gpu (port 8041) - GPU-accelerated with CUDA
#
# Usage:
#   ./setup_docling_service.sh              # Default: native_cpu
#   ./setup_docling_service.sh native_gpu   # GPU mode
#   DOCLING_MODE=native_gpu ./setup_docling_service.sh

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SERVICE_DIR="$ROOT_DIR/docling_service"

# Source port definitions
source "$(dirname "$0")/docling-ports.env"

# Determine mode from argument or environment
DOCLING_MODE="${1:-${DOCLING_MODE:-native_cpu}}"

case "$DOCLING_MODE" in
    native_cpu|cpu)
        DOCLING_MODE="native_cpu"
        PORT="${DOCLING_PORT_NATIVE_CPU}"
        USE_GPU=false
        ;;
    native_gpu|gpu)
        DOCLING_MODE="native_gpu"
        PORT="${DOCLING_PORT_NATIVE_GPU}"
        USE_GPU=true
        ;;
    *)
        echo "Unknown mode: $DOCLING_MODE"
        echo "Valid modes: native_cpu, native_gpu (or cpu, gpu)"
        exit 1
        ;;
esac

RUN_SERVER=${RUN_SERVER:-true}
HOST=${HOST:-0.0.0.0}
PYTHON_BIN=${PYTHON_BIN:-python3}

# Base packages for both modes
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

# GPU packages (if USE_GPU)
APT_PACKAGES_GPU=(
    nvidia-cuda-toolkit
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
[Docling Native Service Setup]
- Mode: $DOCLING_MODE
- Service root: $SERVICE_DIR
- Host/port: $HOST:$PORT
- Python: $PYTHON_BIN
- GPU enabled: $USE_GPU
INFO

echo "[+] Installing system dependencies via apt-get"
sudo apt-get update
sudo apt-get install -y "${APT_PACKAGES[@]}"

if [ "$USE_GPU" = true ]; then
    echo "[+] Installing GPU dependencies"
    sudo apt-get install -y "${APT_PACKAGES_GPU[@]}"

    # Check for NVIDIA driver
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        echo "Warning: nvidia-smi not found. GPU acceleration may not work." >&2
        echo "Install NVIDIA drivers: sudo apt install nvidia-driver-xxx" >&2
    else
        echo "[+] NVIDIA driver detected:"
        nvidia-smi --query-gpu=name,driver_version --format=csv,noheader || true
    fi
fi

if [ "$RUN_SERVER" != "true" ]; then
    echo "System dependencies installed. Set RUN_SERVER=true to auto-start the service."
    exit 0
fi

echo "[+] Starting Docling REST service ($DOCLING_MODE on port $PORT)"
cd "$SERVICE_DIR"

# Set environment for GPU mode
if [ "$USE_GPU" = true ]; then
    export DOCLING_USE_GPU=true
    # Use GPU-optimized PyTorch index
    export PIP_EXTRA_INDEX_URL="${PIP_EXTRA_INDEX_URL:-https://download.pytorch.org/whl/cu121}"
else
    export DOCLING_USE_GPU=false
    # Use CPU-only PyTorch index
    export PIP_EXTRA_INDEX_URL="${PIP_EXTRA_INDEX_URL:-https://download.pytorch.org/whl/cpu}"
fi

PYTHON_BIN="$PYTHON_BIN" HOST="$HOST" PORT="$PORT" ./run.sh
