#!/usr/bin/env bash
# Docling GPU Image Management Script
# Interactive menu for building, testing, and deploying the Docling GPU Docker image

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCLING_DIR="$REPO_ROOT/docling_service"

# Configuration - Base image (heavy, ~7GB, rebuild monthly)
BASE_IMAGE_NAME="${BASE_IMAGE_NAME:-ghcr.io/nshkrdotcom/lumainus-docling-base}"
BASE_TAG="${BASE_TAG:-latest}"
FULL_BASE_IMAGE="${BASE_IMAGE_NAME}:${BASE_TAG}"

# Configuration - App image (tiny, rebuild on code changes)
IMAGE_NAME="${IMAGE_NAME:-ghcr.io/nshkrdotcom/lumainus-docling-gpu}"
TAG="${TAG:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${TAG}"

CONTAINER_NAME="docling-gpu-test"
PORT=8042

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_header() {
    echo -e "\n${CYAN}============================================${NC}"
    echo -e "${CYAN}  Docling GPU Image Manager${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo -e "Base:  ${YELLOW}${FULL_BASE_IMAGE}${NC} (heavy, ~7GB)"
    echo -e "App:   ${YELLOW}${FULL_IMAGE}${NC} (tiny, fast)"
    echo ""
}

print_menu() {
    echo -e "${BLUE}BUILD & TEST${NC}"
    echo "  1) Build BASE image (slow, ~10 min, do once)"
    echo "  2) Build APP image (fast, seconds)"
    echo "  3) Build BOTH images"
    echo "  4) Run locally (CPU mode)"
    echo "  5) Run locally (GPU mode)"
    echo "  6) Stop running container"
    echo ""
    echo -e "${BLUE}HEALTH CHECKS${NC}"
    echo "  7) Test health endpoint"
    echo "  8) Test PDF conversion"
    echo "  9) View container logs"
    echo ""
    echo -e "${BLUE}REGISTRY${NC}"
    echo " 10) Login to ghcr.io"
    echo " 11) Push BASE image (do once)"
    echo " 12) Push APP image (fast)"
    echo " 13) Push BOTH images"
    echo " 14) Check ghcr.io login status"
    echo ""
    echo -e "${BLUE}CLEANUP${NC}"
    echo " 15) Remove local images"
    echo " 16) Prune Docker system"
    echo ""
    echo "  q) Quit"
    echo ""
}

wait_for_service() {
    local max_attempts=30
    local attempt=1
    echo -n "Waiting for service to start"
    while [ $attempt -le $max_attempts ]; do
        if curl -s http://localhost:${PORT}/health > /dev/null 2>&1; then
            echo -e " ${GREEN}Ready!${NC}"
            return 0
        fi
        echo -n "."
        sleep 2
        ((attempt++))
    done
    echo -e " ${RED}Timeout${NC}"
    return 1
}

build_base_image() {
    echo -e "\n${YELLOW}Building BASE image (this takes ~10 min)...${NC}"
    cd "$REPO_ROOT"
    docker build \
        -f docling_service/Dockerfile.gpu-base \
        -t "${FULL_BASE_IMAGE}" \
        --build-arg BUILDKIT_INLINE_CACHE=1 \
        .
    echo -e "${GREEN}Build complete: ${FULL_BASE_IMAGE}${NC}"
}

build_app_image() {
    echo -e "\n${YELLOW}Building APP image...${NC}"

    # Check if base image exists locally or try to pull it
    if ! docker image inspect "${FULL_BASE_IMAGE}" &>/dev/null; then
        echo -e "${YELLOW}Base image not found locally. Trying to pull...${NC}"
        if docker pull "${FULL_BASE_IMAGE}"; then
            echo -e "${GREEN}Pulled base image from registry${NC}"
        else
            echo -e "${RED}Could not pull base image: ${FULL_BASE_IMAGE}${NC}"
            echo "Run option 1 first to build the base image locally."
            return 1
        fi
    fi

    cd "$REPO_ROOT"
    docker build \
        -f docling_service/Dockerfile.gpu \
        -t "${FULL_IMAGE}" \
        --build-arg BASE_IMAGE="${FULL_BASE_IMAGE}" \
        .
    echo -e "${GREEN}Build complete: ${FULL_IMAGE}${NC}"
}

build_both() {
    build_base_image
    build_app_image
}

run_cpu() {
    echo -e "\n${YELLOW}Starting container (CPU mode)...${NC}"

    # Stop existing container if running
    docker rm -f ${CONTAINER_NAME} 2>/dev/null || true

    docker run -d \
        --name ${CONTAINER_NAME} \
        -p ${PORT}:${PORT} \
        "${FULL_IMAGE}"

    wait_for_service
    echo -e "Service running at: ${GREEN}http://localhost:${PORT}${NC}"
}

run_gpu() {
    echo -e "\n${YELLOW}Starting container (GPU mode)...${NC}"

    # Check if nvidia-docker is available
    if ! docker info 2>/dev/null | grep -q "Runtimes.*nvidia"; then
        echo -e "${RED}Warning: NVIDIA runtime not detected. GPU may not be available.${NC}"
    fi

    # Stop existing container if running
    docker rm -f ${CONTAINER_NAME} 2>/dev/null || true

    docker run -d \
        --name ${CONTAINER_NAME} \
        --gpus all \
        -p ${PORT}:${PORT} \
        "${FULL_IMAGE}"

    wait_for_service
    echo -e "Service running at: ${GREEN}http://localhost:${PORT}${NC}"
}

stop_container() {
    echo -e "\n${YELLOW}Stopping container...${NC}"
    if docker ps -q -f name=${CONTAINER_NAME} | grep -q .; then
        docker stop ${CONTAINER_NAME}
        docker rm ${CONTAINER_NAME}
        echo -e "${GREEN}Container stopped and removed${NC}"
    else
        echo -e "${YELLOW}No running container found${NC}"
    fi
}

test_health() {
    echo -e "\n${YELLOW}Testing health endpoint...${NC}"
    local response
    if response=$(curl -s -w "\n%{http_code}" http://localhost:${PORT}/health 2>&1); then
        local http_code=$(echo "$response" | tail -1)
        local body=$(echo "$response" | head -n -1)
        if [ "$http_code" = "200" ]; then
            echo -e "${GREEN}Health check passed!${NC}"
            echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"
        else
            echo -e "${RED}Health check failed (HTTP $http_code)${NC}"
            echo "$body"
        fi
    else
        echo -e "${RED}Could not connect to service at http://localhost:${PORT}${NC}"
        echo "Is the container running?"
    fi
}

test_convert() {
    echo -e "\n${YELLOW}Testing PDF conversion...${NC}"

    # Look for a test PDF
    local test_pdf=""
    for f in "$DOCLING_DIR"/*.pdf "$REPO_ROOT"/*.pdf; do
        if [ -f "$f" ]; then
            test_pdf="$f"
            break
        fi
    done

    if [ -z "$test_pdf" ]; then
        echo -e "${YELLOW}No test PDF found. Enter path to a PDF file:${NC}"
        read -r test_pdf
        if [ ! -f "$test_pdf" ]; then
            echo -e "${RED}File not found: $test_pdf${NC}"
            return 1
        fi
    fi

    echo "Converting: $test_pdf"
    local response
    if response=$(curl -s -X POST http://localhost:${PORT}/convert \
        -F "file=@${test_pdf}" \
        -w "\n%{http_code}" 2>&1); then
        local http_code=$(echo "$response" | tail -1)
        local body=$(echo "$response" | head -n -1)
        if [ "$http_code" = "200" ]; then
            echo -e "${GREEN}Conversion successful!${NC}"
            # Show first 500 chars of markdown
            echo -e "\n${CYAN}Markdown preview (first 500 chars):${NC}"
            echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('markdown','')[:500])" 2>/dev/null || echo "$body" | head -c 500
            echo "..."
        else
            echo -e "${RED}Conversion failed (HTTP $http_code)${NC}"
            echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"
        fi
    else
        echo -e "${RED}Could not connect to service${NC}"
    fi
}

view_logs() {
    echo -e "\n${YELLOW}Container logs (last 50 lines):${NC}"
    if docker ps -q -f name=${CONTAINER_NAME} | grep -q .; then
        docker logs --tail 50 ${CONTAINER_NAME}
    else
        echo -e "${YELLOW}No running container found${NC}"
    fi
}

ghcr_login() {
    echo -e "\n${YELLOW}Logging into ghcr.io...${NC}"

    local ghcr_user="${GHCR_USER:-}"
    local ghcr_token="${GHCR_TOKEN:-}"

    if [ -z "$ghcr_user" ]; then
        echo -n "GitHub username: "
        read -r ghcr_user
    else
        echo "Using GHCR_USER: $ghcr_user"
    fi

    if [ -z "$ghcr_token" ]; then
        echo -n "GitHub PAT (with write:packages scope): "
        read -rs ghcr_token
        echo ""
    else
        echo "Using GHCR_TOKEN from environment"
    fi

    if echo "$ghcr_token" | docker login ghcr.io -u "$ghcr_user" --password-stdin; then
        echo -e "${GREEN}Successfully logged in to ghcr.io${NC}"
    else
        echo -e "${RED}Login failed${NC}"
    fi
}

push_base_image() {
    echo -e "\n${YELLOW}Pushing BASE image to ghcr.io (~7GB, takes a while first time)...${NC}"
    docker push "${FULL_BASE_IMAGE}"
    echo -e "${GREEN}Push complete: ${FULL_BASE_IMAGE}${NC}"
}

push_app_image() {
    echo -e "\n${YELLOW}Pushing APP image to ghcr.io (tiny, fast)...${NC}"
    docker push "${FULL_IMAGE}"
    echo -e "${GREEN}Push complete: ${FULL_IMAGE}${NC}"
}

push_both() {
    push_base_image
    push_app_image
}

check_login() {
    echo -e "\n${YELLOW}Checking ghcr.io login status...${NC}"
    if grep -q "ghcr.io" ~/.docker/config.json 2>/dev/null; then
        echo -e "${GREEN}Credentials found for ghcr.io${NC}"
        echo "Config file: ~/.docker/config.json"
    else
        echo -e "${YELLOW}No ghcr.io credentials found in Docker config${NC}"
        echo "Run option 8 to login"
    fi
}

remove_images() {
    echo -e "\n${YELLOW}Removing local images...${NC}"
    docker rmi "${FULL_IMAGE}" 2>/dev/null && \
        echo -e "${GREEN}App image removed${NC}" || \
        echo -e "${YELLOW}App image not found or in use${NC}"
    docker rmi "${FULL_BASE_IMAGE}" 2>/dev/null && \
        echo -e "${GREEN}Base image removed${NC}" || \
        echo -e "${YELLOW}Base image not found or in use${NC}"
}

prune_docker() {
    echo -e "\n${YELLOW}Pruning Docker system...${NC}"
    echo "This will remove:"
    echo "  - All stopped containers"
    echo "  - All networks not used by containers"
    echo "  - All dangling images"
    echo "  - All build cache"
    echo ""
    echo -n "Continue? [y/N] "
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        docker system prune -f
        echo -e "${GREEN}Prune complete${NC}"
    else
        echo "Cancelled"
    fi
}

# Main loop
main() {
    while true; do
        print_header
        print_menu

        echo -n "Select option: "
        read -r choice

        case $choice in
            1) build_base_image ;;
            2) build_app_image ;;
            3) build_both ;;
            4) run_cpu ;;
            5) run_gpu ;;
            6) stop_container ;;
            7) test_health ;;
            8) test_convert ;;
            9) view_logs ;;
            10) ghcr_login ;;
            11) push_base_image ;;
            12) push_app_image ;;
            13) push_both ;;
            14) check_login ;;
            15) remove_images ;;
            16) prune_docker ;;
            q|Q) echo "Goodbye!"; exit 0 ;;
            *) echo -e "${RED}Invalid option${NC}" ;;
        esac

        echo ""
        echo -n "Press Enter to continue..."
        read -r
    done
}

# Handle command line arguments for non-interactive use
if [ $# -gt 0 ]; then
    case $1 in
        build-base) build_base_image ;;
        build-app|build) build_app_image ;;
        build-all) build_both ;;
        run) run_cpu ;;
        run-gpu) run_gpu ;;
        stop) stop_container ;;
        health) test_health ;;
        convert) test_convert ;;
        logs) view_logs ;;
        login) ghcr_login ;;
        push-base) push_base_image ;;
        push-app|push) push_app_image ;;
        push-all) push_both ;;
        *)
            echo "Usage: $0 <command>"
            echo ""
            echo "Commands:"
            echo "  build-base   Build BASE image (~7GB, do once)"
            echo "  build-app    Build APP image (fast)"
            echo "  build-all    Build both images"
            echo "  run          Run container (CPU)"
            echo "  run-gpu      Run container (GPU)"
            echo "  stop         Stop container"
            echo "  health       Test health endpoint"
            echo "  convert      Test PDF conversion"
            echo "  logs         View container logs"
            echo "  login        Login to ghcr.io"
            echo "  push-base    Push BASE image"
            echo "  push-app     Push APP image"
            echo "  push-all     Push both images"
            exit 1
            ;;
    esac
else
    main
fi
