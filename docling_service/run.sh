#!/usr/bin/env bash
set -euo pipefail

APP_ROOT=$(cd "$(dirname "$0")" && pwd)
VENV_DIR="$APP_ROOT/.venv"
REQUIREMENTS_FILE="$APP_ROOT/requirements.txt"
PYTHON_BIN=${PYTHON_BIN:-python3}
PORT=${PORT:-8042}
HOST=${HOST:-0.0.0.0}
PIP_EXTRA_INDEX_URL=${PIP_EXTRA_INDEX_URL:-https://download.pytorch.org/whl/cpu}
DOCLING_SRC=${DOCLING_SRC:-"$APP_ROOT/../docling"}
USE_LOCAL_DOCLING=${USE_LOCAL_DOCLING:-true}

if [ ! -d "$VENV_DIR" ]; then
  echo "[+] Creating virtual environment at $VENV_DIR"
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

pip install --upgrade pip
export PIP_EXTRA_INDEX_URL
pip install --requirement "$REQUIREMENTS_FILE"

if [ "$USE_LOCAL_DOCLING" = "true" ] && [ -d "$DOCLING_SRC" ] && [ -f "$DOCLING_SRC/pyproject.toml" ]; then
  echo "[+] Installing local docling from $DOCLING_SRC"
  pip install --constraint "$APP_ROOT/constraints.txt" --editable "$DOCLING_SRC"
fi

export PYTHONPATH="$APP_ROOT:${PYTHONPATH:-}"

# Disable uvicorn access logs to reduce noise (use --access-log for verbose mode)
# SSE streaming creates many requests; rely on structured app logs instead
exec uvicorn app.main:app --host "$HOST" --port "$PORT" --no-access-log
