#!/usr/bin/env bash
# Run docling_service Python tests
# Usage: ./scripts/run_tests.sh [pytest-args]
#
# Examples:
#   ./scripts/run_tests.sh                    # Run all tests
#   ./scripts/run_tests.sh -v                 # Verbose
#   ./scripts/run_tests.sh -k test_sse        # Run only SSE tests
#   ./scripts/run_tests.sh --cov=app          # With coverage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Create venv if needed
if [ ! -d ".venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv .venv
fi

# Activate and install deps
source .venv/bin/activate

# Install test dependencies
pip install -q pytest pytest-asyncio asgi-lifespan httpx pytest-cov 2>/dev/null

# Install app dependencies
pip install -q -r requirements.txt 2>/dev/null

echo "Running tests..."
echo "================"

# Run pytest with any passed arguments
python -m pytest tests/ "$@"
