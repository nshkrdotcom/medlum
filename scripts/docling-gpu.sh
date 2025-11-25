#!/usr/bin/env bash
# Docling Docker Image Management Script
# =======================================
# Interactive menu for building, testing, and deploying Docling Docker images.
# Supports both CPU and GPU modes on standardized ports.
#
# Ports (from docling-ports.env):
#   8042 - docker_cpu (Docker, CPU mode)
#   8043 - docker_gpu (Docker, GPU mode)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCLING_DIR="$REPO_ROOT/docling_service"

# Source port definitions
source "$SCRIPT_DIR/docling-ports.env"

# Configuration - Base image (heavy, ~7GB, rebuild monthly)
BASE_IMAGE_NAME="${BASE_IMAGE_NAME:-ghcr.io/nshkrdotcom/lumainus-docling-base}"
BASE_TAG="${BASE_TAG:-latest}"
FULL_BASE_IMAGE="${BASE_IMAGE_NAME}:${BASE_TAG}"

# Configuration - App image (tiny, rebuild on code changes)
IMAGE_NAME="${IMAGE_NAME:-ghcr.io/nshkrdotcom/lumainus-docling-gpu}"
TAG="${TAG:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${TAG}"

# Container names for each mode
CONTAINER_CPU="docling-docker-cpu"
CONTAINER_GPU="docling-docker-gpu"

# Restart policy: no, always, unless-stopped, on-failure
RESTART_POLICY="${DOCLING_RESTART_POLICY:-no}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

print_header() {
    echo -e "\n${CYAN}============================================${NC}"
    echo -e "${CYAN}  Docling Docker Image Manager${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo -e "Base:  ${YELLOW}${FULL_BASE_IMAGE}${NC} (heavy, ~7GB)"
    echo -e "App:   ${YELLOW}${FULL_IMAGE}${NC} (tiny, fast)"
    echo ""
    echo -e "${MAGENTA}Port Assignments:${NC}"
    echo -e "  docker_cpu : ${GREEN}${DOCLING_PORT_DOCKER_CPU}${NC} (container: ${CONTAINER_CPU})"
    echo -e "  docker_gpu : ${GREEN}${DOCLING_PORT_DOCKER_GPU}${NC} (container: ${CONTAINER_GPU})"
    echo ""
    echo -e "Restart policy: ${YELLOW}${RESTART_POLICY}${NC}"
    echo ""
}

print_menu() {
    echo -e "${BLUE}BUILD${NC}"
    echo "  1) Build BASE image (slow, ~10 min, do once)"
    echo "  2) Build APP image (fast, seconds)"
    echo "  3) Build BOTH images"
    echo ""
    echo -e "${BLUE}RUN CONTAINERS${NC}"
    echo "  4) Run docker_cpu  (port ${DOCLING_PORT_DOCKER_CPU}, CPU mode)"
    echo "  5) Run docker_gpu  (port ${DOCLING_PORT_DOCKER_GPU}, GPU mode)"
    echo "  6) Run BOTH containers"
    echo "  7) Stop docker_cpu"
    echo "  8) Stop docker_gpu"
    echo "  9) Stop BOTH containers"
    echo ""
    echo -e "${BLUE}HEALTH & TEST${NC}"
    echo " 10) Health check docker_cpu (:${DOCLING_PORT_DOCKER_CPU})"
    echo " 11) Health check docker_gpu (:${DOCLING_PORT_DOCKER_GPU})"
    echo " 12) Health check ALL backends"
    echo " 13) Test PDF conversion"
    echo " 14) View logs (docker_cpu)"
    echo " 15) View logs (docker_gpu)"
    echo ""
    echo -e "${BLUE}REGISTRY${NC}"
    echo " 16) Login to ghcr.io"
    echo " 17) Push BASE image"
    echo " 18) Push APP image"
    echo " 19) Push BOTH images"
    echo " 20) Check ghcr.io login status"
    echo ""
    echo -e "${BLUE}SETTINGS${NC}"
    echo " 21) Toggle restart policy (current: ${RESTART_POLICY})"
    echo " 22) Show all port assignments"
    echo ""
    echo -e "${BLUE}CLEANUP${NC}"
    echo " 23) Remove local images"
    echo " 24) Prune Docker system"
    echo ""
    echo "  q) Quit"
    echo ""
}

wait_for_service() {
    local port="$1"
    local max_attempts=30
    local attempt=1
    echo -n "Waiting for service on port ${port}"
    while [ $attempt -le $max_attempts ]; do
        if curl -s "http://localhost:${port}/health" > /dev/null 2>&1; then
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

run_docker_cpu() {
    local port="${DOCLING_PORT_DOCKER_CPU}"
    echo -e "\n${YELLOW}Starting ${CONTAINER_CPU} (CPU mode, port ${port})...${NC}"

    # Stop existing container if running
    docker rm -f ${CONTAINER_CPU} 2>/dev/null || true

    docker run -d \
        --name ${CONTAINER_CPU} \
        --restart ${RESTART_POLICY} \
        -p ${port}:${port} \
        -e PORT=${port} \
        "${FULL_IMAGE}"

    wait_for_service "${port}"
    echo -e "Service running at: ${GREEN}http://localhost:${port}${NC}"
}

run_docker_gpu() {
    local port="${DOCLING_PORT_DOCKER_GPU}"
    echo -e "\n${YELLOW}Starting ${CONTAINER_GPU} (GPU mode, port ${port})...${NC}"

    # Check if nvidia-docker is available
    if ! docker info 2>/dev/null | grep -q "Runtimes.*nvidia"; then
        echo -e "${RED}Warning: NVIDIA runtime not detected. GPU may not be available.${NC}"
    fi

    # Stop existing container if running
    docker rm -f ${CONTAINER_GPU} 2>/dev/null || true

    docker run -d \
        --name ${CONTAINER_GPU} \
        --restart ${RESTART_POLICY} \
        --gpus all \
        -p ${port}:${port} \
        -e PORT=${port} \
        "${FULL_IMAGE}"

    wait_for_service "${port}"
    echo -e "Service running at: ${GREEN}http://localhost:${port}${NC}"
}

run_both() {
    run_docker_cpu
    run_docker_gpu
}

stop_docker_cpu() {
    echo -e "\n${YELLOW}Stopping ${CONTAINER_CPU}...${NC}"
    if docker ps -q -f name=${CONTAINER_CPU} | grep -q .; then
        docker stop ${CONTAINER_CPU}
        docker rm ${CONTAINER_CPU}
        echo -e "${GREEN}Container stopped and removed${NC}"
    else
        echo -e "${YELLOW}No running container found${NC}"
    fi
}

stop_docker_gpu() {
    echo -e "\n${YELLOW}Stopping ${CONTAINER_GPU}...${NC}"
    if docker ps -q -f name=${CONTAINER_GPU} | grep -q .; then
        docker stop ${CONTAINER_GPU}
        docker rm ${CONTAINER_GPU}
        echo -e "${GREEN}Container stopped and removed${NC}"
    else
        echo -e "${YELLOW}No running container found${NC}"
    fi
}

stop_both() {
    stop_docker_cpu
    stop_docker_gpu
}

health_check() {
    local port="$1"
    local name="$2"
    echo -e "\n${YELLOW}Health check: ${name} (port ${port})${NC}"
    local response
    if response=$(curl -s -w "\n%{http_code}" "http://localhost:${port}/health" 2>&1); then
        local http_code=$(echo "$response" | tail -1)
        local body=$(echo "$response" | head -n -1)
        if [ "$http_code" = "200" ]; then
            echo -e "${GREEN}${name}: Healthy${NC}"
            echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"
            return 0
        else
            echo -e "${RED}${name}: HTTP $http_code${NC}"
            echo "$body"
            return 1
        fi
    else
        echo -e "${RED}${name}: Unreachable${NC}"
        return 1
    fi
}

health_docker_cpu() {
    health_check "${DOCLING_PORT_DOCKER_CPU}" "docker_cpu"
}

health_docker_gpu() {
    health_check "${DOCLING_PORT_DOCKER_GPU}" "docker_gpu"
}

health_all() {
    echo -e "\n${CYAN}=== Health Check: All Backends ===${NC}"

    echo -e "\n${BLUE}Local Backends:${NC}"
    health_check "${DOCLING_PORT_NATIVE_CPU}" "native_cpu" || true
    health_check "${DOCLING_PORT_NATIVE_GPU}" "native_gpu" || true
    health_check "${DOCLING_PORT_DOCKER_CPU}" "docker_cpu" || true
    health_check "${DOCLING_PORT_DOCKER_GPU}" "docker_gpu" || true

    echo -e "\n${BLUE}Cloud Backends:${NC}"
    if [ -n "${DOCLING_URL_VAST_AI:-}" ]; then
        health_check "${DOCLING_PORT_VAST_AI}" "vast_ai" || true
    else
        echo -e "${YELLOW}vast_ai: Not provisioned${NC}"
    fi
}

test_convert() {
    echo -e "\n${YELLOW}Testing PDF conversion...${NC}"

    # Ask which backend to test
    echo "Which backend to test?"
    echo "  1) docker_cpu (port ${DOCLING_PORT_DOCKER_CPU})"
    echo "  2) docker_gpu (port ${DOCLING_PORT_DOCKER_GPU})"
    echo -n "Select [1]: "
    read -r backend_choice

    local port
    case "${backend_choice:-1}" in
        2) port="${DOCLING_PORT_DOCKER_GPU}" ;;
        *) port="${DOCLING_PORT_DOCKER_CPU}" ;;
    esac

    # Look for a test PDF
    local test_pdf=""
    for f in "$DOCLING_DIR"/*.pdf "$REPO_ROOT"/*.pdf "$REPO_ROOT"/test/fixtures/*.pdf; do
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

    echo "Converting: $test_pdf (via port ${port})"
    local response
    if response=$(curl -s -X POST "http://localhost:${port}/convert" \
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

view_logs_cpu() {
    echo -e "\n${YELLOW}Container logs (${CONTAINER_CPU}, last 50 lines):${NC}"
    if docker ps -a -q -f name=${CONTAINER_CPU} | grep -q .; then
        docker logs --tail 50 ${CONTAINER_CPU}
    else
        echo -e "${YELLOW}Container not found${NC}"
    fi
}

view_logs_gpu() {
    echo -e "\n${YELLOW}Container logs (${CONTAINER_GPU}, last 50 lines):${NC}"
    if docker ps -a -q -f name=${CONTAINER_GPU} | grep -q .; then
        docker logs --tail 50 ${CONTAINER_GPU}
    else
        echo -e "${YELLOW}Container not found${NC}"
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
        echo "Run option 16 to login"
    fi
}

toggle_restart_policy() {
    echo -e "\n${YELLOW}Current restart policy: ${RESTART_POLICY}${NC}"
    echo ""
    echo "Select new restart policy:"
    echo "  1) no              - Never restart"
    echo "  2) always          - Always restart"
    echo "  3) unless-stopped  - Restart unless manually stopped (survives reboot)"
    echo "  4) on-failure      - Restart only on failure"
    echo ""
    echo -n "Select [1-4]: "
    read -r policy_choice

    case "${policy_choice}" in
        1) RESTART_POLICY="no" ;;
        2) RESTART_POLICY="always" ;;
        3) RESTART_POLICY="unless-stopped" ;;
        4) RESTART_POLICY="on-failure" ;;
        *) echo -e "${RED}Invalid choice${NC}"; return ;;
    esac

    export DOCLING_RESTART_POLICY="$RESTART_POLICY"
    echo -e "${GREEN}Restart policy set to: ${RESTART_POLICY}${NC}"
    echo ""
    echo "Note: This applies to newly started containers."
    echo "To persist across shell sessions, add to your environment:"
    echo "  export DOCLING_RESTART_POLICY=${RESTART_POLICY}"
}

show_ports() {
    echo -e "\n${CYAN}=== Docling Port Assignments ===${NC}"
    docling_print_ports
    echo ""
    echo -e "${BLUE}Container Status:${NC}"
    echo -n "  docker_cpu (${CONTAINER_CPU}): "
    if docker ps -q -f name=${CONTAINER_CPU} | grep -q .; then
        echo -e "${GREEN}Running${NC}"
    else
        echo -e "${YELLOW}Stopped${NC}"
    fi
    echo -n "  docker_gpu (${CONTAINER_GPU}): "
    if docker ps -q -f name=${CONTAINER_GPU} | grep -q .; then
        echo -e "${GREEN}Running${NC}"
    else
        echo -e "${YELLOW}Stopped${NC}"
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
            4) run_docker_cpu ;;
            5) run_docker_gpu ;;
            6) run_both ;;
            7) stop_docker_cpu ;;
            8) stop_docker_gpu ;;
            9) stop_both ;;
            10) health_docker_cpu ;;
            11) health_docker_gpu ;;
            12) health_all ;;
            13) test_convert ;;
            14) view_logs_cpu ;;
            15) view_logs_gpu ;;
            16) ghcr_login ;;
            17) push_base_image ;;
            18) push_app_image ;;
            19) push_both ;;
            20) check_login ;;
            21) toggle_restart_policy ;;
            22) show_ports ;;
            23) remove_images ;;
            24) prune_docker ;;
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
        run-cpu) run_docker_cpu ;;
        run-gpu) run_docker_gpu ;;
        run-both) run_both ;;
        stop-cpu) stop_docker_cpu ;;
        stop-gpu) stop_docker_gpu ;;
        stop-both|stop) stop_both ;;
        health-cpu) health_docker_cpu ;;
        health-gpu) health_docker_gpu ;;
        health-all|health) health_all ;;
        convert) test_convert ;;
        logs-cpu) view_logs_cpu ;;
        logs-gpu) view_logs_gpu ;;
        login) ghcr_login ;;
        push-base) push_base_image ;;
        push-app|push) push_app_image ;;
        push-all) push_both ;;
        ports) show_ports ;;
        *)
            echo "Docling Docker Manager"
            echo ""
            echo "Usage: $0 <command>"
            echo ""
            echo "Build Commands:"
            echo "  build-base   Build BASE image (~7GB, do once)"
            echo "  build-app    Build APP image (fast)"
            echo "  build-all    Build both images"
            echo ""
            echo "Run Commands:"
            echo "  run-cpu      Run docker_cpu (port ${DOCLING_PORT_DOCKER_CPU})"
            echo "  run-gpu      Run docker_gpu (port ${DOCLING_PORT_DOCKER_GPU})"
            echo "  run-both     Run both containers"
            echo "  stop-cpu     Stop docker_cpu"
            echo "  stop-gpu     Stop docker_gpu"
            echo "  stop-both    Stop both containers"
            echo ""
            echo "Health & Test:"
            echo "  health-cpu   Health check docker_cpu"
            echo "  health-gpu   Health check docker_gpu"
            echo "  health-all   Health check all backends"
            echo "  convert      Test PDF conversion"
            echo "  logs-cpu     View docker_cpu logs"
            echo "  logs-gpu     View docker_gpu logs"
            echo ""
            echo "Registry:"
            echo "  login        Login to ghcr.io"
            echo "  push-base    Push BASE image"
            echo "  push-app     Push APP image"
            echo "  push-all     Push both images"
            echo ""
            echo "Info:"
            echo "  ports        Show all port assignments"
            echo ""
            echo "Environment Variables:"
            echo "  DOCLING_RESTART_POLICY  Restart policy (no, always, unless-stopped, on-failure)"
            echo "  BASE_IMAGE_NAME         Base image name"
            echo "  IMAGE_NAME              App image name"
            echo "  GHCR_USER               GitHub username for registry"
            echo "  GHCR_TOKEN              GitHub PAT for registry"
            exit 1
            ;;
    esac
else
    main
fi
