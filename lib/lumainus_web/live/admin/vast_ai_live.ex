defmodule LumainusWeb.Admin.VastAILive do
  use LumainusWeb, :live_view
  require Logger

  alias Lumainus.VastAI
  alias Lumainus.VastAI.{Instances, Offers}
  alias Lumainus.Docling.Settings, as: DoclingSettings
  alias Lumainus.Docling.VastAI.ActivityTracker
  alias Lumainus.Docling.VastAI.ProvisioningState
  alias Lumainus.Cloudflare

  # Port used by cloud instances (from VastAI module)
  defp cloud_port, do: VastAI.cloud_port()

  @docling_image "ghcr.io/nshkrdotcom/lumainus-docling-gpu:latest"
  @pytorch_image "pytorch/pytorch:2.2.2-cuda12.1-cudnn8-runtime"

  # =============================================================================
  # Mount
  # =============================================================================

  @impl true
  def mount(_params, _session, socket) do
    # Load existing provisioning state (survives page navigation)
    prov_state = ProvisioningState.get_state()

    if connected?(socket) do
      # Subscribe to provisioning events for real-time updates
      ProvisioningState.subscribe()
      send(self(), :load_data)

      # If provisioning is already in progress, start refresh loop
      if prov_state.provisioning do
        Process.send_after(self(), :refresh_while_provisioning, 2_000)
      end
    end

    {:ok,
     socket
     |> assign(
       instances: [],
       offers: [],
       loading: true,
       provisioning: prov_state.provisioning,
       provision_status: prov_state.status,
       provision_logs: prov_state.logs,
       selected_offer: nil,
       error: nil,
       filters: default_filters(),
       selected_image: @docling_image,
       health_results: %{},
       use_https: prov_state.use_https,
       auto_shutdown_status: get_auto_shutdown_status(),
       dns_status: compute_dns_status(),
       starting_instance_id: nil
     )}
  end

  # =============================================================================
  # Handle Info (grouped together)
  # =============================================================================

  @impl true
  def handle_info(:load_data, socket) do
    socket =
      socket
      |> assign(loading: true)
      |> load_instances()
      |> assign(loading: false)
      |> assign(auto_shutdown_status: get_auto_shutdown_status())

    {:noreply, socket}
  end

  # Handle real-time provisioning events from PubSub
  def handle_info({:provisioning_event, :provisioning_started, state}, socket) do
    Process.send_after(self(), :refresh_while_provisioning, 5_000)

    {:noreply,
     socket
     |> assign(
       provisioning: true,
       provision_status: state.status,
       provision_logs: state.logs,
       use_https: state.use_https
     )
     |> put_flash(:info, "Provisioning started!")}
  end

  def handle_info({:provisioning_event, :log_added, log_entry}, socket) do
    logs = [log_entry | socket.assigns.provision_logs] |> Enum.take(100)
    {:noreply, assign(socket, provision_logs: logs)}
  end

  def handle_info({:provisioning_event, :status_updated, status}, socket) do
    {:noreply, assign(socket, provision_status: status)}
  end

  def handle_info(
        {:provisioning_event, :provisioning_complete,
         %{instance_id: instance_id, endpoint: endpoint}},
        socket
      ) do
    {:noreply,
     socket
     |> put_flash(:info, "Instance #{instance_id} ready at #{endpoint}")
     |> assign(provisioning: false, provision_status: nil, offers: [])
     |> load_instances()}
  end

  def handle_info({:provisioning_event, :provisioning_failed, reason}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Provisioning failed: #{inspect(reason)}")
     |> assign(provisioning: false, provision_status: nil)}
  end

  def handle_info({:provisioning_event, :provisioning_cancelled, _}, socket) do
    {:noreply,
     socket
     |> assign(provisioning: false, provision_status: nil)
     |> put_flash(:warning, "Provisioning cancelled.")}
  end

  def handle_info({:provisioning_event, :logs_cleared, _}, socket) do
    {:noreply, assign(socket, provision_logs: [])}
  end

  def handle_info({:provision_complete, instance_id, endpoint}, socket) do
    socket =
      add_log(
        socket,
        :success,
        "Provisioning complete! Instance #{instance_id} ready at #{endpoint}"
      )

    {:noreply,
     socket
     |> put_flash(:info, "Instance #{instance_id} ready at #{endpoint}")
     |> assign(provisioning: false, provision_status: nil, offers: [])
     |> load_instances()}
  end

  def handle_info({:provision_failed, reason}, socket) do
    socket = add_log(socket, :error, "Provisioning failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> put_flash(:error, "HTTPS provisioning failed: #{inspect(reason)}")
     |> assign(provisioning: false, provision_status: nil)}
  end

  def handle_info({:provision_log, level, message}, socket) do
    {:noreply, add_log(socket, level, message)}
  end

  def handle_info(:refresh_while_provisioning, socket) do
    if socket.assigns.provisioning do
      # Update status based on instances
      socket = load_instances(socket)
      instances = socket.assigns.instances

      {status, done?} =
        case instances do
          [] ->
            {"Waiting for instance to appear...", false}

          [inst | _] ->
            case inst["actual_status"] do
              "loading" ->
                {"Instance #{inst["id"]} loading...", false}

              "running" ->
                if socket.assigns.use_https do
                  {"Instance #{inst["id"]} running! Setting up DNS + HTTPS...", false}
                else
                  # HTTP-only mode: done when running
                  {"Instance #{inst["id"]} is running!", true}
                end

              other ->
                {"Instance status: #{other}", false}
            end
        end

      if done? do
        {:noreply,
         socket
         |> assign(provisioning: false, provision_status: nil)
         |> put_flash(:info, status)}
      else
        # Keep refreshing while provisioning
        Process.send_after(self(), :refresh_while_provisioning, 5_000)
        {:noreply, assign(socket, provision_status: status)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:start_instance_async, instance_id}, socket) do
    alias Lumainus.Docling.VastAI.InstanceManager

    socket =
      case Instances.start(instance_id) do
        {:ok, _} ->
          # Find the instance in our loaded list to get IP
          instance = Enum.find(socket.assigns.instances, &(&1["id"] == instance_id))

          if instance && instance["public_ipaddr"] do
            ip = instance["public_ipaddr"]
            endpoint = build_cloud_endpoint(ip)
            InstanceManager.set_endpoint(instance_id, endpoint, ip)
          end

          socket
          |> put_flash(:info, "Instance #{instance_id} starting, syncing DNS...")
          |> load_instances()
          |> ensure_start_poll()

        {:error, reason} ->
          socket
          |> put_flash(:error, "Failed to start: #{inspect(reason)}")
          |> assign(starting_instance_id: nil)
      end

    {:noreply, socket}
  end

  def handle_info(:poll_starting_instance, %{assigns: %{starting_instance_id: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_info(:poll_starting_instance, socket) do
    socket =
      socket
      |> load_instances()
      |> ensure_start_poll()

    {:noreply, socket}
  end

  # =============================================================================
  # Handle Events (all grouped together)
  # =============================================================================

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> assign(loading: true) |> load_instances() |> assign(loading: false)}
  end

  def handle_event("cancel_provisioning", _params, socket) do
    ProvisioningState.cancel()

    {:noreply,
     socket
     |> assign(provisioning: false, provision_status: nil)
     |> put_flash(
       :warning,
       "Provisioning cancelled. Note: Any created instance still exists - destroy it manually if needed."
     )}
  end

  def handle_event("clear_logs", _params, socket) do
    ProvisioningState.clear_logs()
    {:noreply, assign(socket, provision_logs: [])}
  end

  def handle_event("test_cloudflare", _params, socket) do
    socket = add_log(socket, :info, "Testing Cloudflare DNS connection...")

    # Test the Cloudflare credentials
    case Cloudflare.update_dns_record("127.0.0.1", subdomain: "test-connection") do
      {:ok, result} ->
        socket = add_log(socket, :success, "Cloudflare OK: #{inspect(result)}")
        {:noreply, put_flash(socket, :info, "Cloudflare connection successful!")}

      {:error, :missing_cloudflare_token} ->
        socket = add_log(socket, :error, "Missing LUMAINUS_DOT_COM_CLOUDFLARE_API_TOKEN env var")
        {:noreply, put_flash(socket, :error, "Missing Cloudflare API token")}

      {:error, :missing_cloudflare_zone_id} ->
        socket = add_log(socket, :error, "Missing LUMAINUS_DOT_COM_CLOUDFLARE_ZONE_ID env var")
        {:noreply, put_flash(socket, :error, "Missing Cloudflare Zone ID")}

      {:error, reason} ->
        socket = add_log(socket, :error, "Cloudflare error: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Cloudflare error: #{inspect(reason)}")}
    end
  end

  def handle_event("quick_provision", _params, socket) do
    # Quick provision with default settings (RTX 3090, HTTPS, US/CA)
    # Uses shared ProvisioningState for logs (survives page navigation)
    ProvisioningState.start_provisioning(true)
    ProvisioningState.add_log(:info, "=== QUICK PROVISION STARTED ===")
    ProvisioningState.add_log(:info, "Using defaults: RTX 3090, HTTPS, US/CA regions")

    # Spawn async task for provisioning
    filters = default_filters()
    image = @docling_image

    Task.start(fn ->
      ProvisioningState.add_log(:info, "Checking Cloudflare credentials...")

      case {Cloudflare.cloud_fqdn(), System.get_env("LUMAINUS_DOT_COM_CLOUDFLARE_API_TOKEN")} do
        {_fqdn, nil} ->
          ProvisioningState.add_log(:error, "CLOUDFLARE_API_TOKEN not set! Cannot setup HTTPS.")
          ProvisioningState.fail(:missing_cloudflare_token)

        {fqdn, _token} ->
          ProvisioningState.add_log(:success, "Cloudflare configured for #{fqdn}")
          do_provision_with_https(image, filters)
      end
    end)

    # Schedule periodic refresh while provisioning
    Process.send_after(self(), :refresh_while_provisioning, 5_000)

    {:noreply,
     socket
     |> assign(
       provisioning: true,
       provision_status: "Starting quick provisioning...",
       use_https: true
     )
     |> put_flash(:info, "Quick provisioning started! This will take 2-5 minutes.")}
  end

  def handle_event("search_offers", params, socket) do
    filters = build_filters_from_params(params)

    socket =
      socket
      |> assign(filters: filters, loading: true)
      |> load_offers()
      |> assign(loading: false)

    {:noreply, socket}
  end

  def handle_event("select_image", %{"image" => image}, socket) do
    {:noreply, assign(socket, selected_image: image)}
  end

  def handle_event("toggle_https", %{"use_https" => value}, socket) do
    use_https = value == "true"
    {:noreply, assign(socket, use_https: use_https)}
  end

  def handle_event("provision", %{"offer_id" => offer_id}, socket) do
    # Safety check: prevent provisioning if instances already exist
    existing_instances = socket.assigns.instances

    running_count =
      Enum.count(existing_instances, &(&1["actual_status"] in ["running", "loading"]))

    if running_count > 0 do
      {:noreply,
       socket
       |> put_flash(
         :error,
         "Cannot provision: #{running_count} instance(s) already active. Destroy existing instances first."
       )}
    else
      offer_id = String.to_integer(offer_id)
      offer = Enum.find(socket.assigns.offers, &(&1["id"] == offer_id))

      if offer do
        socket =
          socket
          |> assign(provisioning: true, error: nil, provision_logs: [])
          |> add_log(:info, "Starting provisioning for offer #{offer_id}...")

        image = socket.assigns.selected_image
        use_https = socket.assigns.use_https

        if use_https do
          # Use HTTPS provisioning with Caddy + Let's Encrypt
          provision_with_https(socket, offer_id, image)
        else
          # Legacy HTTP-only provisioning
          provision_http_only(socket, offer_id, image)
        end
      else
        {:noreply, put_flash(socket, :error, "Offer not found")}
      end
    end
  end

  def handle_event("check_health", %{"id" => id, "ip" => ip}, socket) do
    instance_id = String.to_integer(id)
    url = "http://#{ip}:#{cloud_port()}/health"

    result =
      case Req.get(url, receive_timeout: 10_000) do
        {:ok, %{status: 200, body: body}} -> {:ok, body}
        {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
        {:error, reason} -> {:error, inspect(reason)}
      end

    health_results = Map.put(socket.assigns.health_results, instance_id, result)
    {:noreply, assign(socket, health_results: health_results)}
  end

  def handle_event("start", %{"id" => id}, socket) do
    instance_id = String.to_integer(id)

    # Show immediate feedback and kick off async start
    send(self(), {:start_instance_async, instance_id})
    Process.send_after(self(), :poll_starting_instance, 5_000)

    {:noreply,
     socket
     |> assign(starting_instance_id: instance_id)
     |> put_flash(:info, "Starting instance #{instance_id}...")}
  end

  def handle_event("refresh_dns_status", _params, socket) do
    {:noreply, assign(socket, dns_status: compute_dns_status())}
  end

  # Manual DNS update for a running instance
  def handle_event("update_dns", %{"ip" => ip}, socket) do
    case Cloudflare.update_dns_record(ip) do
      {:ok, %{fqdn: fqdn}} ->
        {:noreply,
         socket
         |> put_flash(:info, "DNS updated: #{fqdn} → #{ip}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "DNS update failed: #{inspect(reason)}")}
    end
  end

  def handle_event("stop", %{"id" => id}, socket) do
    alias Lumainus.Docling.VastAI.InstanceManager

    instance_id = String.to_integer(id)

    case Instances.stop(instance_id) do
      {:ok, _} ->
        # Also update InstanceManager
        InstanceManager.set_stopped(instance_id)

        {:noreply,
         socket
         |> put_flash(:info, "Instance #{instance_id} stopping...")
         |> load_instances()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to stop: #{inspect(reason)}")}
    end
  end

  # Sync InstanceManager with a running instance from Vast.ai
  def handle_event("sync_instance", %{"id" => id, "ip" => ip}, socket) do
    alias Lumainus.Docling.VastAI.InstanceManager

    instance_id = String.to_integer(id)
    endpoint = build_cloud_endpoint(ip)

    InstanceManager.set_endpoint(instance_id, endpoint, ip)

    {:noreply,
     socket
     |> put_flash(:info, "Synced instance #{instance_id} with InstanceManager")}
  end

  def handle_event("destroy", %{"id" => id}, socket) do
    instance_id = String.to_integer(id)

    case Instances.destroy(instance_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Instance #{instance_id} destroyed")
         |> load_instances()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to destroy: #{inspect(reason)}")}
    end
  end

  def handle_event("set_cloud_backend", %{"ip" => ip} = params, socket) do
    use_https = params["https"] == "true"

    cloud_url =
      if use_https do
        # Use the Cloudflare-managed HTTPS domain
        VastAI.cloud_https_url()
      else
        "http://#{ip}:#{cloud_port()}"
      end

    case DoclingSettings.update_cloud_url(cloud_url) do
      {:ok, _setting} ->
        {:noreply,
         socket
         |> put_flash(:info, "Cloud backend set to #{cloud_url}")
         |> assign(active_cloud_url: cloud_url)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to set cloud URL: #{inspect(reason)}")}
    end
  end

  # =============================================================================
  # Private: Provisioning
  # =============================================================================

  defp provision_with_https(socket, _offer_id, image) do
    # Use shared ProvisioningState for logs (survives page navigation)
    ProvisioningState.start_provisioning(true)
    ProvisioningState.add_log(:info, "Using HTTPS mode with Caddy + Let's Encrypt")

    # Spawn async task for HTTPS provisioning (takes longer due to DNS + cert setup)
    Task.start(fn ->
      ProvisioningState.add_log(:info, "Checking Cloudflare credentials...")

      # First verify Cloudflare is configured
      case {Cloudflare.cloud_fqdn(), System.get_env("LUMAINUS_DOT_COM_CLOUDFLARE_API_TOKEN")} do
        {_fqdn, nil} ->
          ProvisioningState.add_log(:error, "CLOUDFLARE_API_TOKEN not set! Cannot setup HTTPS.")
          ProvisioningState.fail(:missing_cloudflare_token)

        {fqdn, _token} ->
          ProvisioningState.add_log(:success, "Cloudflare configured for #{fqdn}")
          do_provision_with_https(image, socket.assigns.filters)
      end
    end)

    # Schedule periodic refresh while provisioning
    Process.send_after(self(), :refresh_while_provisioning, 5_000)

    {:noreply,
     socket
     |> assign(provisioning: true, provision_status: "Starting HTTPS provisioning...")
     |> put_flash(:info, "Provisioning started! This will take 25-30 seconds.")}
  end

  defp do_provision_with_https(image, filters) do
    ProvisioningState.add_log(:info, "Searching for GPU offers...")
    ProvisioningState.update_status("Searching for GPU offers...")

    # Generate the Caddy onstart script that starts uvicorn and sets up HTTPS
    onstart = VastAI.caddy_onstart_script(Cloudflare.cloud_fqdn(), VastAI.cloud_port())

    opts = [
      max_price: filters.max_price,
      disk_gb: filters.disk_gb,
      geolocation: filters.geolocation,
      label: "lumainus-docling",
      image: image,
      onstart: onstart
    ]

    ProvisioningState.add_log(:info, "Creating Vast.ai instance with startup script...")
    ProvisioningState.update_status("Creating Vast.ai instance...")

    case VastAI.provision(opts) do
      {:ok, instance_id} ->
        ProvisioningState.add_log(:success, "Instance #{instance_id} created!")
        ProvisioningState.add_log(:info, "Waiting for instance to be ready (up to 5 min)...")
        ProvisioningState.update_status("Instance #{instance_id} created, waiting for boot...")

        case VastAI.wait_for_ready(instance_id, 300_000) do
          {:ok, instance} ->
            ProvisioningState.add_log(:success, "Instance is running!")
            ProvisioningState.update_status("Instance running, setting up DNS...")

            case instance["public_ipaddr"] do
              ip when is_binary(ip) and ip != "" ->
                ProvisioningState.add_log(:info, "Public IP: #{ip}")
                ProvisioningState.add_log(:info, "Updating Cloudflare DNS...")
                ProvisioningState.update_status("Updating Cloudflare DNS for #{ip}...")

                case Cloudflare.update_dns_record(ip) do
                  {:ok, dns_result} ->
                    ProvisioningState.add_log(
                      :success,
                      "DNS updated: #{dns_result.fqdn} -> #{ip}"
                    )

                    endpoint = "https://#{dns_result.fqdn}"
                    ProvisioningState.add_log(:info, "HTTPS endpoint: #{endpoint}")

                    ProvisioningState.add_log(
                      :info,
                      "Note: SSL cert will be obtained by Caddy on first request (may take 1-2 min)"
                    )

                    # Auto-set as cloud backend
                    DoclingSettings.update_cloud_url(endpoint)
                    ProvisioningState.complete(instance_id, endpoint)

                  {:error, dns_error} ->
                    ProvisioningState.add_log(:error, "DNS update failed: #{inspect(dns_error)}")
                    # Still return success but with HTTP URL
                    endpoint = "http://#{ip}:#{VastAI.cloud_port()}"
                    ProvisioningState.add_log(:warning, "Falling back to HTTP: #{endpoint}")
                    DoclingSettings.update_cloud_url(endpoint)
                    ProvisioningState.complete(instance_id, endpoint)
                end

              _ ->
                ProvisioningState.add_log(:error, "Instance has no public IP!")
                ProvisioningState.fail(:no_public_ip)
            end

          {:error, wait_error} ->
            ProvisioningState.add_log(:error, "Instance failed to start: #{inspect(wait_error)}")
            ProvisioningState.fail(wait_error)
        end

      {:error, provision_error} ->
        ProvisioningState.add_log(
          :error,
          "Failed to create instance: #{inspect(provision_error)}"
        )

        ProvisioningState.fail(provision_error)
    end
  end

  defp provision_http_only(socket, offer_id, image) do
    create_params =
      %{
        image: image,
        disk: socket.assigns.filters.disk_gb,
        label: "lumainus-docling",
        runtype: "ssh"
      }
      |> maybe_add_docker_login(image)

    socket =
      socket
      |> assign(provision_status: "Creating instance...")
      |> add_log(:info, "Creating HTTP-only instance...")

    case Instances.create(offer_id, create_params) do
      {:ok, %{"new_contract" => instance_id}} ->
        # Start refresh loop
        Process.send_after(self(), :refresh_while_provisioning, 5_000)

        {:noreply,
         socket
         |> add_log(:success, "Instance #{instance_id} created!")
         |> put_flash(:info, "Instance #{instance_id} created! Waiting for it to start...")
         |> assign(
           provisioning: true,
           provision_status: "Instance #{instance_id} created, waiting for boot..."
         )
         |> load_instances()}

      {:ok, resp} ->
        {:noreply,
         socket
         |> add_log(:warning, "Unexpected response: #{inspect(resp)}")
         |> put_flash(:info, "Provisioned: #{inspect(resp)}")
         |> assign(provisioning: false, provision_status: nil)
         |> load_instances()}

      {:error, reason} ->
        {:noreply,
         socket
         |> add_log(:error, "Failed to provision: #{inspect(reason)}")
         |> put_flash(:error, "Failed to provision: #{inspect(reason)}")
         |> assign(provisioning: false, provision_status: nil, error: reason)}
    end
  end

  # =============================================================================
  # Private: Helpers
  # =============================================================================

  defp add_log(socket, level, message) do
    log_entry = %{
      level: level,
      message: message,
      timestamp: DateTime.utc_now()
    }

    logs = [log_entry | socket.assigns.provision_logs] |> Enum.take(50)
    assign(socket, provision_logs: logs)
  end

  defp load_instances(socket) do
    socket =
      case Instances.list() do
        {:ok, %{"instances" => instances}} ->
          assign(socket, instances: instances, error: nil)

        {:error, reason} ->
          assign(socket, instances: [], error: reason)
      end

    socket
    |> assign(dns_status: compute_dns_status())
    |> maybe_clear_starting_indicator()
  end

  defp load_offers(socket) do
    filters = socket.assigns.filters

    api_filters =
      Offers.build_filters(
        gpu_name: filters.gpu_name,
        num_gpus: filters.num_gpus,
        verified: true,
        rentable: true,
        geolocation: filters.geolocation,
        dph_total: {:lte, filters.max_price},
        cpu_ram: {:gte, filters.min_ram_gb},
        cpu_cores: {:gte, filters.min_cpu_cores},
        inet_down: {:gte, filters.min_inet_down},
        disk_space: {:gte, filters.disk_gb}
      )

    case Offers.search(filters: api_filters, limit: 10) do
      {:ok, %{"offers" => offers}} ->
        assign(socket, offers: offers, error: nil)

      {:error, reason} ->
        assign(socket, offers: [], error: reason)
    end
  end

  defp build_filters_from_params(params) do
    %{
      gpu_name: params["gpu_name"] || "RTX 3090",
      num_gpus: parse_int(params["num_gpus"], 1),
      max_price: parse_float(params["max_price"], 0.25),
      disk_gb: parse_int(params["disk_gb"], 16),
      min_ram_gb: parse_int(params["min_ram_gb"], 16),
      min_cpu_cores: parse_int(params["min_cpu_cores"], 4),
      min_inet_down: parse_int(params["min_inet_down"], 100),
      geolocation: parse_geolocation(params["geolocation"])
    }
  end

  defp default_filters do
    %{
      gpu_name: "RTX 3090",
      num_gpus: 1,
      max_price: 0.25,
      disk_gb: 16,
      min_ram_gb: 16,
      min_cpu_cores: 4,
      min_inet_down: 100,
      geolocation: ["US", "CA"]
    }
  end

  defp compute_dns_status do
    fqdn = Cloudflare.cloud_fqdn()
    zone_id = System.get_env("LUMAINUS_DOT_COM_CLOUDFLARE_ZONE_ID")
    token = System.get_env("LUMAINUS_DOT_COM_CLOUDFLARE_API_TOKEN")

    {dns_state, resolved_ips} =
      case resolve_dns_ips(fqdn) do
        {:ok, ips} -> {:ok, ips}
        {:error, reason} -> {reason, []}
      end

    %{
      fqdn: fqdn,
      zone_id: mask_zone_id(zone_id),
      token_present?: token not in [nil, ""],
      dns_state: dns_state,
      resolved_ips: resolved_ips,
      checked_at: DateTime.utc_now()
    }
  end

  defp resolve_dns_ips(fqdn) when fqdn in [nil, ""] do
    {:error, :no_fqdn_configured}
  end

  defp resolve_dns_ips(fqdn) do
    try do
      case :inet_res.lookup(String.to_charlist(fqdn), :in, :a) do
        [] -> {:ok, []}
        addresses -> {:ok, Enum.map(addresses, &tuple_to_ip/1)}
      end
    rescue
      error -> {:error, error}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp maybe_clear_starting_indicator(socket) do
    starting_id = socket.assigns[:starting_instance_id]
    instances = socket.assigns[:instances] || []

    cond do
      is_nil(starting_id) ->
        socket

      instance = Enum.find(instances, &(&1["id"] == starting_id)) ->
        if instance["actual_status"] == "running" do
          assign(socket, starting_instance_id: nil)
        else
          socket
        end

      true ->
        socket
    end
  end

  defp ensure_start_poll(%{assigns: %{starting_instance_id: nil}} = socket), do: socket

  defp ensure_start_poll(socket) do
    Process.send_after(self(), :poll_starting_instance, 5_000)
    socket
  end

  defp tuple_to_ip(tuple) do
    tuple
    |> :inet.ntoa()
    |> to_string()
  end

  defp mask_zone_id(nil), do: nil
  defp mask_zone_id(""), do: nil

  defp mask_zone_id(zone_id) when is_binary(zone_id) do
    prefix = String.slice(zone_id, 0, 6)
    suffix = String.slice(zone_id, -4, 4)
    "#{prefix}...#{suffix}"
  end

  defp format_timestamp(nil), do: ""

  defp format_timestamp(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default
  defp parse_int(val, _default) when is_integer(val), do: val

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_float(nil, default), do: default
  defp parse_float("", default), do: default
  defp parse_float(val, _default) when is_float(val), do: val

  defp parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_geolocation(nil), do: ["US", "CA"]
  defp parse_geolocation(""), do: ["US", "CA"]

  defp parse_geolocation(val) when is_binary(val) do
    val |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_geolocation(val) when is_list(val), do: val

  defp build_cloud_endpoint(ip) do
    # Use HTTPS via Cloudflare if configured, otherwise HTTP
    fqdn = Cloudflare.cloud_fqdn()

    if fqdn && String.trim(fqdn) != "" do
      "https://#{fqdn}"
    else
      "http://#{ip}:#{cloud_port()}"
    end
  end

  defp docling_image, do: @docling_image
  defp pytorch_image, do: @pytorch_image

  # Add docker_login for private ghcr.io images
  defp maybe_add_docker_login(params, image) do
    if String.starts_with?(image, "ghcr.io/") do
      ghcr_user = Application.get_env(:lumainus, :ghcr_user) || "nshkrdotcom"
      ghcr_token = Application.get_env(:lumainus, :ghcr_token) || System.get_env("GHCR_TOKEN")

      if ghcr_token do
        Map.put(params, :docker_login, "#{ghcr_user}:#{ghcr_token}")
      else
        params
      end
    else
      params
    end
  end

  defp has_active_instances?(instances) do
    Enum.any?(instances, &(&1["actual_status"] in ["running", "loading"]))
  end

  defp status_badge_class("running") do
    "inline-flex items-center rounded-full bg-green-100 px-2 py-1 text-xs font-semibold text-green-800"
  end

  defp status_badge_class("loading") do
    "inline-flex items-center rounded-full bg-yellow-100 px-2 py-1 text-xs font-semibold text-yellow-800"
  end

  defp status_badge_class("exited") do
    "inline-flex items-center rounded-full bg-red-100 px-2 py-1 text-xs font-semibold text-red-800"
  end

  defp status_badge_class(_) do
    "inline-flex items-center rounded-full bg-gray-100 px-2 py-1 text-xs font-semibold text-gray-800"
  end

  defp log_level_class(:success), do: "text-green-400"
  defp log_level_class(:error), do: "text-red-400"
  defp log_level_class(:warning), do: "text-yellow-400"
  defp log_level_class(_), do: "text-blue-400"

  defp log_level_icon(:success), do: "✓"
  defp log_level_icon(:error), do: "✗"
  defp log_level_icon(:warning), do: "⚠"
  defp log_level_icon(_), do: "→"

  defp get_auto_shutdown_status do
    config = Application.get_env(:lumainus, :vast_ai_auto_shutdown, [])
    activity = ActivityTracker.status()

    %{
      enabled: Keyword.get(config, :enabled, true),
      check_interval: Keyword.get(config, :check_interval_minutes, 5),
      idle_timeout: Keyword.get(config, :idle_timeout_minutes, 15),
      last_activity: activity.last_activity,
      idle_minutes: activity.idle_minutes,
      idle_formatted: activity.idle_formatted
    }
  end

  # =============================================================================
  # Render
  # =============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-3xl font-bold text-gray-900 dark:text-gray-100">Vast.ai GPU Instances</h1>
          <p class="mt-2 text-sm text-gray-600 dark:text-gray-300">
            Manage GPU instances for document processing
          </p>
        </div>
        <div class="flex items-center gap-3">
          <.link
            navigate={~p"/admin/gpu_events"}
            class="px-4 py-2 text-sm font-medium text-blue-700 dark:text-blue-300 bg-blue-50 dark:bg-blue-900/30 border border-blue-200 dark:border-blue-700 rounded-md hover:bg-blue-100 dark:hover:bg-blue-900/50"
          >
            Event History
          </.link>
          <button
            type="button"
            phx-click="refresh"
            disabled={@loading}
            class="px-4 py-2 text-sm font-medium text-gray-700 dark:text-gray-200 bg-white dark:bg-gray-700 border border-gray-300 dark:border-gray-600 rounded-md hover:bg-gray-50 dark:hover:bg-gray-600 disabled:opacity-50"
          >
            {if @loading, do: "Loading...", else: "Refresh"}
          </button>
        </div>
      </div>

      <%= if @error do %>
        <div class="bg-red-50 dark:bg-red-900/30 border border-red-200 dark:border-red-700 rounded-lg p-4">
          <p class="text-sm text-red-800 dark:text-red-200">Error: {@error |> inspect()}</p>
        </div>
      <% end %>

      <%!-- Quick Provision Panel - shows when no instances exist --%>
      <%= if @instances == [] and not @provisioning do %>
        <div class="rounded-xl border border-sky-200 bg-gradient-to-r from-sky-50 to-indigo-50 dark:from-sky-900/30 dark:to-indigo-900/30 dark:border-sky-700 px-6 py-5 shadow-sm">
          <div class="flex items-center justify-between gap-6">
            <div class="flex items-center gap-4">
              <div class="flex h-14 w-14 items-center justify-center rounded-full bg-sky-100 dark:bg-sky-800 text-sky-600 dark:text-sky-300">
                <svg
                  class="h-7 w-7"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="1.5"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M8.25 3v1.5M4.5 8.25H3m18 0h-1.5M4.5 12H3m18 0h-1.5m-15 3.75H3m18 0h-1.5M8.25 19.5V21M12 3v1.5m0 15V21m3.75-18v1.5m0 15V21m-9-1.5h10.5a2.25 2.25 0 002.25-2.25V6.75a2.25 2.25 0 00-2.25-2.25H6.75A2.25 2.25 0 004.5 6.75v10.5a2.25 2.25 0 002.25 2.25zm.75-12h9v9h-9v-9z"
                  />
                </svg>
              </div>
              <div class="flex flex-col">
                <span class="text-lg font-semibold text-gray-900 dark:text-gray-100">
                  No GPU Instance Running
                </span>
                <span class="text-sm text-gray-600 dark:text-gray-400 mt-1">
                  Provision a GPU instance to enable fast document processing (~10x faster than CPU).
                </span>
              </div>
            </div>
            <button
              type="button"
              phx-click="quick_provision"
              class="rounded-lg px-5 py-3 text-sm font-semibold text-white shadow-sm transition-colors bg-sky-600 hover:bg-sky-500"
            >
              <span class="flex items-center gap-2">
                <svg
                  class="h-5 w-5"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="1.5"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M3.75 13.5l10.5-11.25L12 10.5h8.25L9.75 21.75 12 13.5H3.75z"
                  />
                </svg>
                Quick Provision GPU
              </span>
            </button>
          </div>
          <div class="mt-4 flex items-center gap-4 text-xs text-gray-500 dark:text-gray-400">
            <span class="flex items-center gap-1">
              <svg
                class="h-4 w-4"
                fill="none"
                viewBox="0 0 24 24"
                stroke-width="1.5"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M12 6v6h4.5m4.5 0a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
              ~2-5 min provision time
            </span>
            <span class="flex items-center gap-1">
              <svg
                class="h-4 w-4"
                fill="none"
                viewBox="0 0 24 24"
                stroke-width="1.5"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M2.25 18.75a60.07 60.07 0 0115.797 2.101c.727.198 1.453-.342 1.453-1.096V18.75M3.75 4.5v.75A.75.75 0 013 6h-.75m0 0v-.375c0-.621.504-1.125 1.125-1.125H20.25M2.25 6v9m18-10.5v.75c0 .414.336.75.75.75h.75m-1.5-1.5h.375c.621 0 1.125.504 1.125 1.125v9.75c0 .621-.504 1.125-1.125 1.125h-.375m1.5-1.5H21a.75.75 0 00-.75.75v.75m0 0H3.75m0 0h-.375a1.125 1.125 0 01-1.125-1.125V15m1.5 1.5v-.75A.75.75 0 003 15h-.75M15 10.5a3 3 0 11-6 0 3 3 0 016 0zm3 0h.008v.008H18V10.5zm-12 0h.008v.008H6V10.5z"
                />
              </svg>
              ~$0.15-0.25/hr (RTX 3090)
            </span>
            <span class="flex items-center gap-1">
              <svg
                class="h-4 w-4"
                fill="none"
                viewBox="0 0 24 24"
                stroke-width="1.5"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M16.5 10.5V6.75a4.5 4.5 0 10-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 002.25-2.25v-6.75a2.25 2.25 0 00-2.25-2.25H6.75a2.25 2.25 0 00-2.25 2.25v6.75a2.25 2.25 0 002.25 2.25z"
                />
              </svg>
              HTTPS via Cloudflare
            </span>
          </div>
        </div>
      <% end %>

      <%= if @provisioning do %>
        <div class="bg-blue-50 dark:bg-blue-900/30 border border-blue-200 dark:border-blue-700 rounded-lg p-6">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-4">
              <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600"></div>
              <div>
                <h3 class="text-lg font-semibold text-blue-900 dark:text-blue-100">
                  Provisioning in Progress
                </h3>
                <p class="text-sm text-blue-700 dark:text-blue-300 mt-1">
                  {@provision_status || "Initializing..."}
                </p>
                <p class="text-xs text-blue-600 dark:text-blue-400 mt-2">
                  This typically takes 25-30 seconds. Auto-refreshing every 5 seconds.
                </p>
              </div>
            </div>
            <button
              type="button"
              phx-click="cancel_provisioning"
              class="px-4 py-2 text-sm font-medium text-red-700 bg-red-100 rounded-md hover:bg-red-200"
            >
              Cancel
            </button>
          </div>
          <div class="mt-4 bg-blue-100 dark:bg-blue-800/50 rounded p-3">
            <p class="text-xs text-blue-800 dark:text-blue-200 font-mono">
              <%= if @use_https do %>
                Steps: Create instance → Wait for boot → Update DNS → Install Caddy → Get SSL cert
              <% else %>
                Steps: Create instance → Wait for boot → Ready!
              <% end %>
            </p>
          </div>
        </div>
      <% end %>
      
    <!-- Current Instances -->
      <div class="bg-white dark:bg-gray-800 shadow-sm rounded-lg p-6">
        <h2 class="text-xl font-semibold mb-4 text-gray-900 dark:text-gray-100">
          Active Instances ({length(@instances)})
        </h2>

        <div class="grid gap-4 md:grid-cols-2 mb-4">
          <div class="rounded-lg border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800/50 p-4">
            <div class="flex items-center justify-between mb-2">
              <p class="text-sm font-semibold text-gray-800 dark:text-gray-100">DNS configuration</p>
              <span class="text-xs text-gray-500 dark:text-gray-400">Cloudflare</span>
            </div>
            <div class="space-y-1 text-sm text-gray-700 dark:text-gray-200">
              <div class="flex items-center gap-2">
                <span class="text-gray-500 dark:text-gray-400">FQDN:</span>
                <code class="px-2 py-1 bg-white/80 dark:bg-gray-900/60 rounded text-xs">
                  {if @dns_status.fqdn && @dns_status.fqdn != "",
                    do: @dns_status.fqdn,
                    else: "not configured"}
                </code>
              </div>
              <div class="flex items-center gap-2">
                <span class="text-gray-500 dark:text-gray-400">Zone ID:</span>
                <code class="px-2 py-1 bg-white/80 dark:bg-gray-900/60 rounded text-xs">
                  {if @dns_status.zone_id, do: @dns_status.zone_id, else: "not set"}
                </code>
              </div>
              <div class="flex items-center gap-2 text-xs">
                <span class={[
                  "inline-flex items-center gap-1 px-2 py-1 rounded-full",
                  @dns_status.token_present? && "bg-green-100 text-green-800",
                  !@dns_status.token_present? && "bg-red-100 text-red-800"
                ]}>
                  <span class={[
                    "w-2 h-2 rounded-full",
                    @dns_status.token_present? && "bg-green-500",
                    !@dns_status.token_present? && "bg-red-500"
                  ]}>
                  </span>
                  {if @dns_status.token_present?, do: "API token present", else: "Missing API token"}
                </span>
              </div>
            </div>
          </div>

          <div class="rounded-lg border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800/50 p-4">
            <div class="flex items-center justify-between mb-2">
              <p class="text-sm font-semibold text-gray-800 dark:text-gray-100">
                Live DNS record (dig)
              </p>
              <button
                type="button"
                phx-click="refresh_dns_status"
                class="text-xs px-2 py-1 rounded bg-blue-100 text-blue-800 hover:bg-blue-200 dark:bg-blue-900/40 dark:text-blue-100"
              >
                Refresh
              </button>
            </div>
            <div class="space-y-1 text-sm text-gray-700 dark:text-gray-200">
              <div class="flex items-start gap-2">
                <span class="text-gray-500 dark:text-gray-400">A record:</span>
                <div class="space-y-1">
                  <%= cond do %>
                    <% @dns_status.dns_state == :ok and @dns_status.resolved_ips == [] -> %>
                      <span class="text-xs text-amber-700 dark:text-amber-300">
                        No A records returned
                      </span>
                    <% @dns_status.dns_state == :ok -> %>
                      <div class="flex flex-wrap gap-1">
                        <%= for ip <- @dns_status.resolved_ips do %>
                          <code class="px-2 py-1 bg-white/80 dark:bg-gray-900/60 rounded text-xs">
                            {ip}
                          </code>
                        <% end %>
                      </div>
                    <% true -> %>
                      <span class="text-xs text-red-700 dark:text-red-300">
                        DNS lookup error: {inspect(@dns_status.dns_state)}
                      </span>
                  <% end %>
                </div>
              </div>
              <div class="text-xs text-gray-500 dark:text-gray-400">
                Checked at: {format_timestamp(@dns_status.checked_at)}
              </div>
            </div>
          </div>
        </div>

        <%= if @instances == [] do %>
          <p class="text-center text-gray-500 dark:text-gray-400 py-8">
            No active instances. Search for offers below to provision one.
          </p>
        <% else %>
          <div class="space-y-4">
            <%= for instance <- @instances do %>
              <div class="border border-gray-200 dark:border-gray-700 rounded-lg p-4">
                <div class="flex items-start justify-between">
                  <div class="flex-1">
                    <div class="flex items-center gap-3 mb-2">
                      <span class="font-mono text-sm font-semibold text-gray-900 dark:text-gray-100">
                        #{instance["id"]}
                      </span>
                      <span class={status_badge_class(instance["actual_status"])}>
                        {instance["actual_status"] || "unknown"}
                      </span>
                      <span class="inline-flex items-center rounded-full bg-blue-100 px-2 py-1 text-xs font-medium text-blue-800">
                        {instance["gpu_name"]}
                      </span>
                    </div>

                    <div class="grid grid-cols-2 md:grid-cols-4 gap-4 text-sm text-gray-600 dark:text-gray-300">
                      <div>
                        <span class="font-medium">Location:</span>
                        {instance["geolocation"]}
                      </div>
                      <div>
                        <span class="font-medium">Cost:</span>
                        ${Float.round((instance["dph_total"] || 0) * 1.0, 3)}/hr
                      </div>
                      <div>
                        <span class="font-medium">GPU RAM:</span>
                        {div(instance["gpu_ram"] || 0, 1024)} GB
                      </div>
                      <div>
                        <span class="font-medium">Label:</span>
                        {instance["label"] || "—"}
                      </div>
                    </div>

                    <%= if instance["ssh_host"] do %>
                      <div class="mt-3 p-2 bg-gray-50 dark:bg-gray-700 rounded text-xs font-mono text-gray-800 dark:text-gray-200">
                        ssh -p {instance["ssh_port"]} root@{instance["ssh_host"]}
                      </div>
                    <% end %>

                    <%= if instance["public_ipaddr"] do %>
                      <div class="mt-3 flex items-center gap-2 text-sm text-gray-700 dark:text-gray-200">
                        <span class="font-medium">Instance IP:</span>
                        <code class="px-2 py-1 bg-gray-100 dark:bg-gray-900/60 rounded text-xs">
                          {instance["public_ipaddr"]}
                        </code>
                      </div>
                    <% end %>

                    <%= if instance["public_ipaddr"] && instance["actual_status"] == "running" do %>
                      <div class="mt-2 space-y-2">
                        <div class="flex items-center gap-2">
                          <span class="text-xs text-gray-500 dark:text-gray-400">HTTP:</span>
                          <code class="text-xs bg-blue-50 dark:bg-blue-900/30 text-blue-800 dark:text-blue-200 px-2 py-1 rounded">
                            http://{instance["public_ipaddr"]}:{cloud_port()}
                          </code>
                          <button
                            type="button"
                            phx-click="check_health"
                            phx-value-id={instance["id"]}
                            phx-value-ip={instance["public_ipaddr"]}
                            class="px-2 py-1 text-xs font-medium text-blue-700 bg-blue-100 rounded hover:bg-blue-200"
                          >
                            Test
                          </button>
                          <button
                            type="button"
                            phx-click="set_cloud_backend"
                            phx-value-ip={instance["public_ipaddr"]}
                            phx-value-https="false"
                            class="px-2 py-1 text-xs font-medium text-purple-700 bg-purple-100 rounded hover:bg-purple-200"
                          >
                            Use HTTP
                          </button>
                        </div>
                        <div class="flex items-center gap-2">
                          <span class="text-xs text-gray-500 dark:text-gray-400">HTTPS:</span>
                          <code class="text-xs bg-green-50 dark:bg-green-900/30 text-green-800 dark:text-green-200 px-2 py-1 rounded">
                            https://docling.lumainus.com
                          </code>
                          <button
                            type="button"
                            phx-click="set_cloud_backend"
                            phx-value-ip={instance["public_ipaddr"]}
                            phx-value-https="true"
                            class="px-2 py-1 text-xs font-medium text-green-700 bg-green-100 rounded hover:bg-green-200"
                          >
                            Use HTTPS
                          </button>
                          <button
                            type="button"
                            phx-click="sync_instance"
                            phx-value-id={instance["id"]}
                            phx-value-ip={instance["public_ipaddr"]}
                            class="px-2 py-1 text-xs font-medium text-cyan-700 bg-cyan-100 rounded hover:bg-cyan-200"
                            title="Sync this instance to InstanceManager so /reports can use it"
                          >
                            Sync
                          </button>
                          <button
                            type="button"
                            phx-click="update_dns"
                            phx-value-ip={instance["public_ipaddr"]}
                            class="px-2 py-1 text-xs font-medium text-orange-700 bg-orange-100 rounded hover:bg-orange-200"
                            title="Update Cloudflare DNS to point docling.lumainus.com to this IP"
                          >
                            Update DNS
                          </button>
                        </div>
                        <%= case @health_results[instance["id"]] do %>
                          <% {:ok, _} -> %>
                            <span class="text-xs text-green-600 dark:text-green-400 font-medium">
                              ✓ Healthy
                            </span>
                          <% {:error, err} -> %>
                            <span class="text-xs text-red-600 dark:text-red-400 font-medium">
                              ✗ {err}
                            </span>
                          <% nil -> %>
                        <% end %>
                      </div>
                    <% end %>
                  </div>

                  <div class="flex items-center gap-3 ml-4">
                    <%= if @starting_instance_id == instance["id"] do %>
                      <div class="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-300">
                        <span class="h-4 w-4 border-2 border-blue-300 border-t-blue-700 rounded-full animate-spin">
                        </span>
                        Starting...
                      </div>
                    <% end %>

                    <div class="flex gap-2">
                      <%= if instance["actual_status"] == "running" do %>
                        <button
                          type="button"
                          phx-click="stop"
                          phx-value-id={instance["id"]}
                          class="px-3 py-1 text-sm font-medium text-amber-700 bg-amber-100 rounded hover:bg-amber-200"
                        >
                          Stop
                        </button>
                      <% else %>
                        <button
                          type="button"
                          phx-click="start"
                          phx-value-id={instance["id"]}
                          class={[
                            "px-3 py-1 text-sm font-medium rounded",
                            instance["actual_status"] == "running" &&
                              "text-gray-400 bg-gray-100 cursor-not-allowed",
                            @starting_instance_id == instance["id"] &&
                              "text-gray-500 bg-gray-100 cursor-wait",
                            instance["actual_status"] != "running" &&
                              @starting_instance_id != instance["id"] &&
                              "text-green-700 bg-green-100 hover:bg-green-200"
                          ]}
                          disabled={
                            instance["actual_status"] == "running" ||
                              @starting_instance_id == instance["id"]
                          }
                        >
                          <%= if @starting_instance_id == instance["id"] do %>
                            Starting...
                          <% else %>
                            Start
                          <% end %>
                        </button>
                      <% end %>
                      <button
                        type="button"
                        phx-click="destroy"
                        phx-value-id={instance["id"]}
                        data-confirm={"Are you sure you want to destroy instance #{instance["id"]}? This cannot be undone."}
                        class="px-3 py-1 text-sm font-medium text-red-700 bg-red-100 rounded hover:bg-red-200"
                      >
                        Destroy
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
      
    <!-- Auto-Shutdown Status & Configuration -->
      <div class="bg-white dark:bg-gray-800 shadow-sm rounded-lg p-6">
        <div class="flex items-start justify-between mb-4">
          <div>
            <h2 class="text-xl font-semibold text-gray-900 dark:text-gray-100">Auto-Shutdown</h2>
            <p class="text-sm text-gray-500 dark:text-gray-400 mt-1">
              Automatically destroys idle GPU instances to save money
            </p>
          </div>
          <span class={[
            "inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold",
            if(@auto_shutdown_status.enabled,
              do: "bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300",
              else: "bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-300"
            )
          ]}>
            {if @auto_shutdown_status.enabled, do: "Enabled", else: "Disabled"}
          </span>
        </div>

        <div class="grid md:grid-cols-2 gap-6">
          <!-- Current Status -->
          <div class="space-y-3">
            <h3 class="text-sm font-semibold text-gray-700 dark:text-gray-200 uppercase tracking-wide">
              Current Status
            </h3>
            <div class="bg-gray-50 dark:bg-gray-700 rounded-lg p-4 space-y-2">
              <div class="flex justify-between text-sm">
                <span class="text-gray-600 dark:text-gray-300">Last Activity</span>
                <span class="font-mono text-gray-900 dark:text-gray-100">
                  {@auto_shutdown_status.idle_formatted}
                </span>
              </div>
              <div class="flex justify-between text-sm">
                <span class="text-gray-600 dark:text-gray-300">Idle Timeout</span>
                <span class="font-mono text-gray-900 dark:text-gray-100">
                  {@auto_shutdown_status.idle_timeout} minutes
                </span>
              </div>
              <div class="flex justify-between text-sm">
                <span class="text-gray-600 dark:text-gray-300">Check Interval</span>
                <span class="font-mono text-gray-900 dark:text-gray-100">
                  Every {@auto_shutdown_status.check_interval} minutes
                </span>
              </div>
              <%= if @auto_shutdown_status.idle_minutes != :never && @auto_shutdown_status.idle_minutes >= @auto_shutdown_status.idle_timeout do %>
                <div class="mt-2 p-2 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-700 rounded text-xs text-amber-800 dark:text-amber-200">
                  Instance will be destroyed on next check (idle > timeout)
                </div>
              <% end %>
            </div>
          </div>
          
    <!-- Configuration -->
          <div class="space-y-3">
            <h3 class="text-sm font-semibold text-gray-700 dark:text-gray-200 uppercase tracking-wide">
              Configuration
            </h3>
            <div class="bg-gray-50 dark:bg-gray-700 rounded-lg p-4 text-xs font-mono text-gray-700 dark:text-gray-300 space-y-2">
              <p class="text-gray-500 dark:text-gray-400 font-sans text-sm mb-2">
                In <code class="bg-gray-200 dark:bg-gray-600 px-1 rounded">config/config.exs</code>:
              </p>
              <pre class="whitespace-pre-wrap">
                config :lumainus, :vast_ai_auto_shutdown,
                  enabled: true,
                  check_interval_minutes: {@auto_shutdown_status.check_interval},
                  idle_timeout_minutes: {@auto_shutdown_status.idle_timeout}
              </pre>
            </div>
          </div>
        </div>
        
    <!-- Crontab Usage -->
        <div class="mt-6 border-t border-gray-200 dark:border-gray-600 pt-4">
          <h3 class="text-sm font-semibold text-gray-700 dark:text-gray-200 uppercase tracking-wide mb-3">
            External Scheduling (Crontab)
          </h3>
          <p class="text-sm text-gray-600 dark:text-gray-400 mb-3">
            The app runs auto-shutdown checks internally. For external scheduling via crontab:
          </p>
          <div class="bg-gray-900 rounded-lg p-4 text-xs font-mono text-gray-300 space-y-3 overflow-x-auto">
            <div>
              <span class="text-gray-500"># Development (with Mix)</span>
              <br />
              <span class="text-green-400">*/5 * * * *</span>
              cd /path/to/lumainus && mix vast_ai.cleanup
            </div>
            <div>
              <span class="text-gray-500"># Production release</span>
              <br />
              <span class="text-green-400">*/5 * * * *</span>
              cd /app && bin/lumainus eval "Lumainus.Docling.VastAI.AutoShutdown.check_and_shutdown()"
            </div>
            <div>
              <span class="text-gray-500"># Or use the included shell script</span>
              <br />
              <span class="text-green-400">*/5 * * * *</span>
              /path/to/lumainus/scripts/vast_ai_cleanup.sh >> /var/log/vast_cleanup.log 2>&1
            </div>
          </div>
          <div class="mt-3 text-xs text-gray-500 dark:text-gray-400">
            <strong>Mix task options:</strong>
            <code class="ml-2 bg-gray-100 dark:bg-gray-700 px-1 rounded">--dry-run</code>
            <code class="ml-1 bg-gray-100 dark:bg-gray-700 px-1 rounded">--force</code>
            <code class="ml-1 bg-gray-100 dark:bg-gray-700 px-1 rounded">--timeout MINUTES</code>
          </div>
        </div>
      </div>
      
    <!-- Search Offers -->
      <div class="bg-white dark:bg-gray-800 shadow-sm rounded-lg p-6">
        <h2 class="text-xl font-semibold mb-4 text-gray-900 dark:text-gray-100">Search GPU Offers</h2>

        <.form for={%{}} phx-submit="search_offers" class="space-y-4 mb-6">
          <div class="grid gap-4 md:grid-cols-4">
            <div>
              <label class="block text-sm font-medium text-gray-700 dark:text-gray-200 mb-1">
                GPU Model
              </label>
              <select
                name="gpu_name"
                class="w-full rounded-md border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 text-sm"
              >
                <option value="RTX 3090" selected={@filters.gpu_name == "RTX 3090"}>RTX 3090</option>
                <option value="RTX 4090" selected={@filters.gpu_name == "RTX 4090"}>RTX 4090</option>
                <option value="A100" selected={@filters.gpu_name == "A100"}>A100</option>
                <option value="H100" selected={@filters.gpu_name == "H100"}>H100</option>
              </select>
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-700 dark:text-gray-200 mb-1">
                # GPUs
              </label>
              <input
                type="number"
                name="num_gpus"
                value={@filters.num_gpus}
                min="1"
                max="8"
                class="w-full rounded-md border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 text-sm"
              />
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-700 dark:text-gray-200 mb-1">
                Max $/hr
              </label>
              <input
                type="number"
                name="max_price"
                value={@filters.max_price}
                min="0.01"
                step="0.01"
                class="w-full rounded-md border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 text-sm"
              />
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-700 dark:text-gray-200 mb-1">
                Region
              </label>
              <input
                type="text"
                name="geolocation"
                value={Enum.join(@filters.geolocation, ", ")}
                placeholder="US, CA"
                class="w-full rounded-md border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 text-sm"
              />
            </div>
          </div>

          <div class="grid gap-4 md:grid-cols-4">
            <div>
              <label class="block text-sm font-medium text-gray-700 dark:text-gray-200 mb-1">
                Min RAM (GB)
              </label>
              <input
                type="number"
                name="min_ram_gb"
                value={@filters.min_ram_gb}
                min="4"
                class="w-full rounded-md border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 text-sm"
              />
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-700 dark:text-gray-200 mb-1">
                Min CPU Cores
              </label>
              <input
                type="number"
                name="min_cpu_cores"
                value={@filters.min_cpu_cores}
                min="1"
                class="w-full rounded-md border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 text-sm"
              />
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-700 dark:text-gray-200 mb-1">
                Min Disk (GB)
              </label>
              <input
                type="number"
                name="disk_gb"
                value={@filters.disk_gb}
                min="8"
                class="w-full rounded-md border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 text-sm"
              />
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-700 dark:text-gray-200 mb-1">
                Min Network (Mb/s)
              </label>
              <input
                type="number"
                name="min_inet_down"
                value={@filters.min_inet_down}
                min="10"
                class="w-full rounded-md border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 text-sm"
              />
            </div>
          </div>

          <div class="md:col-span-5 flex items-end gap-4">
            <button
              type="submit"
              disabled={@loading}
              class="px-4 py-2 text-sm font-medium text-white bg-blue-600 rounded-md hover:bg-blue-700 disabled:opacity-50"
            >
              {if @loading, do: "Searching...", else: "Search Offers"}
            </button>

            <div class="flex-1">
              <label class="block text-sm font-medium text-gray-700 dark:text-gray-200 mb-1">
                Docker Image
              </label>
              <select
                name="image"
                phx-change="select_image"
                class="w-full rounded-md border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 text-sm"
              >
                <option value={docling_image()} selected={@selected_image == docling_image()}>
                  Docling GPU (pre-built, ~3-5 min boot)
                </option>
                <option value={pytorch_image()} selected={@selected_image == pytorch_image()}>
                  PyTorch Base (needs manual setup)
                </option>
              </select>
            </div>

            <div class="flex items-center gap-2">
              <input
                type="checkbox"
                id="use_https"
                checked={@use_https}
                phx-click="toggle_https"
                phx-value-use_https={if @use_https, do: "false", else: "true"}
                class="h-4 w-4 rounded border-gray-300 text-green-600 focus:ring-green-600"
              />
              <label for="use_https" class="text-sm font-medium text-gray-700 dark:text-gray-200">
                HTTPS (Let's Encrypt)
              </label>
              <span
                class="text-xs text-gray-500 dark:text-gray-400"
                title="Auto-configures Caddy + Cloudflare DNS for docling.lumainus.com"
              >
                ?
              </span>
            </div>
          </div>
        </.form>

        <%= if @offers != [] do %>
          <div class="border-t pt-4">
            <%= if has_active_instances?(@instances) do %>
              <div class="mb-4 p-3 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-700 rounded-lg">
                <p class="text-sm text-amber-800 dark:text-amber-200">
                  <span class="font-semibold">Provisioning blocked:</span>
                  You already have active instance(s). Destroy them before provisioning a new one.
                </p>
              </div>
            <% end %>
            <h3 class="text-lg font-medium mb-3 text-gray-900 dark:text-gray-100">
              Available Offers ({length(@offers)})
            </h3>
            <div class="overflow-x-auto">
              <table class="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                <thead class="bg-gray-50 dark:bg-gray-700">
                  <tr>
                    <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                      GPU
                    </th>
                    <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                      Location
                    </th>
                    <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                      $/hr
                    </th>
                    <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                      VRAM
                    </th>
                    <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                      RAM
                    </th>
                    <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                      CPU
                    </th>
                    <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                      Disk
                    </th>
                    <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                      Net
                    </th>
                    <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                      Rel.
                    </th>
                    <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                      Action
                    </th>
                  </tr>
                </thead>
                <tbody class="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                  <%= for offer <- @offers do %>
                    <tr>
                      <td class="px-3 py-2 text-sm text-gray-900 dark:text-gray-100">
                        {offer["gpu_name"]}
                      </td>
                      <td class="px-3 py-2 text-sm text-gray-900 dark:text-gray-100">
                        {offer["geolocation"]}
                      </td>
                      <td class="px-3 py-2 text-sm font-mono text-gray-900 dark:text-gray-100">
                        ${Float.round((offer["dph_total"] || 0) * 1.0, 3)}
                      </td>
                      <td class="px-3 py-2 text-sm text-gray-900 dark:text-gray-100">
                        {div(offer["gpu_ram"] || 0, 1024)} GB
                      </td>
                      <td class="px-3 py-2 text-sm text-gray-900 dark:text-gray-100">
                        {Float.round((offer["cpu_ram"] || 0) * 1.0, 0) |> trunc()} GB
                      </td>
                      <td class="px-3 py-2 text-sm text-gray-900 dark:text-gray-100">
                        {offer["cpu_cores"] || "?"}
                      </td>
                      <td class="px-3 py-2 text-sm text-gray-900 dark:text-gray-100">
                        {Float.round((offer["disk_space"] || 0) * 1.0, 0) |> trunc()} GB
                      </td>
                      <td class="px-3 py-2 text-sm text-gray-900 dark:text-gray-100">
                        {Float.round((offer["inet_down"] || 0) * 1.0, 0) |> trunc()} Mb/s
                      </td>
                      <td class="px-3 py-2 text-sm text-gray-900 dark:text-gray-100">
                        {Float.round((offer["reliability"] || 0) * 100, 0) |> trunc()}%
                      </td>
                      <td class="px-3 py-2">
                        <button
                          type="button"
                          phx-click="provision"
                          phx-value-offer_id={offer["id"]}
                          disabled={@provisioning || has_active_instances?(@instances)}
                          title={
                            if has_active_instances?(@instances),
                              do: "Destroy existing instances first",
                              else: ""
                          }
                          class="px-3 py-1 text-sm font-medium text-white bg-green-600 rounded hover:bg-green-700 disabled:opacity-50 disabled:cursor-not-allowed"
                        >
                          {cond do
                            @provisioning -> "..."
                            has_active_instances?(@instances) -> "Blocked"
                            true -> "Provision"
                          end}
                        </button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>
      </div>
      
    <!-- Provisioning Logs Panel -->
      <div class="bg-gray-900 rounded-lg p-4">
        <div class="flex items-center justify-between mb-3">
          <h3 class="text-sm font-semibold text-gray-100">Provisioning Logs</h3>
          <div class="flex gap-2">
            <button
              type="button"
              phx-click="test_cloudflare"
              class="px-3 py-1 text-xs font-medium text-cyan-400 bg-cyan-900/50 rounded hover:bg-cyan-900"
            >
              Test Cloudflare
            </button>
            <button
              type="button"
              phx-click="clear_logs"
              class="px-3 py-1 text-xs font-medium text-gray-400 bg-gray-800 rounded hover:bg-gray-700"
            >
              Clear
            </button>
          </div>
        </div>

        <div class="font-mono text-xs space-y-1 max-h-64 overflow-y-auto">
          <%= if @provision_logs == [] do %>
            <p class="text-gray-500 italic">No logs yet. Provision an instance to see activity.</p>
          <% else %>
            <%= for log <- Enum.reverse(@provision_logs) do %>
              <div class="flex gap-2">
                <span class="text-gray-500">{Calendar.strftime(log.timestamp, "%H:%M:%S")}</span>
                <span class={log_level_class(log.level)}>{log_level_icon(log.level)}</span>
                <span class="text-gray-300">{log.message}</span>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
