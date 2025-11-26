defmodule Lumainus.VastAI.RemoteDiagnostics do
  @moduledoc """
  Remote SSH diagnostics for Vast.ai GPU instances.

  Runs diagnostic commands over SSH to check service health, port status,
  and container state without manual SSH access.

  ## Usage

      # Run full diagnostics
      RemoteDiagnostics.run()

      # Run specific check
      RemoteDiagnostics.check_service_running()
      RemoteDiagnostics.check_health_endpoint()
      RemoteDiagnostics.check_ports()
  """

  require Logger

  alias Lumainus.VastAI
  alias Lumainus.VastAI.Instances
  alias Lumainus.Docling.VastAI.InstanceManager

  @ssh_timeout 15_000
  @connect_timeout 10

  @doc """
  Run full diagnostics on the active Vast.ai instance.
  Returns a map with all check results.
  """
  def run(opts \\ []) do
    with {:ok, instance_info} <- get_instance_info(opts) do
      Logger.info(
        "[RemoteDiagnostics] Running diagnostics on instance #{instance_info.instance_id}"
      )

      results = %{
        instance: instance_info,
        timestamp: DateTime.utc_now(),
        checks: %{}
      }

      # Run all checks
      checks = [
        {:service_running, &check_service_running/1},
        {:health_local, &check_health_local/1},
        {:ports_listening, &check_ports_listening/1},
        {:process_list, &check_process_list/1},
        {:disk_space, &check_disk_space/1},
        {:gpu_status, &check_gpu_status/1},
        {:logs_tail, &check_logs_tail/1}
      ]

      check_results =
        Enum.reduce(checks, %{}, fn {name, check_fn}, acc ->
          result = safe_run_check(check_fn, instance_info)
          Map.put(acc, name, result)
        end)

      results = %{results | checks: check_results}

      # Summarize
      summary = summarize_results(results)
      Map.put(results, :summary, summary)
    end
  end

  @doc """
  Check if uvicorn/docling service is running.
  """
  def check_service_running(opts_or_info \\ [])

  def check_service_running(opts) when is_list(opts) do
    with {:ok, info} <- get_instance_info(opts) do
      check_service_running(info)
    end
  end

  def check_service_running(%{} = info) do
    cmd = "ps aux | grep -E '(uvicorn|docling)' | grep -v grep"

    case ssh_exec(info, cmd) do
      {:ok, output} when byte_size(output) > 0 ->
        lines = String.split(output, "\n", trim: true)
        {:ok, %{running: true, processes: length(lines), output: output}}

      {:ok, ""} ->
        {:ok, %{running: false, processes: 0, output: ""}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check health endpoint locally on the instance.
  """
  def check_health_local(opts_or_info \\ [])

  def check_health_local(opts) when is_list(opts) do
    with {:ok, info} <- get_instance_info(opts) do
      check_health_local(info)
    end
  end

  def check_health_local(%{} = info) do
    port = info[:port] || 8044
    cmd = "curl -s --connect-timeout 5 http://localhost:#{port}/health"

    case ssh_exec(info, cmd) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, %{"status" => "ok"} = json} ->
            {:ok, %{healthy: true, response: json}}

          {:ok, json} ->
            {:ok, %{healthy: false, response: json}}

          {:error, _} ->
            {:ok, %{healthy: false, raw_response: output}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check what ports are listening.
  """
  def check_ports_listening(opts_or_info \\ [])

  def check_ports_listening(opts) when is_list(opts) do
    with {:ok, info} <- get_instance_info(opts) do
      check_ports_listening(info)
    end
  end

  def check_ports_listening(%{} = info) do
    # Try multiple commands since some containers have limited tools
    cmd = """
    (ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || cat /proc/net/tcp 2>/dev/null | head -20) 2>&1
    """

    case ssh_exec(info, cmd) do
      {:ok, output} ->
        port_8044 = String.contains?(output, "8044") || String.contains?(output, ":1F6C")
        {:ok, %{port_8044_listening: port_8044, output: output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get list of running processes.
  """
  def check_process_list(opts_or_info \\ [])

  def check_process_list(opts) when is_list(opts) do
    with {:ok, info} <- get_instance_info(opts) do
      check_process_list(info)
    end
  end

  def check_process_list(%{} = info) do
    cmd = "ps aux --sort=-%mem | head -15"

    case ssh_exec(info, cmd) do
      {:ok, output} ->
        {:ok, %{output: output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check disk space.
  """
  def check_disk_space(opts_or_info \\ [])

  def check_disk_space(opts) when is_list(opts) do
    with {:ok, info} <- get_instance_info(opts) do
      check_disk_space(info)
    end
  end

  def check_disk_space(%{} = info) do
    cmd = "df -h / /app 2>/dev/null | tail -n +2"

    case ssh_exec(info, cmd) do
      {:ok, output} ->
        {:ok, %{output: output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check GPU status via nvidia-smi.
  """
  def check_gpu_status(opts_or_info \\ [])

  def check_gpu_status(opts) when is_list(opts) do
    with {:ok, info} <- get_instance_info(opts) do
      check_gpu_status(info)
    end
  end

  def check_gpu_status(%{} = info) do
    cmd =
      "nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null || echo 'nvidia-smi not available'"

    case ssh_exec(info, cmd) do
      {:ok, output} ->
        if String.contains?(output, "not available") do
          {:ok, %{available: false, output: output}}
        else
          {:ok, %{available: true, output: output}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get tail of uvicorn logs.
  """
  def check_logs_tail(opts_or_info \\ [])

  def check_logs_tail(opts) when is_list(opts) do
    with {:ok, info} <- get_instance_info(opts) do
      check_logs_tail(info)
    end
  end

  def check_logs_tail(%{} = info) do
    cmd =
      "tail -20 /var/log/uvicorn.log 2>/dev/null || tail -20 /var/log/startup.log 2>/dev/null || echo 'No logs found'"

    case ssh_exec(info, cmd) do
      {:ok, output} ->
        {:ok, %{output: output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Start the docling service remotely.
  """
  def start_service(opts \\ []) do
    with {:ok, info} <- get_instance_info(opts) do
      Logger.info("[RemoteDiagnostics] Starting service on #{info.ip}...")

      port = info[:port] || 8044

      cmd = """
      cd /app/service && \
      export PORT=#{port} && \
      export HOST=0.0.0.0 && \
      export CUDA_VISIBLE_DEVICES=0 && \
      nohup /opt/conda/bin/python -m uvicorn app.main:app --host $HOST --port $PORT --no-access-log > /var/log/uvicorn.log 2>&1 &
      echo "Started uvicorn on port #{port}"
      sleep 3
      curl -s http://localhost:#{port}/health || echo "Health check failed"
      """

      case ssh_exec(info, cmd, timeout: 30_000) do
        {:ok, output} ->
          Logger.info("[RemoteDiagnostics] Start result: #{output}")
          {:ok, %{output: output, started: String.contains?(output, "ok")}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Stop the docling service remotely.
  """
  def stop_service(opts \\ []) do
    with {:ok, info} <- get_instance_info(opts) do
      cmd =
        "pkill -f 'uvicorn app.main:app' && echo 'Service stopped' || echo 'No service running'"

      case ssh_exec(info, cmd) do
        {:ok, output} ->
          {:ok, %{output: output}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Restart the docling service remotely.
  """
  def restart_service(opts \\ []) do
    with {:ok, _} <- stop_service(opts),
         :ok <- Process.sleep(2_000),
         {:ok, result} <- start_service(opts) do
      {:ok, result}
    end
  end

  # Private functions

  defp get_instance_info(opts) do
    cond do
      # Explicit instance info provided
      opts[:ip] && opts[:ssh_port] ->
        {:ok,
         %{
           ip: opts[:ip],
           ssh_port: opts[:ssh_port],
           instance_id: opts[:instance_id],
           port: opts[:port] || 8044
         }}

      # Get from InstanceManager
      true ->
        case get_active_instance() do
          {:ok, info} -> {:ok, info}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp get_active_instance do
    # First try to get from InstanceManager
    case InstanceManager.current_instance_id() do
      nil ->
        # Fall back to Vast.ai API
        get_instance_from_api()

      instance_id ->
        get_instance_details(instance_id)
    end
  end

  defp get_instance_from_api do
    case Instances.list() do
      {:ok, %{"instances" => instances}} when is_list(instances) ->
        running =
          Enum.find(instances, fn inst ->
            inst["actual_status"] in ["running", "loading"] ||
              inst["cur_state"] in ["running", "loading"]
          end)

        case running do
          nil -> {:error, :no_running_instance}
          inst -> build_instance_info(inst)
        end

      {:ok, %{"instances" => %{"id" => _} = inst}} ->
        build_instance_info(inst)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_instance_details(instance_id) do
    case VastAI.status(instance_id) do
      {:ok, inst} -> build_instance_info(inst)
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_instance_info(inst) do
    ip = inst["public_ipaddr"]
    ssh_port = inst["ssh_port"] || extract_ssh_port(inst["ports"])
    instance_id = inst["id"]

    if ip && ssh_port do
      {:ok,
       %{
         ip: ip,
         ssh_port: ssh_port,
         instance_id: instance_id,
         port: 8044,
         ssh_host: inst["ssh_host"] || "ssh#{inst["ssh_idx"]}.vast.ai",
         raw: inst
       }}
    else
      {:error, {:missing_connection_info, ip: ip, ssh_port: ssh_port}}
    end
  end

  defp extract_ssh_port(ports) when is_map(ports) do
    case ports["22/tcp"] do
      [%{"HostPort" => port} | _] -> String.to_integer(port)
      _ -> nil
    end
  end

  defp extract_ssh_port(_), do: nil

  defp ssh_exec(info, cmd, opts \\ []) do
    timeout = opts[:timeout] || @ssh_timeout
    ssh_host = info[:ssh_host] || "ssh#{div(info.ssh_port, 1000)}.vast.ai"
    ssh_port = info.ssh_port

    # Build SSH command
    ssh_args = [
      "-o",
      "StrictHostKeyChecking=no",
      "-o",
      "UserKnownHostsFile=/dev/null",
      "-o",
      "ConnectTimeout=#{@connect_timeout}",
      "-o",
      "BatchMode=yes",
      "-p",
      "#{ssh_port}",
      "root@#{ssh_host}",
      cmd
    ]

    Logger.debug("[RemoteDiagnostics] SSH: ssh #{Enum.join(ssh_args, " ")}")

    case System.cmd("ssh", ssh_args, stderr_to_stdout: true, timeout: timeout) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, exit_code} ->
        Logger.warning("[RemoteDiagnostics] SSH command failed (exit #{exit_code}): #{output}")
        {:error, {:ssh_failed, exit_code, output}}
    end
  rescue
    e ->
      Logger.error("[RemoteDiagnostics] SSH error: #{inspect(e)}")
      {:error, {:ssh_error, Exception.message(e)}}
  end

  defp safe_run_check(check_fn, info) do
    try do
      check_fn.(info)
    rescue
      e -> {:error, {:check_failed, Exception.message(e)}}
    catch
      :exit, reason -> {:error, {:check_exit, reason}}
    end
  end

  defp summarize_results(results) do
    checks = results.checks

    service_ok = match?({:ok, %{running: true}}, checks[:service_running])
    health_ok = match?({:ok, %{healthy: true}}, checks[:health_local])

    status =
      cond do
        service_ok && health_ok -> :healthy
        service_ok -> :degraded
        true -> :down
      end

    %{
      status: status,
      service_running: service_ok,
      health_ok: health_ok,
      instance_id: results.instance.instance_id,
      ip: results.instance.ip
    }
  end
end
