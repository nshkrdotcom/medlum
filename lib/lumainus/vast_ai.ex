defmodule Lumainus.VastAI do
  @moduledoc """
  High-level Vast.ai operations (search, provision, destroy, status).
  """

  require Logger

  alias Lumainus.VastAI.{Instances, Offers}
  alias Lumainus.Cloudflare

  # Custom GPU image with docling pre-installed
  # See docling_service/DEPLOYMENT.md for build instructions
  @default_image "ghcr.io/nshkrdotcom/lumainus-docling-gpu:latest"

  # External port for cloud backend (container will run on this port)
  @cloud_port 8044

  # Default domain for HTTPS
  @default_domain "lumainus.com"
  @default_subdomain "docling"

  def cloud_port, do: @cloud_port

  @doc """
  Get the HTTPS URL for the cloud backend.
  """
  def cloud_https_url(opts \\ []) do
    Cloudflare.cloud_url(opts)
  end

  @doc """
  Provision an instance with automatic HTTPS setup via Caddy + Let's Encrypt.

  This will:
  1. Provision the instance with Caddy onstart script
  2. Wait for the instance to be ready
  3. Update Cloudflare DNS to point to the instance IP
  4. Return the HTTPS endpoint

  ## Options
  Same as `provision/1` plus:
    - `:subdomain` - Subdomain for HTTPS (default: "docling")
    - `:setup_https` - Whether to set up HTTPS (default: true)
  """
  def provision_with_https(opts \\ []) do
    subdomain = Keyword.get(opts, :subdomain, @default_subdomain)
    domain = Keyword.get(opts, :domain, @default_domain)
    fqdn = "#{subdomain}.#{domain}"

    # Generate onstart script with Caddy configuration
    onstart = caddy_onstart_script(fqdn, @cloud_port)

    # Provision with the Caddy onstart script
    opts = Keyword.put(opts, :onstart, onstart)

    with {:ok, instance_id} <- provision(opts),
         {:ok, instance} <- wait_for_ready(instance_id, 300_000),
         {:ok, ip} <- extract_ip(instance),
         {:ok, _dns} <- update_dns(ip, subdomain: subdomain) do
      endpoint = "https://#{fqdn}"
      Logger.info("[VastAI] HTTPS instance ready at #{endpoint}")
      {:ok, instance_id, endpoint}
    end
  end

  defp extract_ip(%{"public_ipaddr" => ip}) when is_binary(ip) and ip != "", do: {:ok, ip}
  defp extract_ip(_), do: {:error, :no_public_ip}

  defp update_dns(ip, opts) do
    Logger.info("[VastAI] Updating DNS to point to #{ip}")
    Cloudflare.update_dns_record(ip, opts)
  end

  @doc """
  Generate Caddy onstart script for automatic HTTPS.
  """
  def caddy_onstart_script(domain, backend_port) do
    """
    #!/bin/bash
    # Auto-generated startup script for docling service with Caddy HTTPS
    set -e
    DOMAIN="#{domain}"
    BACKEND_PORT="#{backend_port}"
    LOG="/var/log/startup.log"

    log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

    log "=== Starting docling service setup ==="
    log "Domain: $DOMAIN, Backend port: $BACKEND_PORT"

    # ============================================
    # STEP 1: Start the docling uvicorn service
    # ============================================
    # With runtype=ssh, Docker CMD doesn't run, so we must start it manually
    log "Starting uvicorn service..."

    cd /app/service
    export PORT=$BACKEND_PORT
    export HOST=0.0.0.0
    export CUDA_VISIBLE_DEVICES=0
    export OMP_NUM_THREADS=4

    # Start uvicorn in background, logging to file
    # Use conda python path (the Docker image uses miniconda)
    nohup /opt/conda/bin/python -m uvicorn app.main:app --host $HOST --port $PORT --no-access-log > /var/log/uvicorn.log 2>&1 &
    UVICORN_PID=$!
    log "Uvicorn started with PID $UVICORN_PID"

    # ============================================
    # STEP 2: Wait for backend to be ready
    # ============================================
    log "Waiting for backend to be ready..."
    for i in {1..60}; do
      if curl -s "http://localhost:$BACKEND_PORT/health" > /dev/null 2>&1; then
        log "Backend is ready!"
        break
      fi
      log "Waiting for backend... ($i/60)"
      sleep 5
    done

    # ============================================
    # STEP 3: Install and configure Caddy
    # ============================================
    log "Installing Caddy..."
    apt-get update -y
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -y
    apt-get install -y caddy

    # Create Caddyfile (no quotes on CADDYEOF to allow variable expansion)
    mkdir -p /var/log/caddy
    cat > /etc/caddy/Caddyfile <<-CADDYEOF
    $DOMAIN {
        reverse_proxy localhost:$BACKEND_PORT
        log {
            output file /var/log/caddy/access.log
            format json
        }
    }
    CADDYEOF

    # Start Caddy
    systemctl enable caddy
    systemctl restart caddy
    log "=== Setup complete ==="
    log "Docling service: http://localhost:$BACKEND_PORT"
    log "HTTPS endpoint: https://$DOMAIN"
    """
  end

  def provision(opts \\ []) do
    max_price = Keyword.get(opts, :max_price, 0.18)
    disk_gb = Keyword.get(opts, :disk_gb, 16)
    label = Keyword.get(opts, :label, "docling-dev")
    onstart = Keyword.get(opts, :onstart)
    image = Keyword.get(opts, :image, @default_image)

    # For private registries (ghcr.io private packages)
    # Set GHCR_TOKEN env var or config :lumainus, :ghcr_token
    docker_login = Keyword.get(opts, :docker_login) || fetch_docker_login(image)

    filters =
      Offers.build_filters(
        gpu_name: "RTX 3090",
        num_gpus: 1,
        verified: true,
        rentable: true,
        geolocation: Keyword.get(opts, :geolocation, ["US", "CA"]),
        dph_total: {:lte, max_price}
      )

    # Configure container to run on cloud port (8044)
    # The PORT env var overrides the Dockerfile's default of 8042
    create_params =
      %{
        image: image,
        disk: disk_gb,
        label: label,
        onstart: onstart,
        runtype: "ssh",
        env: %{PORT: "#{@cloud_port}"}
      }
      |> maybe_add_docker_login(docker_login)

    with {:ok, offer} <- Offers.cheapest(filters: filters),
         true <- offer["dph_total"] <= max_price || {:error, :price_too_high},
         {:ok, resp} <- Instances.create(offer["id"], create_params),
         %{"new_contract" => instance_id} <- resp do
      {:ok, instance_id}
    end
  end

  defp maybe_add_docker_login(params, nil), do: params

  defp maybe_add_docker_login(params, docker_login),
    do: Map.put(params, :docker_login, docker_login)

  defp fetch_docker_login(image) do
    # Only add docker_login for ghcr.io images
    if String.starts_with?(image, "ghcr.io/") do
      ghcr_user = Application.get_env(:lumainus, :ghcr_user) || "nshkrdotcom"

      ghcr_token =
        Application.get_env(:lumainus, :ghcr_token) ||
          System.get_env("GHCR_TOKEN")

      if ghcr_token do
        "#{ghcr_user}:#{ghcr_token}"
      else
        nil
      end
    else
      nil
    end
  end

  def wait_for_ready(instance_id, timeout_ms \\ 300_000),
    do: Instances.wait_for_ready(instance_id, timeout_ms)

  def destroy(instance_id), do: Instances.destroy(instance_id)

  def start(instance_id), do: Instances.start(instance_id)

  def stop(instance_id), do: Instances.stop(instance_id)

  def status(instance_id), do: Instances.get(instance_id)
end
