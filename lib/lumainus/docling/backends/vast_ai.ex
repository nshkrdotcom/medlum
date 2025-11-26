defmodule Lumainus.Docling.Backends.VastAI do
  @moduledoc """
  Vast.ai GPU backend with automatic instance provisioning.

  Provisions RTX 3090 instances on-demand via Vast.ai API.
  Instances are kept alive while jobs are running, then destroyed after idle timeout.

  ## Configuration

      config :lumainus, :docling,
        backend: :vast_ai,
        vast_ai: [
          api_key: "...",
          gpu_name: "RTX_3090",
          min_disk_gb: 20,
          idle_timeout_minutes: 15
        ]

  Requires: VAST_API_KEY environment variable (or config)
  """

  @behaviour Lumainus.Docling.Backend
  require Logger

  alias Lumainus.Docling.HTTP
  alias Lumainus.Docling.VastAI.InstanceManager
  alias Lumainus.Docling.VastAI.ActivityTracker
  alias Lumainus.Cloudflare
  alias Lumainus.VastAI
  alias Lumainus.GPU

  @default_timeout 1_200_000
  # Shorter health timeout for faster UI feedback when service is down
  @default_health_timeout_ms 2_000

  @impl true
  def convert(binary, opts) when is_binary(binary) do
    with {:ok, endpoint} <- InstanceManager.ensure_instance() do
      record_activity()
      HTTP.convert(binary, opts, base_url: endpoint)
    end
  end

  @impl true
  def enqueue(binary, opts) when is_binary(binary) do
    with {:ok, endpoint} <- InstanceManager.ensure_instance(),
         {:ok, response} <- HTTP.enqueue(binary, opts, base_url: endpoint) do
      record_activity()
      {:ok, build_job(response, opts, endpoint)}
    end
  end

  @impl true
  def await(job, opts \\ []) do
    endpoint = job.metadata.endpoint
    result = HTTP.await(job, opts, base_url: endpoint)

    # Update activity after job completes
    record_activity()

    result
  end

  # Record activity in both trackers
  defp record_activity do
    InstanceManager.update_activity()
    ActivityTracker.record_activity()
  end

  @impl true
  def health do
    case InstanceManager.get_endpoint() do
      {:ok, endpoint} ->
        case HTTP.health([base_url: endpoint], health_req_opts()) do
          {:ok, _} = ok ->
            ok

          {:error, reason} ->
            Logger.warning(
              "[Docling.VastAI] Primary endpoint #{endpoint} unreachable: #{inspect(reason)}. Attempting direct IP fallback..."
            )

            case fallback_health_via_ip(reason) do
              {:ok, _} = ok ->
                ok

              {:error, fallback_reason} = error ->
                Logger.warning(
                  "[Docling.VastAI] Fallback health failed: #{inspect(fallback_reason)}"
                )

                error
            end
        end

      {:error, :no_instance} ->
        {:ok, %{"status" => "no_instance", "message" => "No active Vast.ai instance"}}
    end
  end

  @impl true
  def cancel(job_id) when is_binary(job_id) do
    case InstanceManager.get_endpoint() do
      {:ok, endpoint} ->
        HTTP.cancel(job_id, base_url: endpoint)

      {:error, :no_instance} ->
        {:error, :no_instance}
    end
  end

  @impl true
  def capabilities, do: [:sync, :async, :sse, :cancel, :auto_provision, :gpu]

  # Private functions

  defp build_job(response, opts, endpoint) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout)

    %{
      job_id: response["job_id"],
      timeout_ms: timeout_ms,
      timeout_at:
        DateTime.utc_now()
        |> DateTime.add(timeout_ms, :millisecond)
        |> DateTime.truncate(:second),
      backend: __MODULE__,
      metadata: %{
        endpoint: endpoint,
        instance_id: InstanceManager.current_instance_id()
      }
    }
  end

  # Try direct IP health when HTTPS/Cloudflare is unreachable
  defp fallback_health_via_ip(primary_reason) do
    with {:ok, instance_id} <- current_instance_id_for_fallback(),
         {:ok, ip, ip_attempts} <- ip_for_fallback(instance_id),
         {:ok, resp, endpoint, attempts} <- try_health_endpoints(ip) do
      Logger.info(
        "[Docling.VastAI] Fallback health succeeded via #{endpoint}/health; updating endpoint"
      )

      Logger.info("[Docling.VastAI] Fallback resolved IP #{ip} (sources=#{inspect(ip_attempts)})")

      InstanceManager.set_endpoint(instance_id, endpoint, ip)

      GPU.log(:lifecycle, :vast_ai_health_fallback, "Vast.ai health fallback via direct IP",
        instance_id: instance_id,
        endpoint: endpoint,
        ip: ip,
        primary_reason: inspect(primary_reason),
        ip_attempts: ip_attempts,
        attempts: attempts,
        source: "docling_vast_ai_backend"
      )

      {:ok, Map.put(resp, "fallback", true)}
    else
      {:error, reason} ->
        detail =
          format_fallback_error(reason, primary_reason, Keyword.get(binding(), :ip_attempts))

        Logger.warning("[Docling.VastAI] Fallback health attempts exhausted: #{inspect(detail)}")
        {:error, {:fallback_failed, detail}}
    end
  end

  defp current_instance_id_for_fallback do
    case InstanceManager.current_instance_id() do
      nil -> {:error, :no_instance}
      id -> {:ok, id}
    end
  end

  defp ip_for_fallback(instance_id) do
    case ip_from_vast_status(instance_id) do
      {:ok, ip, status_val} ->
        {:ok, ip, [%{source: :vast_status, value: ip, status: status_val}]}

      {:error, status_reason} ->
        case ip_from_endpoint() do
          {:ok, ip, endpoint} ->
            {:ok, ip,
             [
               %{source: :vast_status, error: status_reason},
               %{source: :endpoint, value: ip, endpoint: endpoint}
             ]}

          {:error, endpoint_reason} ->
            case ip_from_dns() do
              {:ok, ip, domain} ->
                {:ok, ip,
                 [
                   %{source: :vast_status, error: status_reason},
                   %{source: :endpoint, error: endpoint_reason},
                   %{source: :dns, value: ip, domain: domain}
                 ]}

              {:error, dns_reason} ->
                {:error,
                 {:no_ip_available,
                  [
                    %{source: :vast_status, error: status_reason},
                    %{source: :endpoint, error: endpoint_reason},
                    %{source: :dns, error: dns_reason}
                  ]}}
            end
        end
    end
  end

  defp ip_from_vast_status(instance_id) do
    case VastAI.status(instance_id) do
      {:ok, %{"public_ipaddr" => ip} = status} when is_binary(ip) ->
        status_val = status_value(status)

        if valid_ip?(ip) do
          {:ok, ip, status_val}
        else
          {:error, {:invalid_ip_in_status, ip, status_val}}
        end

      {:ok, status} ->
        {:error, {:status_missing_ip, status_value(status)}}

      {:error, reason} ->
        {:error, {:status_error, reason}}
    end
  end

  defp ip_from_endpoint do
    case InstanceManager.get_endpoint() do
      {:ok, endpoint} ->
        case Regex.run(~r/(\d{1,3}(?:\.\d{1,3}){3})/, endpoint) do
          [_, ip] ->
            if valid_ip?(ip) do
              {:ok, ip, endpoint}
            else
              {:error, {:invalid_ip_in_endpoint, ip, endpoint}}
            end

          _ ->
            {:error, {:no_ip_in_endpoint, endpoint}}
        end

      {:error, reason} ->
        {:error, {:no_endpoint, reason}}
    end
  end

  defp ip_from_dns do
    domain =
      case Cloudflare.cloud_fqdn() do
        fqdn when is_binary(fqdn) and fqdn != "" -> fqdn
        _ -> "docling.lumainus.com"
      end

    case resolve_domain_ip(domain) do
      {:ok, ip} -> {:ok, ip, domain}
      {:error, reason} -> {:error, {:dns_lookup_failed, domain, reason}}
    end
  end

  defp resolve_domain_ip(domain) do
    case :inet.getaddr(String.to_charlist(domain), :inet) do
      {:ok, {a, b, c, d}} -> {:ok, Enum.join([a, b, c, d], ".")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp try_health_endpoints(ip) do
    allow_insecure = allow_insecure_ip_https?()
    attempts = health_attempts(ip, allow_insecure)

    # Run all health attempts concurrently to minimize total wait time
    timeout = health_timeout_ms()

    # Pair each attempt with its task, capturing the attempt in the tuple
    tasks_with_attempts =
      Enum.map(attempts, fn attempt ->
        task = Task.async(fn -> perform_health_attempt(attempt) end)
        {attempt, task}
      end)

    # Wait for all tasks with overall timeout, collect results
    results =
      tasks_with_attempts
      |> Enum.map(fn {attempt, task} ->
        case Task.yield(task, timeout + 500) || Task.shutdown(task, :brutal_kill) do
          {:ok, {result, record}} ->
            {attempt, result, record}

          nil ->
            # Task didn't complete in time - build timeout record
            attempt_record = %{
              url: "#{attempt.base_url}/health",
              scheme: attempt.scheme,
              insecure?: attempt.insecure?,
              result: {:error, :task_timeout}
            }

            {attempt, {:error, :task_timeout}, attempt_record}
        end
      end)

    # Find first success or collect all failures
    case Enum.find(results, fn {_attempt, result, _record} -> match?({:ok, _}, result) end) do
      {attempt, {:ok, resp}, _record} ->
        attempt_records = Enum.map(results, fn {_, _, record} -> record end)
        {:ok, resp, attempt.base_url, attempt_records}

      nil ->
        attempt_records = Enum.map(results, fn {_, _, record} -> record end)
        {:error, {:all_failed, attempt_records}}
    end
  end

  defp health_attempts(ip, allow_insecure_https?) do
    port = VastAI.cloud_port()
    http_base = "http://#{ip}:#{port}"
    https_base = "https://#{ip}:#{port}"

    # Build base connect options with short timeout for health checks
    timeout = health_timeout_ms()
    base_connect_opts = [timeout: timeout]

    attempts = [
      %{
        scheme: "http",
        base_url: http_base,
        insecure?: false,
        connect_options: base_connect_opts
      },
      %{
        scheme: "https",
        base_url: https_base,
        insecure?: false,
        connect_options: base_connect_opts
      }
    ]

    if allow_insecure_https? do
      # Merge transport_opts for insecure HTTPS (skip cert verification)
      insecure_connect_opts =
        Keyword.merge(base_connect_opts, transport_opts: [verify: :verify_none])

      attempts ++
        [
          %{
            scheme: "https",
            base_url: https_base,
            insecure?: true,
            connect_options: insecure_connect_opts
          }
        ]
    else
      attempts
    end
  end

  defp perform_health_attempt(%{base_url: base_url, scheme: scheme} = attempt) do
    insecure? = Map.get(attempt, :insecure?, false)
    connect_options = Map.get(attempt, :connect_options, [])
    timeout = health_timeout_ms()
    url = "#{base_url}/health"

    # Build opts with properly merged connect_options (no duplicates)
    opts = [receive_timeout: timeout, connect_options: connect_options]

    Logger.warning(
      "[Docling.VastAI] Fallback health attempt #{url} (scheme=#{scheme}, insecure=#{insecure?})"
    )

    result = HTTP.health([base_url: base_url], opts)

    attempt_record = %{
      url: url,
      scheme: scheme,
      insecure?: insecure?,
      result: attempt_result(result)
    }

    case result do
      {:ok, _} ->
        Logger.info("[Docling.VastAI] Fallback health succeeded via #{url}")
        {result, attempt_record}

      {:error, error} ->
        Logger.warning("[Docling.VastAI] Fallback health failed via #{url}: #{inspect(error)}")
        {result, attempt_record}
    end
  end

  defp health_req_opts do
    timeout = health_timeout_ms()
    [receive_timeout: timeout, connect_options: [timeout: timeout]]
  end

  defp health_timeout_ms do
    Application.get_env(:lumainus, :docling, [])
    |> Keyword.get(:health_timeout_ms, @default_health_timeout_ms)
  end

  defp attempt_result({:ok, _}), do: :ok
  defp attempt_result({:error, reason}), do: {:error, reason}

  defp allow_insecure_ip_https? do
    Application.get_env(:lumainus, :docling, [])
    |> Keyword.get(:allow_insecure_ip_https, true)
  end

  defp valid_ip?(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp valid_ip?(_), do: false

  defp status_value(status) do
    status["actual_status"] || status["cur_state"] || status["status"]
  end

  defp format_fallback_error({:no_ip_available, ip_attempts}, primary_reason, _scoped_ip_attempts) do
    %{primary_reason: primary_reason, ip_attempts: ip_attempts}
  end

  defp format_fallback_error({:all_failed, attempts}, primary_reason, scoped_ip_attempts) do
    %{primary_reason: primary_reason, attempts: attempts}
    |> maybe_add_ip_attempts(scoped_ip_attempts)
  end

  defp format_fallback_error(reason, primary_reason, scoped_ip_attempts) do
    %{primary_reason: primary_reason, reason: reason}
    |> maybe_add_ip_attempts(scoped_ip_attempts)
  end

  defp maybe_add_ip_attempts(map, ip_attempts) when is_list(ip_attempts),
    do: Map.put(map, :ip_attempts, ip_attempts)

  defp maybe_add_ip_attempts(map, _), do: map
end
