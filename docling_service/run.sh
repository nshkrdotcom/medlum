#!/usr/bin/env bash
set -euo pipefail

APP_ROOT=$(cd "$(dirname "$0")" && pwd)
VENV_DIR="$APP_ROOT/.venv"
REQUIREMENTS_FILE="$APP_ROOT/requirements.txt"
PYTHON_BIN=${PYTHON_BIN:-python3}
PORT=${PORT:-8042}
HOST=${HOST:-0.0.0.0}
DOCLING_TORCH_INDEX=${DOCLING_TORCH_INDEX:-https://download.pytorch.org/whl/cpu}

if [ ! -d "$VENV_DIR" ]; then
  echo "[+] Creating virtual environment at $VENV_DIR"
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

python -m pip install --index-url "$DOCLING_TORCH_INDEX" torch torchvision
python -m pip install --requirement "$REQUIREMENTS_FILE"

export PYTHONPATH="$APP_ROOT:${PYTHONPATH:-}"

# Disable uvicorn access logs to reduce noise (use --access-log for verbose mode)
# SSE streaming creates many requests; rely on structured app logs instead
exec uvicorn app.main:app --host "$HOST" --port "$PORT" --no-access-log
