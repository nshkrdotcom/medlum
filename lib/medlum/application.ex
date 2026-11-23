defmodule Medlum.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  alias Oban
  require Logger

  alias Medlum.VastAI.Availability

  @impl true
  def start(_type, _args) do
    # Attach telemetry handlers early
    Medlum.AI.TelemetryHandler.attach()
    Medlum.AI.InvocationTelemetryHandler.attach()
    Medlum.Reports.ObanTelemetryHandler.attach()

    # Core infrastructure
    base_children = [
      MedlumWeb.Telemetry,
      Medlum.Repo,
      {Oban, Application.fetch_env!(:medlum, Oban)},
      {DNSCluster, query: Application.get_env(:medlum, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: MedlumWeb.PubSub},
      # Finch for HTTP client (used by SSE consumer)
      {Finch, name: Medlum.Finch},
      # Task supervisor for SSE streaming tasks
      {Task.Supervisor, name: Medlum.TaskSupervisor},
      # AI concurrency gate (defense in depth for LLM rate limiting)
      {Medlum.AI.ConcurrencyGate, gate_config()},
      # Conversion system (v2)
      {Registry, keys: :unique, name: Medlum.Conversion.Registry},
      Medlum.Conversion.Application.JobTracker
    ]

    # Docker auto-management MUST start before HealthManager (blocks until container healthy)
    docker_children =
      if docker_auto_manage_enabled?() do
        [Medlum.Docling.DockerManager]
      else
        []
      end

    # Health manager starts after Docker is ready
    health_children = [
      Medlum.Conversion.Infrastructure.HealthManager
    ]

    # Web endpoint last
    endpoint_children = [
      MedlumWeb.Endpoint
    ]

    children = base_children ++ docker_children ++ health_children ++ endpoint_children

    children =
      if Application.get_env(:medlum, :disable_ingestion_health_checker, false) do
        children
      else
        children ++ [Medlum.Documents.IngestionHealthChecker]
      end

    # Add VastAI workers: StartTracker must start before InstanceManager (dependency)
    children =
      if vast_ai_enabled?() do
        children ++
          [
            Medlum.Docling.VastAI.StartTracker,
            Medlum.Docling.VastAI.InstanceManager,
            Medlum.Docling.VastAI.ActivityTracker,
            Medlum.Docling.VastAI.AutoShutdown,
            Medlum.Docling.VastAI.ProvisioningState
          ]
      else
        Logger.info("[VastAI] Vast.ai workers not started (no API key configured)")
        children
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MedlumWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MedlumWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp vast_ai_enabled? do
    Availability.enabled?()
  end

  defp docker_auto_manage_enabled? do
    config = Application.get_env(:medlum, :docling, [])
    Keyword.get(config, :docker_auto_manage, true)
  end

  defp gate_config do
    config = Application.get_env(:medlum, :concurrency_gate, [])

    [
      max_concurrent: Keyword.get(config, :max_concurrent, 1),
      max_queue: Keyword.get(config, :max_queue, 50),
      inter_call_delay_ms: Keyword.get(config, :inter_call_delay_ms, 2000)
    ]
  end
end
