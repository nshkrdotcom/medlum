#!/usr/bin/env bash
# Docling Vast.ai GPU Management
# ===============================
# Interactive menu for provisioning, managing, and deploying to Vast.ai GPU instances.
#
# Requires:
#   - VAST_API_KEY environment variable
#   - vast CLI (optional, for some operations)
#   - Elixir/Mix (for Medlum.VastAI module)
#
# Port: 8044 (cloud/vast_ai backend)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# Default configuration
DEFAULT_MAX_PRICE="0.25"
DEFAULT_DISK_GB="16"
DEFAULT_GEOLOCATION="US,CA"
DEFAULT_GPU_TYPE="RTX_3090"
DEFAULT_LABEL="docling-medlum"

print_header() {
    echo -e "\n${CYAN}============================================${NC}"
    echo -e "${CYAN}  Docling Vast.ai GPU Manager${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo ""
    echo -e "Cloud port: ${GREEN}${DOCLING_PORT_VAST_AI}${NC}"
    echo ""
    if [ -n "${VAST_API_KEY:-}" ]; then
        echo -e "API Key: ${GREEN}Set${NC} (${#VAST_API_KEY} chars)"
    else
        echo -e "API Key: ${RED}NOT SET${NC} - export VAST_API_KEY first!"
    fi
    echo ""
}

print_menu() {
    echo -e "${BLUE}INSTANCE MANAGEMENT${NC}"
    echo "  1) List all instances"
    echo "  2) List running instances"
    echo "  3) Provision new instance (interactive)"
    echo "  4) Provision with defaults (quick)"
    echo "  5) Destroy instance (by ID)"
    echo "  6) Destroy ALL instances"
    echo ""
    echo -e "${BLUE}DEPLOYMENT${NC}"
    echo "  7) Deploy Docling to instance (SSH)"
    echo "  8) Check instance health"
    echo "  9) View instance logs (SSH)"
    echo " 10) Restart Docling on instance (SSH)"
    echo ""
    echo -e "${BLUE}SEARCH & OFFERS${NC}"
    echo " 11) Search available GPUs"
    echo " 12) Search cheap RTX 3090s"
    echo " 13) Search cheap RTX 4090s"
    echo " 14) Show current offers"
    echo ""
    echo -e "${BLUE}CONFIGURATION${NC}"
    echo " 15) Set/show API key"
    echo " 16) Show current defaults"
    echo " 17) Test API connection"
    echo ""
    echo -e "${BLUE}PHOENIX INTEGRATION${NC}"
    echo " 18) Update cloud_url in Phoenix config"
    echo " 19) Check Phoenix Vast.ai health"
    echo ""
    echo "  q) Quit"
    echo ""
}

check_api_key() {
    if [ -z "${VAST_API_KEY:-}" ]; then
        echo -e "${RED}Error: VAST_API_KEY not set${NC}"
        echo "Export it first: export VAST_API_KEY=your_key_here"
        return 1
    fi
    return 0
}

run_mix() {
    cd "$REPO_ROOT"
    MIX_ENV=dev VAST_API_KEY="$VAST_API_KEY" mix run -e "$1"
}

# Safety check: returns 0 if NO active instances, 1 if instances exist
check_no_active_instances() {
    echo -e "${YELLOW}Checking for existing instances...${NC}"
    local count
    count=$(cd "$REPO_ROOT" && MIX_ENV=dev VAST_API_KEY="$VAST_API_KEY" mix run -e "
      case Medlum.VastAI.Instances.list() do
        {:ok, %{\"instances\" => instances}} ->
          active = Enum.count(instances, & &1[\"actual_status\"] in [\"running\", \"loading\"])
          IO.puts(active)
        {:ok, instances} when is_list(instances) ->
          active = Enum.count(instances, & &1[\"actual_status\"] in [\"running\", \"loading\"])
          IO.puts(active)
        _ -> IO.puts(\"0\")
      end
    " 2>/dev/null | tail -1)

    if [ "$count" != "0" ] && [ -n "$count" ]; then
        echo -e "${RED}ERROR: $count active instance(s) already exist!${NC}"
        echo -e "${YELLOW}Destroy existing instances before provisioning a new one.${NC}"
        echo ""
        echo "Options:"
        echo "  - Use option 5 to destroy a specific instance"
        echo "  - Use option 6 to destroy ALL instances"
        return 1
    fi
    echo -e "${GREEN}No active instances found. Safe to provision.${NC}"
    return 0
}

# Instance Management
list_all_instances() {
    echo -e "\n${YELLOW}Listing all Vast.ai instances...${NC}"
    check_api_key || return
    run_mix "IO.inspect(Medlum.VastAI.Instances.list(), pretty: true)"
}

list_running_instances() {
    echo -e "\n${YELLOW}Listing running instances...${NC}"
    check_api_key || return
    run_mix "
      case Medlum.VastAI.Instances.list() do
        {:ok, instances} ->
          running = Enum.filter(instances, & &1[\"actual_status\"] == \"running\")
          IO.puts(\"Running instances: #{length(running)}\")
          Enum.each(running, fn i ->
            IO.puts(\"  ID: #{i[\"id\"]} | GPU: #{i[\"gpu_name\"]} | \$#{i[\"dph_total\"]}/hr | #{i[\"ssh_host\"]}:#{i[\"ssh_port\"]}\")
          end)
        {:error, e} -> IO.puts(\"Error: #{inspect(e)}\")
      end
    "
}

provision_interactive() {
    echo -e "\n${YELLOW}Provision new Vast.ai instance${NC}"
    check_api_key || return
    check_no_active_instances || return

    echo -n "Max price per hour [$DEFAULT_MAX_PRICE]: "
    read -r max_price
    max_price="${max_price:-$DEFAULT_MAX_PRICE}"

    echo -n "Disk GB [$DEFAULT_DISK_GB]: "
    read -r disk_gb
    disk_gb="${disk_gb:-$DEFAULT_DISK_GB}"

    echo -n "Geolocation (comma-separated) [$DEFAULT_GEOLOCATION]: "
    read -r geo
    geo="${geo:-$DEFAULT_GEOLOCATION}"

    echo -n "Label [$DEFAULT_LABEL]: "
    read -r label
    label="${label:-$DEFAULT_LABEL}"

    echo ""
    echo -e "${CYAN}Provisioning with:${NC}"
    echo "  Max price: \$$max_price/hr"
    echo "  Disk: ${disk_gb}GB"
    echo "  Geolocation: $geo"
    echo "  Label: $label"
    echo ""
    echo -n "Proceed? [y/N] "
    read -r confirm

    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        geo_list=$(echo "$geo" | sed 's/,/","/g')
        run_mix "IO.inspect(Medlum.VastAI.provision(max_price: $max_price, disk_gb: $disk_gb, geolocation: [\"$geo_list\"], label: \"$label\"), pretty: true)"
    else
        echo "Cancelled"
    fi
}

provision_quick() {
    echo -e "\n${YELLOW}Quick provision with defaults...${NC}"
    check_api_key || return
    check_no_active_instances || return

    echo "Using: \$$DEFAULT_MAX_PRICE/hr, ${DEFAULT_DISK_GB}GB disk, $DEFAULT_GEOLOCATION"
    geo_list=$(echo "$DEFAULT_GEOLOCATION" | sed 's/,/","/g')
    run_mix "IO.inspect(Medlum.VastAI.provision(max_price: $DEFAULT_MAX_PRICE, disk_gb: $DEFAULT_DISK_GB, geolocation: [\"$geo_list\"], label: \"$DEFAULT_LABEL\"), pretty: true)"
}

destroy_instance() {
    echo -e "\n${YELLOW}Destroy instance${NC}"
    check_api_key || return

    echo -n "Instance ID to destroy: "
    read -r instance_id

    if [ -z "$instance_id" ]; then
        echo -e "${RED}No instance ID provided${NC}"
        return
    fi

    echo -n "Are you sure you want to destroy instance $instance_id? [y/N] "
    read -r confirm

    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        run_mix "IO.inspect(Medlum.VastAI.destroy(\"$instance_id\"), pretty: true)"
    else
        echo "Cancelled"
    fi
}

destroy_all_instances() {
    echo -e "\n${RED}WARNING: This will destroy ALL Vast.ai instances!${NC}"
    check_api_key || return

    echo -n "Type 'DESTROY ALL' to confirm: "
    read -r confirm

    if [ "$confirm" = "DESTROY ALL" ]; then
        run_mix "
          case Medlum.VastAI.Instances.list() do
            {:ok, %{\"instances\" => instances}} ->
              instances
              |> List.wrap()
              |> Enum.each(fn i ->
                IO.puts(\"Destroying #{i[\"id\"]}...\")
                Medlum.VastAI.destroy(i[\"id\"])
              end)
              IO.puts(\"Done.\")

            {:ok, instances} when is_list(instances) ->
              Enum.each(instances, fn i ->
                IO.puts(\"Destroying #{i[\"id\"]}...\")
                Medlum.VastAI.destroy(i[\"id\"])
              end)
              IO.puts(\"Done.\")

            {:ok, %{} = other} ->
              case Map.get(other, \"instances\") do
                nil ->
                  IO.puts(\"Error: unexpected response shape #{inspect(other)}\")

                instances ->
                  instances
                  |> List.wrap()
                  |> Enum.each(fn i ->
                    IO.puts(\"Destroying #{i[\"id\"]}...\")
                    Medlum.VastAI.destroy(i[\"id\"])
                  end)

                  IO.puts(\"Done.\")
              end

            {:error, e} ->
              IO.puts(\"Error: #{inspect(e)}\")
          end
        "
    else
        echo "Cancelled"
    fi
}

# Deployment
deploy_to_instance() {
    echo -e "\n${YELLOW}Deploy Docling to instance${NC}"

    echo -n "SSH target (user@host or user@host:port): "
    read -r ssh_target

    if [ -z "$ssh_target" ]; then
        echo -e "${RED}No SSH target provided${NC}"
        return
    fi

    echo -n "Git branch [main]: "
    read -r branch
    branch="${branch:-main}"

    echo -e "\n${CYAN}Deploying to $ssh_target (branch: $branch)...${NC}"

    if [ -f "$REPO_ROOT/docling/scripts/bootstrap_vast_gpu.sh" ]; then
        PORT="$DOCLING_PORT_VAST_AI" "$REPO_ROOT/docling/scripts/bootstrap_vast_gpu.sh" "$ssh_target" "$branch"
    else
        echo -e "${RED}Bootstrap script not found at docling/scripts/bootstrap_vast_gpu.sh${NC}"
    fi
}

check_instance_health() {
    echo -e "\n${YELLOW}Check instance health${NC}"

    echo -n "Instance URL (or IP:port): "
    read -r instance_url

    if [ -z "$instance_url" ]; then
        echo -e "${RED}No URL provided${NC}"
        return
    fi

    # Add http:// if not present
    if [[ ! "$instance_url" =~ ^https?:// ]]; then
        instance_url="http://$instance_url"
    fi

    # Add port if not present
    if [[ ! "$instance_url" =~ :[0-9]+$ ]]; then
        instance_url="$instance_url:$DOCLING_PORT_VAST_AI"
    fi

    echo -e "Checking ${CYAN}$instance_url/health${NC}..."

    if response=$(curl -s -w "\n%{http_code}" "$instance_url/health" 2>&1); then
        http_code=$(echo "$response" | tail -1)
        body=$(echo "$response" | head -n -1)
        if [ "$http_code" = "200" ]; then
            echo -e "${GREEN}Healthy${NC}"
            echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"
        else
            echo -e "${RED}HTTP $http_code${NC}"
            echo "$body"
        fi
    else
        echo -e "${RED}Unreachable${NC}"
    fi
}

view_instance_logs() {
    echo -e "\n${YELLOW}View instance logs${NC}"

    echo -n "SSH target (user@host or user@host:port): "
    read -r ssh_target

    if [ -z "$ssh_target" ]; then
        echo -e "${RED}No SSH target provided${NC}"
        return
    fi

    echo -e "${CYAN}Fetching logs from $ssh_target...${NC}"
    ssh "$ssh_target" "tail -100 /opt/medlum/docling_service.log 2>/dev/null || echo 'Log file not found'"
}

restart_instance_docling() {
    echo -e "\n${YELLOW}Restart Docling on instance${NC}"

    echo -n "SSH target (user@host or user@host:port): "
    read -r ssh_target

    if [ -z "$ssh_target" ]; then
        echo -e "${RED}No SSH target provided${NC}"
        return
    fi

    echo -e "${CYAN}Restarting Docling on $ssh_target...${NC}"
    ssh "$ssh_target" bash <<EOF
pkill -f "uvicorn.*docling" || true
cd /opt/medlum/medlum/docling_service
export PORT=$DOCLING_PORT_VAST_AI
export HOST=0.0.0.0
nohup ./run.sh > /opt/medlum/docling_service.log 2>&1 </dev/null &
echo "Restarted. Check logs with: tail -f /opt/medlum/docling_service.log"
EOF
}

# Search & Offers
search_gpus() {
    echo -e "\n${YELLOW}Search available GPUs${NC}"
    check_api_key || return

    echo -n "Max price per hour [$DEFAULT_MAX_PRICE]: "
    read -r max_price
    max_price="${max_price:-$DEFAULT_MAX_PRICE}"

    echo -n "GPU type (e.g., RTX_3090, RTX_4090, A100) [any]: "
    read -r gpu_type

    run_mix "
      opts = [max_price: $max_price]
      opts = if \"$gpu_type\" != \"\", do: Keyword.put(opts, :gpu_name, \"$gpu_type\"), else: opts
      case Medlum.VastAI.Offers.search(opts) do
        {:ok, offers} ->
          IO.puts(\"Found #{length(offers)} offers:\")
          offers |> Enum.take(10) |> Enum.each(fn o ->
            IO.puts(\"  \$#{o[\"dph_total\"]}/hr | #{o[\"gpu_name\"]} | #{o[\"num_gpus\"]}x GPU | #{o[\"geolocation\"]}\")
          end)
        {:error, e} -> IO.puts(\"Error: #{inspect(e)}\")
      end
    "
}

search_cheap_3090() {
    echo -e "\n${YELLOW}Searching for cheap RTX 3090s...${NC}"
    check_api_key || return
    run_mix "
      case Medlum.VastAI.Offers.search(max_price: 0.20, gpu_name: \"RTX_3090\") do
        {:ok, offers} ->
          IO.puts(\"Found #{length(offers)} RTX 3090 offers under \$0.20/hr:\")
          offers |> Enum.take(10) |> Enum.each(fn o ->
            IO.puts(\"  \$#{o[\"dph_total\"]}/hr | #{o[\"num_gpus\"]}x GPU | #{o[\"geolocation\"]} | ID: #{o[\"id\"]}\")
          end)
        {:error, e} -> IO.puts(\"Error: #{inspect(e)}\")
      end
    "
}

search_cheap_4090() {
    echo -e "\n${YELLOW}Searching for cheap RTX 4090s...${NC}"
    check_api_key || return
    run_mix "
      case Medlum.VastAI.Offers.search(max_price: 0.40, gpu_name: \"RTX_4090\") do
        {:ok, offers} ->
          IO.puts(\"Found #{length(offers)} RTX 4090 offers under \$0.40/hr:\")
          offers |> Enum.take(10) |> Enum.each(fn o ->
            IO.puts(\"  \$#{o[\"dph_total\"]}/hr | #{o[\"num_gpus\"]}x GPU | #{o[\"geolocation\"]} | ID: #{o[\"id\"]}\")
          end)
        {:error, e} -> IO.puts(\"Error: #{inspect(e)}\")
      end
    "
}

show_offers() {
    echo -e "\n${YELLOW}Current offers (top 15 cheapest)...${NC}"
    check_api_key || return
    run_mix "
      case Medlum.VastAI.Offers.search(max_price: 1.0) do
        {:ok, offers} ->
          offers
          |> Enum.sort_by(& &1[\"dph_total\"])
          |> Enum.take(15)
          |> Enum.each(fn o ->
            IO.puts(\"\$#{Float.round(o[\"dph_total\"], 3)}/hr | #{o[\"gpu_name\"]} | #{o[\"num_gpus\"]}x | #{o[\"cuda_max_good\"]} CUDA | #{o[\"geolocation\"]}\")
          end)
        {:error, e} -> IO.puts(\"Error: #{inspect(e)}\")
      end
    "
}

# Configuration
set_api_key() {
    echo -e "\n${YELLOW}API Key Configuration${NC}"
    if [ -n "${VAST_API_KEY:-}" ]; then
        echo -e "Current: ${GREEN}Set${NC} (${#VAST_API_KEY} chars)"
    else
        echo -e "Current: ${RED}Not set${NC}"
    fi
    echo ""
    echo "To set, run in your shell:"
    echo -e "  ${CYAN}export VAST_API_KEY=your_api_key_here${NC}"
    echo ""
    echo "To persist, add to ~/.bashrc or ~/.zshrc"
}

show_defaults() {
    echo -e "\n${CYAN}Current Defaults:${NC}"
    echo "  Max price:    \$$DEFAULT_MAX_PRICE/hr"
    echo "  Disk:         ${DEFAULT_DISK_GB}GB"
    echo "  Geolocation:  $DEFAULT_GEOLOCATION"
    echo "  GPU type:     $DEFAULT_GPU_TYPE"
    echo "  Label:        $DEFAULT_LABEL"
    echo "  Port:         $DOCLING_PORT_VAST_AI"
}

test_api() {
    echo -e "\n${YELLOW}Testing API connection...${NC}"
    check_api_key || return
    run_mix "
      case Medlum.VastAI.Instances.list() do
        {:ok, instances} -> IO.puts(\"#{IO.ANSI.green()}API OK#{IO.ANSI.reset()} - #{length(instances)} instances found\")
        {:error, e} -> IO.puts(\"#{IO.ANSI.red()}API Error#{IO.ANSI.reset()}: #{inspect(e)}\")
      end
    "
}

# Phoenix Integration
update_phoenix_cloud_url() {
    echo -e "\n${YELLOW}Update Phoenix cloud_url${NC}"

    echo -n "Instance URL (e.g., http://1.2.3.4:8044): "
    read -r cloud_url

    if [ -z "$cloud_url" ]; then
        echo -e "${RED}No URL provided${NC}"
        return
    fi

    echo -e "${CYAN}To update Phoenix, run in iex:${NC}"
    echo ""
    echo "  Medlum.Docling.Settings.update_settings(%{cloud_url: \"$cloud_url\"})"
    echo ""
    echo "Or set environment variable:"
    echo "  export DOCLING_CLOUD_URL=$cloud_url"
}

check_phoenix_vast_health() {
    echo -e "\n${YELLOW}Check Phoenix Vast.ai health...${NC}"
    run_mix "IO.inspect(Medlum.Docling.health(backend: :vast_ai), pretty: true)"
}

# Main loop
main() {
    while true; do
        print_header
        print_menu

        echo -n "Select option: "
        read -r choice

        case $choice in
            1) list_all_instances ;;
            2) list_running_instances ;;
            3) provision_interactive ;;
            4) provision_quick ;;
            5) destroy_instance ;;
            6) destroy_all_instances ;;
            7) deploy_to_instance ;;
            8) check_instance_health ;;
            9) view_instance_logs ;;
            10) restart_instance_docling ;;
            11) search_gpus ;;
            12) search_cheap_3090 ;;
            13) search_cheap_4090 ;;
            14) show_offers ;;
            15) set_api_key ;;
            16) show_defaults ;;
            17) test_api ;;
            18) update_phoenix_cloud_url ;;
            19) check_phoenix_vast_health ;;
            q|Q) echo "Goodbye!"; exit 0 ;;
            *) echo -e "${RED}Invalid option${NC}" ;;
        esac

        echo ""
        echo -n "Press Enter to continue..."
        read -r
    done
}

# Run
main
