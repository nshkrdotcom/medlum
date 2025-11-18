#!/usr/bin/env bash
set -euo pipefail

APP_ROOT=$(cd "$(dirname "$0")" && pwd)
VENV_DIR="$APP_ROOT/.venv"
REQUIREMENTS_FILE="$APP_ROOT/requirements.txt"
PYTHON_BIN=${PYTHON_BIN:-python3}
PORT=${PORT:-8042}
HOST=${HOST:-0.0.0.0}
PIP_EXTRA_INDEX_URL=${PIP_EXTRA_INDEX_URL:-https://download.pytorch.org/whl/cpu}

if [ ! -d "$VENV_DIR" ]; then
  echo "[+] Creating virtual environment at $VENV_DIR"
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

pip install --upgrade pip
export PIP_EXTRA_INDEX_URL
pip install --requirement "$REQUIREMENTS_FILE"

export PYTHONPATH="$APP_ROOT:${PYTHONPATH:-}"

exec uvicorn app.main:app --host "$HOST" --port "$PORT"
