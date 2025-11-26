defmodule Lumainus.VastAI do
  @moduledoc """
  High-level Vast.ai operations (search, provision, destroy, status).

  ## Cloudflare Tunnel Integration

  Instead of exposing ports and using Let's Encrypt, we now use Cloudflare Tunnels:

  1. `provision_with_tunnel/1` creates a Cloudflare Tunnel via API
  2. The tunnel token is passed to the Vast.ai onstart script
  3. `cloudflared` runs inside the container, creating an outbound connection
  4. Traffic flows: Internet → Cloudflare → Tunnel → uvicorn:8044

  This works with Vast.ai's SSH-mode containers which don't expose HTTP ports.
  """

  require Logger

  alias Lumainus.VastAI.{Instances, Offers}
  alias Lumainus.Cloudflare
  alias Lumainus.Cloudflare.Tunnel

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
  Provision an instance with automatic HTTPS setup via Cloudflare Tunnel.

  This will:
  1. Create a Cloudflare Tunnel via API
  2. Configure tunnel ingress and DNS CNAME
  3. Provision the Vast.ai instance with cloudflared onstart script
  4. Wait for the instance to be ready
  5. Return the HTTPS endpoint

  ## Why Cloudflare Tunnel?

  Vast.ai SSH-mode containers don't expose HTTP ports (80, 443, 8044).
  Cloudflare Tunnel creates an *outbound* connection from the container,
  so no port exposure is needed. Cloudflare handles HTTPS termination.

  ## Options
  Same as `provision/1` plus:
    - `:subdomain` - Subdomain for HTTPS (default: "docling")
  """
  def provision_with_https(opts \\ []) do
    # Delegate to the new tunnel-based provisioning
    provision_with_tunnel(opts)
  end

  @doc """
  Provision an instance with Cloudflare Tunnel for secure connectivity.

  ## Options
    - `:subdomain` - Subdomain for HTTPS (default: "docling")
    - `:max_price` - Maximum hourly price (default: 0.18)
    - `:disk_gb` - Disk size in GB (default: 16)
    - `:label` - Instance label (default: "docling-dev")
  """
  def provision_with_tunnel(opts \\ []) do
    subdomain = Keyword.get(opts, :subdomain, @default_subdomain)
    domain = Keyword.get(opts, :domain, @default_domain)
    fqdn = "#{subdomain}.#{domain}"

    Logger.info("[VastAI] Starting tunnel-based provisioning for #{fqdn}")

    # Step 1: Create Cloudflare Tunnel and configure routing
    # We create the tunnel BEFORE the instance so we have the token
    with {:ok, tunnel} <- create_tunnel_for_instance(opts),
         # Step 2: Generate onstart script with tunnel token
         onstart = cloudflared_onstart_script(tunnel.tunnel_token, @cloud_port),
         # Step 3: Provision the Vast.ai instance
         opts = Keyword.put(opts, :onstart, onstart),
         {:ok, instance_id} <- provision(opts),
         # Step 4: Wait for instance to be ready
         {:ok, _instance} <- wait_for_ready(instance_id, 300_000) do
      endpoint = "https://#{fqdn}"
      Logger.info("[VastAI] Tunnel-based instance ready at #{endpoint}")
      Logger.info("[VastAI] Tunnel ID: #{tunnel.tunnel_id}")

      {:ok, instance_id, endpoint, tunnel.tunnel_id}
    else
      {:error, reason} = error ->
        Logger.error("[VastAI] Tunnel provisioning failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Destroy an instance and clean up its Cloudflare Tunnel.

  ## Options
    - `:tunnel_id` - The Cloudflare Tunnel ID to delete (optional)
  """
  def destroy_with_tunnel(instance_id, opts \\ []) do
    tunnel_id = Keyword.get(opts, :tunnel_id)

    # Destroy the Vast.ai instance first
    result = destroy(instance_id)

    # Clean up the tunnel if provided
    if tunnel_id do
      Logger.info("[VastAI] Cleaning up tunnel #{tunnel_id}")

      case Tunnel.cleanup_for_vast_ai(tunnel_id, opts) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[VastAI] Failed to cleanup tunnel: #{inspect(reason)}")
      end
    end

    result
  end

  # Create Cloudflare Tunnel for a new instance
  defp create_tunnel_for_instance(opts) do
    # Use a timestamp-based name since we don't have instance ID yet
    timestamp = System.system_time(:second)
    label = Keyword.get(opts, :label, "docling-dev")

    Tunnel.provision_for_vast_ai("#{label}-#{timestamp}", opts)
  end

  @doc """
  Generate cloudflared onstart script for Cloudflare Tunnel connectivity.

  Unlike Caddy (which needs ports 80/443 exposed for Let's Encrypt),
  cloudflared creates an OUTBOUND connection to Cloudflare, so no
  port exposure is needed on the Vast.ai container.

  ## Parameters
    - `tunnel_token` - The Cloudflare Tunnel connector token
    - `backend_port` - The port uvicorn listens on (default: 8044)
  """
  def cloudflared_onstart_script(tunnel_token, backend_port) do
    """
    #!/bin/bash
    # Auto-generated startup script for docling service with Cloudflare Tunnel
    set -e
    TUNNEL_TOKEN="#{tunnel_token}"
    BACKEND_PORT="#{backend_port}"
    LOG="/var/log/startup.log"

    log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

    log "=== Starting docling service setup (Cloudflare Tunnel mode) ==="
    log "Backend port: $BACKEND_PORT"

    # ============================================
    # STEP 0: Save config for restart scenarios
    # ============================================
    # The onstart script only runs on first provision, not on stop/start.
    # Save the token and port so ensure_services_running can restart services.
    mkdir -p /etc/cloudflared
    echo "$TUNNEL_TOKEN" > /etc/cloudflared/tunnel_token
    echo "$BACKEND_PORT" > /etc/cloudflared/backend_port
    chmod 600 /etc/cloudflared/tunnel_token
    log "Saved tunnel config to /etc/cloudflared/"

    # ============================================
    # STEP 1: Start the docling uvicorn service
    # ============================================
    log "Starting uvicorn service..."

    cd /app/service
    export PORT=$BACKEND_PORT
    export HOST=0.0.0.0
    export CUDA_VISIBLE_DEVICES=0
    export OMP_NUM_THREADS=4

    # Start uvicorn in background, logging to file
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
    # STEP 3: Install cloudflared
    # ============================================
    log "Installing cloudflared..."

    # Download and install cloudflared
    if ! command -v cloudflared &> /dev/null; then
      curl -L --output /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
      dpkg -i /tmp/cloudflared.deb || apt-get install -f -y
      rm /tmp/cloudflared.deb
    fi

    log "cloudflared version: $(cloudflared --version)"

    # ============================================
    # STEP 4: Start cloudflared tunnel
    # ============================================
    log "Starting Cloudflare Tunnel..."
    mkdir -p /var/log/cloudflared

    # Run cloudflared with the tunnel token
    # The token contains all config (tunnel ID, account, ingress rules)
    nohup cloudflared tunnel --no-autoupdate run --token "$TUNNEL_TOKEN" > /var/log/cloudflared/cloudflared.log 2>&1 &
    CLOUDFLARED_PID=$!
    log "cloudflared started with PID $CLOUDFLARED_PID"

    # Wait for tunnel to establish connection
    log "Waiting for tunnel connection..."
    for i in {1..30}; do
      if grep -q "Connection.*registered" /var/log/cloudflared/cloudflared.log 2>/dev/null; then
        log "Tunnel connected!"
        break
      fi
      if grep -q "error" /var/log/cloudflared/cloudflared.log 2>/dev/null; then
        log "WARNING: Tunnel may have errors, check /var/log/cloudflared/cloudflared.log"
      fi
      log "Waiting for tunnel... ($i/30)"
      sleep 2
    done

    # Save PIDs for service management
    echo "$UVICORN_PID" > /var/run/uvicorn.pid
    echo "$CLOUDFLARED_PID" > /var/run/cloudflared.pid

    log "=== Setup complete ==="
    log "Docling service: http://localhost:$BACKEND_PORT"
    log "Cloudflare Tunnel: Active (traffic routed via Cloudflare)"
    log "Check tunnel status: cat /var/log/cloudflared/cloudflared.log"
    """
  end

  @doc """
  Generate Caddy onstart script for automatic HTTPS.

  DEPRECATED: Use cloudflared_onstart_script/2 instead.
  Caddy requires ports 80/443 to be exposed for Let's Encrypt ACME challenges,
  which doesn't work with Vast.ai SSH-mode containers.
  """
  def caddy_onstart_script(_domain, _backend_port) do
    Logger.warning(
      "[VastAI] caddy_onstart_script is deprecated - use cloudflared_onstart_script instead"
    )

    """
    #!/bin/bash
    # DEPRECATED: This script requires ports 80/443 which aren't exposed in Vast.ai SSH mode
    # Use cloudflared_onstart_script instead
    echo "ERROR: Caddy mode is deprecated. Vast.ai SSH containers don't expose ports 80/443."
    echo "Please use Cloudflare Tunnel mode instead."
    exit 1
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
