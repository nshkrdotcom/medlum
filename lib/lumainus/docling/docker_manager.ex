defmodule Lumainus.Docling.DockerManager do
  @moduledoc """
  Manages the local Docling Docker container lifecycle.

  - Starts container when Phoenix boots
  - Stops container when Phoenix shuts down
  - Monitors health and restarts if container dies

  ## Configuration

      config :lumainus, :docling,
        docker_auto_manage: true,      # Enable auto-management (default: true)
        docker_service: "docling-cpu", # Which service to manage (default: "docling-cpu")
        docker_compose_path: nil       # Path to docker-compose.yml (default: app root)
  """

  use GenServer
  require Logger

  @health_check_interval_ms 30_000
  @startup_timeout_ms 120_000
  @health_endpoint "http://127.0.0.1:8042/health"

  defstruct [:service, :compose_path, :status, :container_id]

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get current status: :starting, :running, :unhealthy, :stopped"
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Force restart the container"
  def restart do
    GenServer.call(__MODULE__, :restart, @startup_timeout_ms)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    config = Application.get_env(:lumainus, :docling, [])

    state = %__MODULE__{
      service: Keyword.get(config, :docker_service, "docling-cpu"),
      compose_path: Keyword.get(config, :docker_compose_path) || app_root(),
      status: :starting,
      container_id: nil
    }

    # Block startup until container is healthy
    case start_container_blocking(state) do
      {:ok, new_state} ->
        schedule_health_check()
        {:ok, new_state}

      {:error, reason} ->
        Logger.error("[DockerManager] Failed to start container: #{inspect(reason)}")
        # Still start, but in unhealthy state - will retry via health checks
        schedule_health_check()
        send(self(), :start_container)
        {:ok, %{state | status: :unhealthy}}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("[DockerManager] Shutting down (#{inspect(reason)}), stopping container...")
    stop_container(state)
    :ok
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call(:restart, _from, state) do
    Logger.info("[DockerManager] Restarting container...")
    stop_container(state)

    case start_container(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, %{state | status: :stopped}}
    end
  end

  @impl true
  def handle_info(:start_container, state) do
    case start_container(state) do
      {:ok, new_state} ->
        schedule_health_check()
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("[DockerManager] Failed to start container: #{inspect(reason)}")
        # Retry in 30 seconds
        Process.send_after(self(), :start_container, 30_000)
        {:noreply, %{state | status: :stopped}}
    end
  end

  @impl true
  def handle_info(:health_check, state) do
    new_state =
      case check_health() do
        :ok ->
          if state.status != :running do
            Logger.info("[DockerManager] Container is healthy")
            broadcast_status(:running)
          end

          %{state | status: :running}

        {:error, reason} ->
          Logger.warning("[DockerManager] Health check failed: #{inspect(reason)}")

          if state.status == :running do
            # Was running, now unhealthy - try to restart
            Logger.info("[DockerManager] Attempting to restart container...")
            broadcast_status(:unhealthy)
            restart_container(state)
          end

          %{state | status: :unhealthy}
      end

    schedule_health_check()
    {:noreply, new_state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp start_container_blocking(state) do
    IO.puts("\n#{IO.ANSI.cyan()}[DockerManager]#{IO.ANSI.reset()} Starting #{state.service}...")

    # Use --force-recreate to always pick up code changes from mounted volumes
    args = [
      "compose",
      "-f",
      Path.join(state.compose_path, "docker-compose.yml"),
      "up",
      "-d",
      "--force-recreate",
      state.service
    ]

    case System.cmd("docker", args, stderr_to_stdout: true, cd: state.compose_path) do
      {output, 0} ->
        Logger.debug("[DockerManager] docker compose up output: #{String.trim(output)}")

        IO.puts(
          "#{IO.ANSI.cyan()}[DockerManager]#{IO.ANSI.reset()} Container started, waiting for healthy..."
        )

        # Wait for container to be healthy with progress updates
        case wait_for_healthy_with_progress(@startup_timeout_ms) do
          :ok ->
            IO.puts(
              "#{IO.ANSI.green()}[DockerManager]#{IO.ANSI.reset()} Container healthy and ready!"
            )

            broadcast_status(:running)
            {:ok, %{state | status: :running}}

          {:error, :timeout} ->
            IO.puts(
              "#{IO.ANSI.yellow()}[DockerManager]#{IO.ANSI.reset()} Timeout waiting for healthy - continuing anyway"
            )

            {:ok, %{state | status: :starting}}
        end

      {output, code} ->
        IO.puts(
          "#{IO.ANSI.red()}[DockerManager]#{IO.ANSI.reset()} docker compose up failed (#{code}): #{output}"
        )

        {:error, {:docker_error, code, output}}
    end
  end

  defp start_container(state) do
    Logger.info("[DockerManager] Starting #{state.service}...")

    # Use --force-recreate to always pick up code changes from mounted volumes
    args = [
      "compose",
      "-f",
      Path.join(state.compose_path, "docker-compose.yml"),
      "up",
      "-d",
      "--force-recreate",
      state.service
    ]

    case System.cmd("docker", args, stderr_to_stdout: true, cd: state.compose_path) do
      {output, 0} ->
        Logger.debug("[DockerManager] docker compose up output: #{output}")

        # Wait for container to be healthy
        case wait_for_healthy(@startup_timeout_ms) do
          :ok ->
            Logger.info("[DockerManager] Container started and healthy")
            broadcast_status(:running)
            {:ok, %{state | status: :running}}

          {:error, :timeout} ->
            Logger.warning("[DockerManager] Container started but not healthy yet")
            {:ok, %{state | status: :starting}}
        end

      {output, code} ->
        Logger.error("[DockerManager] docker compose up failed (#{code}): #{output}")
        {:error, {:docker_error, code, output}}
    end
  end

  defp stop_container(state) do
    Logger.info("[DockerManager] Stopping #{state.service}...")

    args = [
      "compose",
      "-f",
      Path.join(state.compose_path, "docker-compose.yml"),
      "stop",
      state.service
    ]

    case System.cmd("docker", args, stderr_to_stdout: true, cd: state.compose_path) do
      {_, 0} ->
        Logger.info("[DockerManager] Container stopped")
        :ok

      {output, code} ->
        Logger.warning("[DockerManager] docker compose stop failed (#{code}): #{output}")
        :ok
    end
  end

  defp restart_container(state) do
    args = [
      "compose",
      "-f",
      Path.join(state.compose_path, "docker-compose.yml"),
      "restart",
      state.service
    ]

    case System.cmd("docker", args, stderr_to_stdout: true, cd: state.compose_path) do
      {_, 0} ->
        Logger.info("[DockerManager] Container restarted")
        :ok

      {output, code} ->
        Logger.warning("[DockerManager] docker compose restart failed (#{code}): #{output}")
        :error
    end
  end

  defp wait_for_healthy_with_progress(timeout_ms) do
    # Show progress every 5 seconds
    do_wait_for_healthy_with_progress(timeout_ms, 0, 0)
  end

  defp do_wait_for_healthy_with_progress(timeout_ms, elapsed, last_report)
       when elapsed >= timeout_ms do
    {:error, :timeout}
  end

  defp do_wait_for_healthy_with_progress(timeout_ms, elapsed, last_report) do
    # Report every 5 seconds
    if elapsed - last_report >= 5_000 and elapsed > 0 do
      seconds = div(elapsed, 1000)

      IO.puts(
        "#{IO.ANSI.cyan()}[DockerManager]#{IO.ANSI.reset()} Still waiting... (#{seconds}s elapsed)"
      )

      new_last_report = elapsed
      do_check_and_wait(timeout_ms, elapsed, new_last_report)
    else
      do_check_and_wait(timeout_ms, elapsed, last_report)
    end
  end

  defp do_check_and_wait(timeout_ms, elapsed, last_report) do
    case check_health() do
      :ok ->
        :ok

      {:error, _reason} ->
        Process.sleep(1_000)
        do_wait_for_healthy_with_progress(timeout_ms, elapsed + 1_000, last_report)
    end
  end

  defp wait_for_healthy(timeout_ms, elapsed \\ 0) do
    if elapsed >= timeout_ms do
      {:error, :timeout}
    else
      case check_health() do
        :ok ->
          :ok

        {:error, _} ->
          Process.sleep(2_000)
          wait_for_healthy(timeout_ms, elapsed + 2_000)
      end
    end
  end

  defp check_health do
    case Req.get(@health_endpoint, receive_timeout: 5_000, retry: false) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        {:error, {:unhealthy, status}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:connection_failed, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval_ms)
  end

  defp broadcast_status(status) do
    Phoenix.PubSub.broadcast(
      LumainusWeb.PubSub,
      "docling:status",
      {:docling_docker_status, status}
    )
  end

  defp app_root do
    # In development: use the project root (where docker-compose.yml lives)
    # In production: use configured path or current working directory
    cond do
      # Check if we're in a Mix project (development)
      File.exists?(Path.join(File.cwd!(), "docker-compose.yml")) ->
        File.cwd!()

      # Check relative to priv directory (release)
      File.exists?(
        Path.join(Application.app_dir(:lumainus, "priv"), "../../../docker-compose.yml")
      ) ->
        Application.app_dir(:lumainus, "priv") |> Path.join("../../..") |> Path.expand()

      # Fallback to current directory
      true ->
        File.cwd!()
    end
  end
end
