#!/usr/bin/env bash
# Helper to run both the Phoenix dev server and the Docling ingestion service.
# This is intended for local development only so that `/reports` can talk to the
# PDF-to-Markdown microservice without starting two shells manually.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
DOC_SERVICE_DIR="$ROOT_DIR/docling_service"
DOC_SERVICE_RUN="$DOC_SERVICE_DIR/run.sh"
PHX_CMD=${PHX_CMD:-mix phx.server}
MIX_ENV=${MIX_ENV:-dev}
DOCLING_HOST=${DOCLING_HOST:-127.0.0.1}
DOCLING_PORT=${DOCLING_PORT:-8042}
DOCLING_PYTHON_BIN=${DOCLING_PYTHON_BIN:-python3}

if [[ "$MIX_ENV" != "dev" ]]; then
  echo "[dev-stack] This helper only runs with MIX_ENV=dev (current: $MIX_ENV)" >&2
  exit 1
fi

if [[ ! -x "$DOC_SERVICE_RUN" ]]; then
  echo "[dev-stack] Could not find docling_service/run.sh at $DOC_SERVICE_RUN" >&2
  echo "[dev-stack] Make sure you've cloned the repo with subdirectories intact." >&2
  exit 1
fi

DOCLING_PID=""

cleanup() {
  local exit_code=${1:-$?}
  if [[ -n "$DOCLING_PID" ]] && kill -0 "$DOCLING_PID" 2>/dev/null; then
    echo "[dev-stack] Stopping Docling service (pid=$DOCLING_PID)"
    kill "$DOCLING_PID" 2>/dev/null || true
    wait "$DOCLING_PID" 2>/dev/null || true
  fi
  return "$exit_code"
}

trap 'cleanup 130; exit 130' INT
trap 'cleanup 143; exit 143' TERM

echo "[dev-stack] Starting Docling service on ${DOCLING_HOST}:${DOCLING_PORT}"
(
  cd "$DOC_SERVICE_DIR"
  HOST="$DOCLING_HOST" PORT="$DOCLING_PORT" PYTHON_BIN="$DOCLING_PYTHON_BIN" ./run.sh
) &
DOCLING_PID=$!

sleep 1
if ! kill -0 "$DOCLING_PID" 2>/dev/null; then
  echo "[dev-stack] Docling process exited immediately. Check logs above." >&2
  cleanup 1
fi

echo "[dev-stack] Starting Phoenix server via '$PHX_CMD' (MIX_ENV=$MIX_ENV)"
cd "$ROOT_DIR"
MIX_ENV="$MIX_ENV" $PHX_CMD
exit_code=$?
trap - INT TERM
cleanup "$exit_code"
exit "$exit_code"
