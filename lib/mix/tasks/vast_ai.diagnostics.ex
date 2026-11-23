defmodule Mix.Tasks.VastAi.Diagnostics do
  @moduledoc """
  Run remote diagnostics on the active Vast.ai GPU instance.

  ## Usage

      # Run full diagnostics
      mix vast_ai.diagnostics

      # Run specific check
      mix vast_ai.diagnostics --check service
      mix vast_ai.diagnostics --check health
      mix vast_ai.diagnostics --check ports
      mix vast_ai.diagnostics --check gpu
      mix vast_ai.diagnostics --check logs

      # Start/stop/restart service
      mix vast_ai.diagnostics --start
      mix vast_ai.diagnostics --stop
      mix vast_ai.diagnostics --restart

      # Specify instance manually
      mix vast_ai.diagnostics --ip 172.97.229.207 --ssh-port 11704

  ## Options

      --check NAME    Run specific check (service, health, ports, processes, disk, gpu, logs)
      --start         Start the docling service
      --stop          Stop the docling service
      --restart       Restart the docling service
      --ip IP         Instance IP address
      --ssh-port PORT SSH port
      --port PORT     Service port (default: 8044)
      --verbose       Show detailed output
      --json          Output as JSON
  """

  use Mix.Task

  alias Medlum.VastAI.RemoteDiagnostics

  @shortdoc "Run remote diagnostics on Vast.ai GPU instance"

  @switches [
    check: :string,
    start: :boolean,
    stop: :boolean,
    restart: :boolean,
    ip: :string,
    ssh_port: :integer,
    port: :integer,
    verbose: :boolean,
    json: :boolean
  ]

  @impl true
  def run(args) do
    # Start the application
    Mix.Task.run("app.start", [])

    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    instance_opts = build_instance_opts(opts)
    verbose = opts[:verbose] || false
    json_output = opts[:json] || false

    result =
      cond do
        opts[:start] ->
          IO.puts("Starting service...")
          RemoteDiagnostics.start_service(instance_opts)

        opts[:stop] ->
          IO.puts("Stopping service...")
          RemoteDiagnostics.stop_service(instance_opts)

        opts[:restart] ->
          IO.puts("Restarting service...")
          RemoteDiagnostics.restart_service(instance_opts)

        opts[:check] ->
          run_specific_check(opts[:check], instance_opts)

        true ->
          IO.puts("Running full diagnostics...\n")
          RemoteDiagnostics.run(instance_opts)
      end

    if json_output do
      output_json(result)
    else
      output_human(result, verbose)
    end
  end

  defp build_instance_opts(opts) do
    base = []
    base = if opts[:ip], do: [{:ip, opts[:ip]} | base], else: base
    base = if opts[:ssh_port], do: [{:ssh_port, opts[:ssh_port]} | base], else: base
    base = if opts[:port], do: [{:port, opts[:port]} | base], else: base
    base
  end

  defp run_specific_check(check_name, opts) do
    case check_name do
      "service" ->
        RemoteDiagnostics.check_service_running(opts)

      "health" ->
        RemoteDiagnostics.check_health_local(opts)

      "ports" ->
        RemoteDiagnostics.check_ports_listening(opts)

      "processes" ->
        RemoteDiagnostics.check_process_list(opts)

      "disk" ->
        RemoteDiagnostics.check_disk_space(opts)

      "gpu" ->
        RemoteDiagnostics.check_gpu_status(opts)

      "logs" ->
        RemoteDiagnostics.check_logs_tail(opts)

      _ ->
        IO.puts("Unknown check: #{check_name}")
        IO.puts("Available: service, health, ports, processes, disk, gpu, logs")
        {:error, :unknown_check}
    end
  end

  defp output_json(result) do
    case Jason.encode(result, pretty: true) do
      {:ok, json} -> IO.puts(json)
      {:error, _} -> IO.puts(inspect(result, pretty: true))
    end
  end

  defp output_human({:error, reason}, _verbose) do
    IO.puts("\n#{IO.ANSI.red()}ERROR:#{IO.ANSI.reset()} #{inspect(reason)}")
  end

  defp output_human({:ok, result}, _verbose) when is_map(result) do
    # Single check result
    if result[:output] do
      IO.puts(result.output)
    else
      IO.puts(inspect(result, pretty: true))
    end
  end

  defp output_human(%{summary: summary, checks: checks, instance: instance} = result, verbose) do
    # Full diagnostics result
    IO.puts("=" |> String.duplicate(60))
    IO.puts("VAST.AI REMOTE DIAGNOSTICS")
    IO.puts("=" |> String.duplicate(60))

    IO.puts("\nInstance: ##{instance.instance_id}")
    IO.puts("IP: #{instance.ip}")
    IO.puts("SSH Port: #{instance.ssh_port}")
    IO.puts("Timestamp: #{result.timestamp}")

    IO.puts("\n" <> String.duplicate("-", 60))
    IO.puts("SUMMARY")
    IO.puts(String.duplicate("-", 60))

    status_color =
      case summary.status do
        :healthy -> IO.ANSI.green()
        :degraded -> IO.ANSI.yellow()
        :down -> IO.ANSI.red()
      end

    IO.puts(
      "Status: #{status_color}#{summary.status |> to_string() |> String.upcase()}#{IO.ANSI.reset()}"
    )

    IO.puts("Service Running: #{bool_emoji(summary.service_running)}")
    IO.puts("Health Check: #{bool_emoji(summary.health_ok)}")

    IO.puts("\n" <> String.duplicate("-", 60))
    IO.puts("CHECKS")
    IO.puts(String.duplicate("-", 60))

    Enum.each(checks, fn {name, result} ->
      print_check(name, result, verbose)
    end)

    IO.puts("\n" <> String.duplicate("=", 60))
  end

  defp print_check(name, {:ok, result}, verbose) do
    status = check_status(name, result)
    color = if status == :ok, do: IO.ANSI.green(), else: IO.ANSI.yellow()

    IO.puts("\n#{color}[#{name}]#{IO.ANSI.reset()}")

    case name do
      :service_running ->
        IO.puts("  Running: #{bool_emoji(result.running)}")
        IO.puts("  Processes: #{result.processes}")
        if verbose && result.output != "", do: IO.puts("  Output:\n#{indent(result.output, 4)}")

      :health_local ->
        IO.puts("  Healthy: #{bool_emoji(result[:healthy])}")
        if result[:response], do: IO.puts("  Response: #{inspect(result.response)}")

      :ports_listening ->
        IO.puts("  Port 8044: #{bool_emoji(result.port_8044_listening)}")
        if verbose, do: IO.puts("  Output:\n#{indent(result.output, 4)}")

      :gpu_status ->
        IO.puts("  Available: #{bool_emoji(result.available)}")
        if result.available, do: IO.puts("  Info: #{result.output}")

      _ ->
        if result[:output] do
          if verbose do
            IO.puts("  Output:\n#{indent(result.output, 4)}")
          else
            lines = String.split(result.output, "\n") |> Enum.take(3)
            IO.puts("  #{Enum.join(lines, "\n  ")}")
            if length(String.split(result.output, "\n")) > 3, do: IO.puts("  ...")
          end
        end
    end
  end

  defp print_check(name, {:error, reason}, _verbose) do
    IO.puts("\n#{IO.ANSI.red()}[#{name}]#{IO.ANSI.reset()}")
    IO.puts("  Error: #{inspect(reason)}")
  end

  defp check_status(:service_running, %{running: true}), do: :ok
  defp check_status(:health_local, %{healthy: true}), do: :ok
  defp check_status(:ports_listening, %{port_8044_listening: true}), do: :ok
  defp check_status(:gpu_status, %{available: true}), do: :ok
  defp check_status(_, _), do: :warn

  defp bool_emoji(true), do: "#{IO.ANSI.green()}YES#{IO.ANSI.reset()}"
  defp bool_emoji(false), do: "#{IO.ANSI.red()}NO#{IO.ANSI.reset()}"
  defp bool_emoji(nil), do: "#{IO.ANSI.yellow()}UNKNOWN#{IO.ANSI.reset()}"

  defp indent(text, spaces) do
    padding = String.duplicate(" ", spaces)

    text
    |> String.split("\n")
    |> Enum.map(&(padding <> &1))
    |> Enum.join("\n")
  end
end
