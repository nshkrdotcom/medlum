#!/usr/bin/env bash
# Build the GPU-enabled Docling Docker image
# Usage: ./build-gpu-image.sh [tag]
#
# Prerequisites:
#   - Docker installed and running
#   - For GPU testing: nvidia-docker / NVIDIA Container Toolkit
#
# Examples:
#   ./build-gpu-image.sh                    # builds :latest
#   ./build-gpu-image.sh v1.0.0             # builds :v1.0.0
#   ./build-gpu-image.sh dev                # builds :dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
IMAGE_NAME="${IMAGE_NAME:-ghcr.io/nshkrdotcom/medlum-docling-gpu}"
TAG="${1:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${TAG}"

echo "=============================================="
echo "Building Docling GPU Image"
echo "=============================================="
echo "Image: ${FULL_IMAGE}"
echo "Context: ${REPO_ROOT}"
echo "Dockerfile: ${SCRIPT_DIR}/Dockerfile.gpu"
echo "=============================================="

cd "$REPO_ROOT"

# Build the image
docker build \
    -f docling_service/Dockerfile.gpu \
    -t "${FULL_IMAGE}" \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    .

echo ""
echo "=============================================="
echo "Build complete: ${FULL_IMAGE}"
echo "=============================================="
echo ""
echo "Next steps:"
echo ""
echo "1. Test locally (CPU mode):"
echo "   docker run -p 8042:8042 ${FULL_IMAGE}"
echo ""
echo "2. Test locally (GPU mode, requires nvidia-docker):"
echo "   docker run --gpus all -p 8042:8042 ${FULL_IMAGE}"
echo ""
echo "3. Verify health:"
echo "   curl http://localhost:8042/health"
echo ""
echo "4. Push to registry:"
echo "   docker push ${FULL_IMAGE}"
echo ""
