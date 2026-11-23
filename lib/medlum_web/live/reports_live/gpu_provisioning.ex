defmodule MedlumWeb.ReportsLive.GpuProvisioning do
  @moduledoc """
  GPU provisioning workflow for Vast.ai instances.

  This module handles the complete provisioning flow:
  1. Search for GPU offers matching requirements
  2. Create instance from best offer
  3. Wait for instance to boot
  4. Setup DNS and SSL (HTTPS) or fallback to HTTP
  5. Register instance with InstanceManager
  """

  require Logger

  alias Medlum.Cloudflare
  alias Medlum.Docling.Settings, as: DoclingSettings
  alias Medlum.Docling.VastAI.InstanceManager
  alias Medlum.Docling.VastAI.ProvisioningState
  alias Medlum.VastAI
  alias Medlum.VastAI.Instances, as: VastAIInstances
  alias Medlum.VastAI.Offers, as: VastAIOffers

  @doc """
  Main entry point for GPU auto-provisioning.

  Performs safety checks for existing instances before starting provisioning.
  Returns `{:ok, instance_id}` on success or `{:error, reason}` on failure.
  """
  def auto_provision_gpu do
    # SAFETY CHECK: Double-check for existing instances before starting
    # This is a second layer of protection in case the caller didn't check
    case InstanceManager.check_existing_instance() do
      {:ok, endpoint} when is_binary(endpoint) ->
        Logger.warning(
          "[auto_provision_gpu] Instance already exists at #{endpoint}, aborting provisioning"
        )

        {:error, :instance_already_exists}

      {:ok, :running, instance_id} ->
        Logger.warning(
          "[auto_provision_gpu] Found untracked instance #{instance_id}, aborting provisioning"
        )

        {:error, {:untracked_instance, instance_id}}

      {:ok, :none} ->
        # Safe to proceed
        do_auto_provision_gpu()

      {:error, reason} ->
        Logger.error(
          "[auto_provision_gpu] Failed to check existing instances: #{inspect(reason)}"
        )

        # Proceed with caution - let the provisioning try and fail if needed
        do_auto_provision_gpu()
    end
  end

  defp do_auto_provision_gpu do
    # Use shared ProvisioningState for real-time updates
    ProvisioningState.start_provisioning(true)
    ProvisioningState.add_log(:info, "=== GPU AUTO-PROVISIONING STARTED ===")
    ProvisioningState.add_log(:info, "Time: #{DateTime.utc_now() |> DateTime.to_string()}")

    # Check configuration upfront
    ProvisioningState.add_log(:info, "=== PRE-FLIGHT CONFIG CHECK ===")

    vast_api_key = System.get_env("VAST_API_KEY")
    cf_token = System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_API_TOKEN")
    cf_zone = System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_ZONE_ID")

    cf_fqdn =
      (System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_FQDN") || Cloudflare.cloud_fqdn())
      |> normalize_fqdn()

    ProvisioningState.add_log(
      :info,
      "Vast.ai API Key: #{if vast_api_key, do: "#{String.slice(vast_api_key, 0, 8)}...", else: "NOT SET!"}"
    )

    ProvisioningState.add_log(
      :info,
      "Cloudflare Token: #{if cf_token, do: "#{String.slice(cf_token, 0, 8)}...", else: "NOT SET!"}"
    )

    ProvisioningState.add_log(
      :info,
      "Cloudflare Zone: #{if cf_zone, do: "#{String.slice(cf_zone, 0, 8)}...", else: "NOT SET!"}"
    )

    ProvisioningState.add_log(:info, "Cloudflare FQDN: #{cf_fqdn || "NOT SET!"}")

    if is_nil(vast_api_key) do
      ProvisioningState.add_log(:error, "VAST_API_KEY not set - cannot continue!")
      ProvisioningState.fail(:missing_vast_api_key)
      {:error, :missing_vast_api_key}
    else
      if is_nil(cf_token) or is_nil(cf_zone) do
        ProvisioningState.add_log(:warning, "Cloudflare not configured - will fall back to HTTP")
      end

      # Search for best offers with good defaults
      ProvisioningState.add_log(:info, "=== PHASE 1: Search GPU Offers ===")
      ProvisioningState.update_status("Searching for GPU offers...")

      filters =
        VastAIOffers.build_filters(
          gpu_name: "RTX 3090",
          num_gpus: 1,
          verified: true,
          rentable: true,
          geolocation: ["US", "CA"],
          dph_total: {:lte, 0.30},
          cpu_ram: {:gte, 16},
          cpu_cores: {:gte, 4},
          inet_down: {:gte, 100},
          disk_space: {:gte, 16}
        )

      ProvisioningState.add_log(
        :info,
        "Filter criteria: RTX 3090, 1 GPU, US/CA, <$0.30/hr, 16GB+ RAM"
      )

      case VastAIOffers.search(filters: filters, limit: 3) do
        {:ok, %{"offers" => []}} ->
          ProvisioningState.add_log(:error, "No GPU offers found matching requirements")
          ProvisioningState.fail(:no_offers)
          {:error, :no_offers}

        {:ok, %{"offers" => offers}} ->
          ProvisioningState.add_log(:success, "Found #{length(offers)} offers")

          for offer <- offers do
            ProvisioningState.add_log(
              :info,
              "  - Offer ##{offer["id"]}: $#{Float.round((offer["dph_total"] || 0) * 1.0, 3)}/hr, #{offer["gpu_name"]}, #{offer["geolocation"]}"
            )
          end

          # Try top offers in order with full HTTPS provisioning
          try_provision_offers_with_https(offers)

        {:error, reason} ->
          ProvisioningState.add_log(:error, "Failed to search offers: #{inspect(reason)}")
          ProvisioningState.fail(reason)
          {:error, reason}
      end
    end
  end

  defp try_provision_offers_with_https([]) do
    ProvisioningState.add_log(:error, "All offers failed to provision")
    ProvisioningState.fail(:all_offers_failed)
    {:error, :all_offers_failed}
  end

  defp try_provision_offers_with_https([offer | rest]) do
    offer_id = offer["id"]
    remaining = length(rest)

    ProvisioningState.add_log(:info, "=== Trying offer ##{offer_id} (#{remaining} remaining) ===")

    ProvisioningState.add_log(
      :info,
      "  Price: $#{Float.round((offer["dph_total"] || 0) * 1.0, 3)}/hr"
    )

    ProvisioningState.add_log(
      :info,
      "  GPU: #{offer["gpu_name"]} (#{div(offer["gpu_ram"] || 0, 1024)}GB VRAM)"
    )

    ProvisioningState.add_log(:info, "  Location: #{offer["geolocation"]}")

    ProvisioningState.add_log(
      :info,
      "  Reliability: #{Float.round((offer["reliability"] || 0) * 100, 0)}%"
    )

    ProvisioningState.update_status("Creating instance from offer ##{offer_id}...")

    # Generate the Caddy onstart script that starts uvicorn and sets up HTTPS
    onstart = VastAI.caddy_onstart_script(Cloudflare.cloud_fqdn(), VastAI.cloud_port())

    ProvisioningState.add_log(
      :info,
      "Calling VastAI.provision(offer_id: #{offer_id}, disk_gb: 20, label: medlum-docling, onstart: <script>)"
    )

    case VastAI.provision(
           offer_id: offer_id,
           disk_gb: 20,
           label: "medlum-docling",
           onstart: onstart
         ) do
      {:ok, instance_id} ->
        ProvisioningState.add_log(:success, "=== PHASE 1 COMPLETE ===")

        ProvisioningState.add_log(
          :success,
          "Instance ##{instance_id} created from offer ##{offer_id}"
        )

        # Continue with full HTTPS setup
        finish_https_provisioning(instance_id)

      {:error, reason} ->
        ProvisioningState.add_log(:error, "Offer ##{offer_id} failed: #{inspect(reason)}")

        if rest != [] do
          ProvisioningState.add_log(:info, "Trying next offer (#{remaining} remaining)...")
          try_provision_offers_with_https(rest)
        else
          ProvisioningState.add_log(
            :error,
            "All #{length([offer | rest])} offers exhausted - provisioning failed"
          )

          ProvisioningState.fail(reason)
          {:error, reason}
        end
    end
  end

  defp finish_https_provisioning(instance_id) do
    ProvisioningState.add_log(:info, "=== PHASE 2: Wait for instance boot ===")
    ProvisioningState.add_log(:info, "Instance ID: #{instance_id}")
    ProvisioningState.add_log(:info, "Timeout: 5 minutes (300 seconds)")
    ProvisioningState.update_status("Instance ##{instance_id} created, waiting for boot...")

    # Use granular wait with status updates
    case wait_for_ready_with_logging(instance_id, 300_000) do
      {:ok, instance} ->
        ProvisioningState.add_log(:success, "=== PHASE 2 COMPLETE: Instance is running! ===")

        # Log all instance details
        ProvisioningState.add_log(:info, "Instance details:")
        ProvisioningState.add_log(:info, "  - actual_status: #{instance["actual_status"]}")

        ProvisioningState.add_log(
          :info,
          "  - public_ipaddr: #{instance["public_ipaddr"] || "NONE"}"
        )

        ProvisioningState.add_log(:info, "  - ssh_host: #{instance["ssh_host"] || "NONE"}")
        ProvisioningState.add_log(:info, "  - ssh_port: #{instance["ssh_port"] || "NONE"}")
        ProvisioningState.add_log(:info, "  - gpu_name: #{instance["gpu_name"] || "?"}")
        ProvisioningState.add_log(:info, "  - label: #{instance["label"] || "?"}")

        ProvisioningState.add_log(:info, "=== PHASE 3: Setup DNS ===")
        ProvisioningState.update_status("Instance running, setting up DNS...")

        case instance["public_ipaddr"] do
          ip when is_binary(ip) and ip != "" ->
            ProvisioningState.add_log(:info, "Public IP obtained: #{ip}")
            setup_dns_and_ssl(instance_id, ip, instance)

          nil ->
            ProvisioningState.add_log(:error, "public_ipaddr is nil!")

            ProvisioningState.add_log(
              :error,
              "Full instance data: #{inspect(instance, limit: 1000)}"
            )

            ProvisioningState.fail(:no_public_ip)
            {:error, :no_public_ip}

          "" ->
            ProvisioningState.add_log(:error, "public_ipaddr is empty string!")
            ProvisioningState.fail(:no_public_ip)
            {:error, :no_public_ip}

          other ->
            ProvisioningState.add_log(:error, "Unexpected public_ipaddr value: #{inspect(other)}")
            ProvisioningState.fail(:no_public_ip)
            {:error, :no_public_ip}
        end

      {:error, :timeout} ->
        ProvisioningState.add_log(:error, "=== PHASE 2 FAILED: Timeout ===")

        ProvisioningState.add_log(
          :error,
          "Instance did not reach 'running' state within 5 minutes"
        )

        ProvisioningState.add_log(:info, "Tip: Check Vast.ai console for instance status")
        ProvisioningState.fail(:timeout)
        {:error, :timeout}

      {:error, :exited} ->
        ProvisioningState.add_log(:error, "=== PHASE 2 FAILED: Instance exited ===")
        ProvisioningState.add_log(:error, "Instance crashed or was terminated")
        ProvisioningState.fail(:exited)
        {:error, :exited}

      {:error, reason} ->
        ProvisioningState.add_log(:error, "=== PHASE 2 FAILED: #{inspect(reason)} ===")
        ProvisioningState.fail(reason)
        {:error, reason}
    end
  end

  defp setup_dns_and_ssl(instance_id, ip, instance) do
    ProvisioningState.add_log(:info, "Checking Cloudflare configuration...")

    # Log Cloudflare config
    fqdn =
      (System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_FQDN") || Cloudflare.cloud_fqdn())
      |> normalize_fqdn()

    zone_id = System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_ZONE_ID")
    token = System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_API_TOKEN")

    missing_cloudflare? =
      is_nil(fqdn) or zone_id in [nil, ""] or token in [nil, ""]

    ProvisioningState.add_log(:info, "  - Target FQDN: #{fqdn || "NOT SET"}")

    ProvisioningState.add_log(
      :info,
      "  - Zone ID: #{if zone_id, do: "#{String.slice(zone_id, 0, 8)}...", else: "NOT SET"}"
    )

    ProvisioningState.add_log(
      :info,
      "  - API Token: #{if token, do: "#{String.slice(token, 0, 8)}...", else: "NOT SET"}"
    )

    if missing_cloudflare? do
      ProvisioningState.add_log(:error, "Cloudflare not fully configured!")
      fallback_to_http(instance_id, ip)
    else
      ProvisioningState.add_log(:info, "Calling Cloudflare.update_dns_record(#{ip})...")
      ProvisioningState.update_status("Updating Cloudflare DNS: #{fqdn} -> #{ip}")

      case Cloudflare.update_dns_record(ip) do
        {:ok, dns_result} ->
          ProvisioningState.add_log(:success, "=== PHASE 3 COMPLETE: DNS updated ===")
          ProvisioningState.add_log(:info, "DNS Result: #{inspect(dns_result)}")

          endpoint = "https://#{dns_result.fqdn}"
          ProvisioningState.add_log(:info, "=== PHASE 4: SSL/HTTPS Setup ===")
          ProvisioningState.add_log(:info, "HTTPS endpoint: #{endpoint}")

          ProvisioningState.add_log(
            :info,
            "Caddy will obtain Let's Encrypt cert on first request"
          )

          # Wait for the service to be ready (Docker pull + service start)
          ProvisioningState.add_log(:info, "=== PHASE 4: Wait for service ready ===")
          ProvisioningState.add_log(:info, "Waiting for Docker image pull and service start...")

          http_url = "http://#{ip}:#{VastAI.cloud_port()}/health"

          case wait_for_service_health(http_url, 300_000) do
            :ok ->
              ProvisioningState.add_log(:success, "Service is responding!")

              # Now test HTTPS via Caddy
              ProvisioningState.add_log(:info, "Testing HTTPS endpoint...")
              https_url = "#{endpoint}/health"
              test_endpoint(https_url, "HTTPS via Caddy")

            {:error, :timeout} ->
              ProvisioningState.add_log(
                :warning,
                "Service not responding yet - may still be starting"
              )

              ProvisioningState.add_log(
                :info,
                "Continuing anyway - health checks will retry on /reports"
              )
          end

          # Save the cloud URL
          ProvisioningState.add_log(:info, "Saving cloud URL to settings: #{endpoint}")

          case DoclingSettings.update_cloud_url(endpoint) do
            {:ok, _} ->
              ProvisioningState.add_log(:success, "Cloud URL saved!")

            {:error, err} ->
              ProvisioningState.add_log(:warning, "Failed to save URL: #{inspect(err)}")
          end

          # CRITICAL: Update InstanceManager so it knows about this instance
          # This prevents duplicate provisioning when cloud backend is used
          ProvisioningState.add_log(:info, "Registering instance with InstanceManager...")
          InstanceManager.set_endpoint(instance_id, endpoint, ip)
          ProvisioningState.add_log(:success, "Instance registered with InstanceManager")

          ProvisioningState.add_log(:success, "=== PROVISIONING COMPLETE ===")
          ProvisioningState.add_log(:info, "Instance: ##{instance_id}")
          ProvisioningState.add_log(:info, "Endpoint: #{endpoint}")

          ProvisioningState.add_log(
            :info,
            "SSH: ssh -p #{instance["ssh_port"]} root@#{instance["ssh_host"]}"
          )

          ProvisioningState.complete(instance_id, endpoint)
          {:ok, instance_id}

        {:error, dns_error} ->
          ProvisioningState.add_log(:error, "=== PHASE 3 FAILED: DNS update error ===")
          ProvisioningState.add_log(:error, "Error: #{inspect(dns_error)}")
          fallback_to_http(instance_id, ip)
      end
    end
  end

  defp fallback_to_http(instance_id, ip) do
    endpoint = "http://#{ip}:#{VastAI.cloud_port()}"
    ProvisioningState.add_log(:warning, "Falling back to HTTP (no SSL)")
    ProvisioningState.add_log(:info, "HTTP endpoint: #{endpoint}")

    # Test HTTP endpoint
    test_endpoint("#{endpoint}/health", "HTTP direct")

    DoclingSettings.update_cloud_url(endpoint)

    # CRITICAL: Update InstanceManager so it knows about this instance
    # This prevents duplicate provisioning when cloud backend is used
    ProvisioningState.add_log(:info, "Registering instance with InstanceManager...")
    InstanceManager.set_endpoint(instance_id, endpoint, ip)
    ProvisioningState.add_log(:success, "Instance registered with InstanceManager")

    ProvisioningState.complete(instance_id, endpoint)
    {:ok, instance_id}
  end

  defp test_endpoint(url, label) do
    ProvisioningState.add_log(:info, "  Testing #{label}: #{url}")

    case Req.get(url, receive_timeout: 15_000, retry: false) do
      {:ok, %{status: status, body: body}} ->
        ProvisioningState.add_log(:success, "  #{label}: HTTP #{status}")

        if is_map(body) do
          ProvisioningState.add_log(:info, "  Response: #{inspect(body, limit: 200)}")
        end

      {:error, %{reason: reason}} ->
        ProvisioningState.add_log(:warning, "  #{label}: Failed - #{inspect(reason)}")

      {:error, reason} ->
        ProvisioningState.add_log(:warning, "  #{label}: Failed - #{inspect(reason)}")
    end
  end

  # Wait for service health endpoint to respond (handles Docker pull time)
  defp wait_for_service_health(url, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    # 10 seconds between checks
    poll_interval = 10_000

    do_health_wait_loop(url, deadline, poll_interval, 0)
  end

  defp do_health_wait_loop(url, deadline, poll_interval, attempt) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      if rem(attempt, 3) == 0 do
        ProvisioningState.add_log(:info, "Health check attempt #{attempt + 1}...")
      end

      case Req.get(url, receive_timeout: 10_000, retry: false) do
        {:ok, %{status: status}} when status in 200..299 ->
          ProvisioningState.add_log(:success, "Health check passed on attempt #{attempt + 1}")
          :ok

        {:ok, %{status: status}} ->
          ProvisioningState.add_log(:info, "Health check returned #{status}, retrying...")
          Process.sleep(poll_interval)
          do_health_wait_loop(url, deadline, poll_interval, attempt + 1)

        {:error, _reason} ->
          # Service not ready yet - this is expected during Docker pull
          Process.sleep(poll_interval)
          do_health_wait_loop(url, deadline, poll_interval, attempt + 1)
      end
    end
  end

  # Wait for instance with detailed logging
  defp wait_for_ready_with_logging(instance_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    # 10 seconds between polls
    poll_interval = 10_000
    last_status = nil

    do_wait_loop(instance_id, deadline, poll_interval, last_status, 0)
  end

  defp do_wait_loop(instance_id, deadline, poll_interval, last_status, poll_count) do
    if System.monotonic_time(:millisecond) >= deadline do
      ProvisioningState.add_log(:error, "Timeout waiting for instance after #{poll_count} polls")
      {:error, :timeout}
    else
      result = VastAIInstances.get(instance_id)

      # Log raw response on first poll for debugging
      if poll_count == 0 do
        ProvisioningState.add_log(:info, "Raw API response: #{inspect(result, limit: 500)}")
      end

      case result do
        {:ok, response} when is_map(response) ->
          # Extract instance data - API returns %{"instances" => %{data}} (map, not list!)
          instance_data =
            case response do
              # Map with id key
              %{"instances" => %{"id" => _} = inst} ->
                inst

              # List format
              %{"instances" => [inst | _]} ->
                inst

              # Single instance
              %{"instance" => inst} ->
                inst

              # Direct instance data
              %{"id" => _} = inst ->
                inst

              _ ->
                ProvisioningState.add_log(
                  :warning,
                  "Could not extract instance data from: #{inspect(response, limit: 300)}"
                )

                nil
            end

          if is_nil(instance_data) do
            Process.sleep(poll_interval)
            do_wait_loop(instance_id, deadline, poll_interval, last_status, poll_count + 1)
          else
            # Check BOTH actual_status AND cur_state - API uses both inconsistently
            actual_status = instance_data["actual_status"]
            cur_state = instance_data["cur_state"]
            # Use cur_state as fallback
            status = actual_status || cur_state
            status_msg = instance_data["status_msg"]
            ssh_host = instance_data["ssh_host"]
            public_ip = instance_data["public_ipaddr"]
            intended_status = instance_data["intended_status"]
            label = instance_data["label"]

            # Log status changes
            status_key = {actual_status, cur_state, status_msg}

            if status_key != last_status do
              ProvisioningState.add_log(
                :info,
                "Poll ##{poll_count}: actual=#{actual_status || "nil"} | cur=#{cur_state || "nil"} | intended=#{intended_status || "?"}"
              )

              if label, do: ProvisioningState.add_log(:info, "Label: #{label}")

              if status_msg && status_msg != "",
                do: ProvisioningState.add_log(:info, "Msg: #{status_msg}")

              if ssh_host,
                do:
                  ProvisioningState.add_log(
                    :info,
                    "SSH: #{ssh_host}:#{instance_data["ssh_port"]}"
                  )

              if public_ip && public_ip != "",
                do: ProvisioningState.add_log(:info, "IP: #{public_ip}")
            end

            ProvisioningState.update_status(
              "Instance ##{instance_id}: #{status || "pending"}... (#{poll_count * 10}s)"
            )

            # Check if running - use EITHER actual_status OR cur_state
            cond do
              actual_status == "running" or cur_state == "running" ->
                ProvisioningState.add_log(
                  :success,
                  "Instance is running! (actual=#{actual_status}, cur=#{cur_state})"
                )

                {:ok, instance_data}

              actual_status == "exited" or cur_state == "exited" ->
                ProvisioningState.add_log(:error, "Instance exited unexpectedly")
                ProvisioningState.add_log(:error, "Status msg: #{status_msg}")
                {:error, :exited}

              true ->
                Process.sleep(poll_interval)
                do_wait_loop(instance_id, deadline, poll_interval, status_key, poll_count + 1)
            end
          end

        {:ok, other} ->
          ProvisioningState.add_log(
            :warning,
            "Unexpected response type: #{inspect(other, limit: 200)}"
          )

          Process.sleep(poll_interval)
          do_wait_loop(instance_id, deadline, poll_interval, last_status, poll_count + 1)

        {:error, reason} = error ->
          ProvisioningState.add_log(:error, "API error: #{inspect(reason)}")
          error
      end
    end
  end

  defp normalize_fqdn(fqdn) do
    case fqdn do
      nil ->
        nil

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end
    end
  end
end
