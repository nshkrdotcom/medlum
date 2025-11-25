#!/usr/bin/env bash
# Docling Docker Compose Manager
# ==============================
# Interactive menu for managing Docling services via docker-compose.
#
# Ports (from docling-ports.env):
#   8042 - docker_cpu (Docker, CPU mode)
#   8043 - docker_gpu (Docker, GPU mode)
#
# Usage:
#   ./docling-compose.sh              # Interactive menu
#   ./docling-compose.sh <command>    # Direct command

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/docker-compose.yml"

# Source port definitions
source "$SCRIPT_DIR/docling-ports.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Check for docker compose
COMPOSE_CMD=""
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    echo -e "${RED}Error: docker compose not found${NC}"
    echo "Install Docker with Compose plugin or docker-compose standalone"
    exit 1
fi

print_header() {
    echo -e "\n${CYAN}============================================${NC}"
    echo -e "${CYAN}  Docling Docker Compose Manager${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo -e "Compose file: ${YELLOW}${COMPOSE_FILE}${NC}"
    echo ""
    echo -e "${MAGENTA}Services:${NC}"
    echo -e "  docling-cpu : port ${GREEN}${DOCLING_PORT_DOCKER_CPU}${NC} (CPU mode)"
    echo -e "  docling-gpu : port ${GREEN}${DOCLING_PORT_DOCKER_GPU}${NC} (GPU mode, requires --profile gpu)"
    echo ""
}

print_menu() {
    echo -e "${BLUE}START SERVICES${NC}"
    echo "  1) Start CPU service only"
    echo "  2) Start GPU service only"
    echo "  3) Start BOTH services (CPU + GPU)"
    echo "  4) Start in foreground (attached, CPU)"
    echo "  5) Start in foreground (attached, GPU)"
    echo ""
    echo -e "${BLUE}STOP SERVICES${NC}"
    echo "  6) Stop CPU service"
    echo "  7) Stop GPU service"
    echo "  8) Stop ALL services"
    echo "  9) Stop and remove volumes"
    echo ""
    echo -e "${BLUE}STATUS & LOGS${NC}"
    echo " 10) Show running containers (ps)"
    echo " 11) Show all containers (ps -a)"
    echo " 12) Show logs (CPU, follow)"
    echo " 13) Show logs (GPU, follow)"
    echo " 14) Show logs (all, tail 50)"
    echo ""
    echo -e "${BLUE}HEALTH & TEST${NC}"
    echo " 15) Health check CPU (:${DOCLING_PORT_DOCKER_CPU})"
    echo " 16) Health check GPU (:${DOCLING_PORT_DOCKER_GPU})"
    echo " 17) Health check BOTH"
    echo ""
    echo -e "${BLUE}MANAGEMENT${NC}"
    echo " 18) Restart CPU service"
    echo " 19) Restart GPU service"
    echo " 20) Restart ALL services"
    echo " 21) Pull latest images"
    echo " 22) Build images locally"
    echo ""
    echo -e "${BLUE}AUTO-START ON REBOOT${NC}"
    # Show current restart policy state
    local cpu_restart gpu_restart cpu_color gpu_color
    cpu_restart=$(docker inspect --format='{{.HostConfig.RestartPolicy.Name}}' docling-docker-cpu 2>/dev/null | tr -d '\n' || true)
    gpu_restart=$(docker inspect --format='{{.HostConfig.RestartPolicy.Name}}' docling-docker-gpu 2>/dev/null | tr -d '\n' || true)
    [[ -z "$cpu_restart" ]] && cpu_restart="none"
    [[ -z "$gpu_restart" ]] && gpu_restart="none"
    cpu_color="${RED}"; gpu_color="${RED}"
    [[ "$cpu_restart" == "always" ]] && cpu_color="${GREEN}"
    [[ "$gpu_restart" == "always" ]] && gpu_color="${GREEN}"
    echo -e "     Current: CPU=${cpu_color}${cpu_restart}${NC}  GPU=${gpu_color}${gpu_restart}${NC}"
    echo " 23) Enable auto-start (restart: always)"
    echo " 24) Disable auto-start (restart: no)"
    echo ""
    echo -e "${BLUE}ADVANCED${NC}"
    echo " 25) Execute shell in CPU container"
    echo " 26) Execute shell in GPU container"
    echo " 27) Show compose config"
    echo " 28) Validate compose file"
    echo " 29) Show service ports"
    echo ""
    echo -e "${BLUE}CLEANUP${NC}"
    echo " 30) Remove stopped containers"
    echo " 31) Remove all (containers + networks)"
    echo " 32) Prune unused images"
    echo ""
    echo "  q) Quit"
    echo ""
}

# Helper to run compose commands
compose() {
    cd "$REPO_ROOT"
    $COMPOSE_CMD -f "$COMPOSE_FILE" "$@"
}

# Start services
start_cpu() {
    echo -e "\n${YELLOW}Starting CPU service...${NC}"
    compose up -d docling-cpu
    echo -e "${GREEN}CPU service started on port ${DOCLING_PORT_DOCKER_CPU}${NC}"
}

start_gpu() {
    echo -e "\n${YELLOW}Starting GPU service...${NC}"
    compose --profile gpu up -d docling-gpu
    echo -e "${GREEN}GPU service started on port ${DOCLING_PORT_DOCKER_GPU}${NC}"
}

start_both() {
    echo -e "\n${YELLOW}Starting both services...${NC}"
    compose --profile gpu up -d
    echo -e "${GREEN}Both services started${NC}"
}

start_cpu_attached() {
    echo -e "\n${YELLOW}Starting CPU service (attached)...${NC}"
    echo "Press Ctrl+C to stop"
    compose up docling-cpu
}

start_gpu_attached() {
    echo -e "\n${YELLOW}Starting GPU service (attached)...${NC}"
    echo "Press Ctrl+C to stop"
    compose --profile gpu up docling-gpu
}

# Stop services
stop_cpu() {
    echo -e "\n${YELLOW}Stopping CPU service...${NC}"
    compose stop docling-cpu
    echo -e "${GREEN}CPU service stopped${NC}"
}

stop_gpu() {
    echo -e "\n${YELLOW}Stopping GPU service...${NC}"
    compose --profile gpu stop docling-gpu
    echo -e "${GREEN}GPU service stopped${NC}"
}

stop_all() {
    echo -e "\n${YELLOW}Stopping all services...${NC}"
    compose --profile gpu down
    echo -e "${GREEN}All services stopped${NC}"
}

stop_with_volumes() {
    echo -e "\n${YELLOW}Stopping all services and removing volumes...${NC}"
    compose --profile gpu down -v
    echo -e "${GREEN}All services stopped, volumes removed${NC}"
}

# Status & Logs
show_ps() {
    echo -e "\n${CYAN}Running containers:${NC}"
    compose ps
}

show_ps_all() {
    echo -e "\n${CYAN}All containers:${NC}"
    compose ps -a
}

logs_cpu() {
    echo -e "\n${CYAN}CPU service logs (Ctrl+C to exit):${NC}"
    compose logs -f docling-cpu
}

logs_gpu() {
    echo -e "\n${CYAN}GPU service logs (Ctrl+C to exit):${NC}"
    compose --profile gpu logs -f docling-gpu
}

logs_all() {
    echo -e "\n${CYAN}All service logs (last 50 lines):${NC}"
    compose --profile gpu logs --tail 50
}

# Health checks
health_check() {
    local port="$1"
    local name="$2"
    echo -n "  $name (:$port): "
    if response=$(curl -s -w "%{http_code}" "http://localhost:${port}/health" -o /tmp/health_body 2>&1); then
        if [ "$response" = "200" ]; then
            echo -e "${GREEN}Healthy${NC}"
            cat /tmp/health_body | python3 -m json.tool 2>/dev/null | head -5 || true
        else
            echo -e "${RED}HTTP $response${NC}"
        fi
    else
        echo -e "${RED}Unreachable${NC}"
    fi
}

health_cpu() {
    echo -e "\n${CYAN}Health Check:${NC}"
    health_check "${DOCLING_PORT_DOCKER_CPU}" "CPU"
}

health_gpu() {
    echo -e "\n${CYAN}Health Check:${NC}"
    health_check "${DOCLING_PORT_DOCKER_GPU}" "GPU"
}

health_both() {
    echo -e "\n${CYAN}Health Check:${NC}"
    health_check "${DOCLING_PORT_DOCKER_CPU}" "CPU"
    health_check "${DOCLING_PORT_DOCKER_GPU}" "GPU"
}

# Management
restart_cpu() {
    echo -e "\n${YELLOW}Restarting CPU service...${NC}"
    compose restart docling-cpu
    echo -e "${GREEN}CPU service restarted${NC}"
}

restart_gpu() {
    echo -e "\n${YELLOW}Restarting GPU service...${NC}"
    compose --profile gpu restart docling-gpu
    echo -e "${GREEN}GPU service restarted${NC}"
}

restart_all() {
    echo -e "\n${YELLOW}Restarting all services...${NC}"
    compose --profile gpu restart
    echo -e "${GREEN}All services restarted${NC}"
}

pull_images() {
    echo -e "\n${YELLOW}Pulling latest images...${NC}"
    compose --profile gpu pull
    echo -e "${GREEN}Images pulled${NC}"
}

build_images() {
    echo -e "\n${YELLOW}Building images...${NC}"
    compose --profile gpu build
    echo -e "${GREEN}Images built${NC}"
}

# Auto-start on reboot
# Container names from docker-compose.yml
CPU_CONTAINER="docling-docker-cpu"
GPU_CONTAINER="docling-docker-gpu"

enable_autostart() {
    echo -e "\n${YELLOW}Enabling auto-start on reboot...${NC}"

    # Check if CPU container exists
    local cpu_container=$(docker ps -a -q -f name="^${CPU_CONTAINER}$" 2>/dev/null)
    if [ -z "$cpu_container" ]; then
        echo -e "  ${CYAN}CPU container doesn't exist, starting it...${NC}"
        compose up -d docling-cpu
        sleep 2
        cpu_container=$(docker ps -q -f name="^${CPU_CONTAINER}$" 2>/dev/null)
    fi

    if [ -n "$cpu_container" ]; then
        docker update --restart=always "$cpu_container"
        echo -e "  ${GREEN}CPU container: restart=always${NC}"
    else
        echo -e "  ${RED}CPU container failed to start${NC}"
    fi

    # Check if GPU container exists
    local gpu_container=$(docker ps -a -q -f name="^${GPU_CONTAINER}$" 2>/dev/null)
    if [ -z "$gpu_container" ]; then
        echo -e "  ${CYAN}GPU container doesn't exist, starting it...${NC}"
        compose --profile gpu up -d docling-gpu
        sleep 2
        gpu_container=$(docker ps -q -f name="^${GPU_CONTAINER}$" 2>/dev/null)
    fi

    if [ -n "$gpu_container" ]; then
        docker update --restart=always "$gpu_container"
        echo -e "  ${GREEN}GPU container: restart=always${NC}"
    else
        echo -e "  ${RED}GPU container failed to start (may need GPU)${NC}"
    fi

    echo -e "\n${GREEN}Done. Containers with restart=always will auto-start on reboot.${NC}"
}

disable_autostart() {
    echo -e "\n${YELLOW}Disabling auto-start on reboot...${NC}"
    local cpu_container=$(docker ps -a -q -f name="^${CPU_CONTAINER}$" 2>/dev/null)
    local gpu_container=$(docker ps -a -q -f name="^${GPU_CONTAINER}$" 2>/dev/null)

    if [ -n "$cpu_container" ]; then
        docker update --restart=no "$cpu_container"
        echo -e "  ${GREEN}CPU container: restart=no${NC}"
    else
        echo -e "  ${YELLOW}CPU container doesn't exist (nothing to disable)${NC}"
    fi

    if [ -n "$gpu_container" ]; then
        docker update --restart=no "$gpu_container"
        echo -e "  ${GREEN}GPU container: restart=no${NC}"
    else
        echo -e "  ${YELLOW}GPU container doesn't exist (nothing to disable)${NC}"
    fi

    echo -e "\n${GREEN}Done. Containers will NOT auto-start on reboot.${NC}"
}

# Advanced
shell_cpu() {
    echo -e "\n${CYAN}Opening shell in CPU container...${NC}"
    compose exec docling-cpu /bin/bash || compose exec docling-cpu /bin/sh
}

shell_gpu() {
    echo -e "\n${CYAN}Opening shell in GPU container...${NC}"
    compose --profile gpu exec docling-gpu /bin/bash || compose --profile gpu exec docling-gpu /bin/sh
}

show_config() {
    echo -e "\n${CYAN}Compose configuration:${NC}"
    compose --profile gpu config
}

validate_config() {
    echo -e "\n${CYAN}Validating compose file...${NC}"
    if compose --profile gpu config -q; then
        echo -e "${GREEN}Compose file is valid${NC}"
    else
        echo -e "${RED}Compose file has errors${NC}"
    fi
}

show_ports() {
    echo -e "\n${CYAN}Service ports:${NC}"
    compose --profile gpu port docling-cpu 8042 2>/dev/null || echo "  CPU: not running"
    compose --profile gpu port docling-gpu 8043 2>/dev/null || echo "  GPU: not running"
    echo ""
    echo "Expected ports:"
    docling_print_ports | grep -E "docker_cpu|docker_gpu"
}

# Cleanup
remove_stopped() {
    echo -e "\n${YELLOW}Removing stopped containers...${NC}"
    compose --profile gpu rm -f
    echo -e "${GREEN}Stopped containers removed${NC}"
}

remove_all() {
    echo -e "\n${YELLOW}Removing all containers and networks...${NC}"
    compose --profile gpu down --remove-orphans
    echo -e "${GREEN}All containers and networks removed${NC}"
}

prune_images() {
    echo -e "\n${YELLOW}Pruning unused images...${NC}"
    docker image prune -f
    echo -e "${GREEN}Unused images pruned${NC}"
}

# Main loop
main() {
    while true; do
        print_header
        print_menu

        echo -n "Select option: "
        read -r choice

        case $choice in
            1) start_cpu ;;
            2) start_gpu ;;
            3) start_both ;;
            4) start_cpu_attached ;;
            5) start_gpu_attached ;;
            6) stop_cpu ;;
            7) stop_gpu ;;
            8) stop_all ;;
            9) stop_with_volumes ;;
            10) show_ps ;;
            11) show_ps_all ;;
            12) logs_cpu ;;
            13) logs_gpu ;;
            14) logs_all ;;
            15) health_cpu ;;
            16) health_gpu ;;
            17) health_both ;;
            18) restart_cpu ;;
            19) restart_gpu ;;
            20) restart_all ;;
            21) pull_images ;;
            22) build_images ;;
            23) enable_autostart ;;
            24) disable_autostart ;;
            25) shell_cpu ;;
            26) shell_gpu ;;
            27) show_config ;;
            28) validate_config ;;
            29) show_ports ;;
            30) remove_stopped ;;
            31) remove_all ;;
            32) prune_images ;;
            q|Q) echo "Goodbye!"; exit 0 ;;
            *) echo -e "${RED}Invalid option${NC}" ;;
        esac

        echo ""
        echo -n "Press Enter to continue..."
        read -r
    done
}

# Command line interface
print_cli_help() {
    echo "Docling Docker Compose Manager"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Start Commands:"
    echo "  up              Start CPU service (detached)"
    echo "  up-gpu          Start GPU service (detached)"
    echo "  up-all          Start both services"
    echo "  up-attached     Start CPU service (attached)"
    echo ""
    echo "Stop Commands:"
    echo "  down            Stop all services"
    echo "  down-v          Stop all and remove volumes"
    echo "  stop            Stop CPU service"
    echo "  stop-gpu        Stop GPU service"
    echo ""
    echo "Status Commands:"
    echo "  ps              Show running containers"
    echo "  logs            Show CPU logs (follow)"
    echo "  logs-gpu        Show GPU logs (follow)"
    echo "  logs-all        Show all logs (tail 50)"
    echo ""
    echo "Health Commands:"
    echo "  health          Health check CPU"
    echo "  health-gpu      Health check GPU"
    echo "  health-all      Health check both"
    echo ""
    echo "Management Commands:"
    echo "  restart         Restart CPU service"
    echo "  restart-gpu     Restart GPU service"
    echo "  restart-all     Restart all services"
    echo "  pull            Pull latest images"
    echo "  build           Build images locally"
    echo ""
    echo "Auto-Start Commands:"
    echo "  autostart-on    Enable auto-start on reboot"
    echo "  autostart-off   Disable auto-start on reboot"
    echo ""
    echo "Advanced Commands:"
    echo "  shell           Shell into CPU container"
    echo "  shell-gpu       Shell into GPU container"
    echo "  config          Show compose config"
    echo "  validate        Validate compose file"
    echo ""
    echo "Cleanup Commands:"
    echo "  rm              Remove stopped containers"
    echo "  clean           Remove all containers/networks"
    echo "  prune           Prune unused images"
    echo ""
    echo "Run without arguments for interactive menu."
}

# Handle CLI arguments
if [ $# -gt 0 ]; then
    case $1 in
        up) start_cpu ;;
        up-gpu) start_gpu ;;
        up-all) start_both ;;
        up-attached) start_cpu_attached ;;
        down) stop_all ;;
        down-v) stop_with_volumes ;;
        stop) stop_cpu ;;
        stop-gpu) stop_gpu ;;
        ps) show_ps ;;
        ps-a) show_ps_all ;;
        logs) logs_cpu ;;
        logs-gpu) logs_gpu ;;
        logs-all) logs_all ;;
        health) health_cpu ;;
        health-gpu) health_gpu ;;
        health-all) health_both ;;
        restart) restart_cpu ;;
        restart-gpu) restart_gpu ;;
        restart-all) restart_all ;;
        pull) pull_images ;;
        build) build_images ;;
        autostart-on) enable_autostart ;;
        autostart-off) disable_autostart ;;
        shell) shell_cpu ;;
        shell-gpu) shell_gpu ;;
        config) show_config ;;
        validate) validate_config ;;
        ports) show_ports ;;
        rm) remove_stopped ;;
        clean) remove_all ;;
        prune) prune_images ;;
        -h|--help|help) print_cli_help ;;
        *)
            echo -e "${RED}Unknown command: $1${NC}"
            echo ""
            print_cli_help
            exit 1
            ;;
    esac
else
    main
fi
