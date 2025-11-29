defmodule Lumainus.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  alias Oban

  @impl true
  def start(_type, _args) do
    # Core infrastructure
    base_children = [
      LumainusWeb.Telemetry,
      Lumainus.Repo,
      {Oban, Application.fetch_env!(:lumainus, Oban)},
      {DNSCluster, query: Application.get_env(:lumainus_web, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: LumainusWeb.PubSub},
      # Finch for HTTP client (used by SSE consumer)
      {Finch, name: Lumainus.Finch},
      # Task supervisor for SSE streaming tasks
      {Task.Supervisor, name: Lumainus.TaskSupervisor},
      # Conversion system (v2)
      {Registry, keys: :unique, name: Lumainus.Conversion.Registry},
      Lumainus.Conversion.Application.JobTracker
    ]

    # Docker auto-management MUST start before HealthManager (blocks until container healthy)
    docker_children =
      if docker_auto_manage_enabled?() do
        [Lumainus.Docling.DockerManager]
      else
        []
      end

    # Health manager starts after Docker is ready
    health_children = [
      Lumainus.Conversion.Infrastructure.HealthManager
    ]

    # Web endpoint last
    endpoint_children = [
      LumainusWeb.Endpoint
    ]

    children = base_children ++ docker_children ++ health_children ++ endpoint_children

    children =
      if Application.get_env(:lumainus, :disable_ingestion_health_checker, false) do
        children
      else
        children ++ [Lumainus.Documents.IngestionHealthChecker]
      end

    # Add VastAI workers: StartTracker must start before InstanceManager (dependency)
    children =
      if vast_ai_enabled?() do
        children ++
          [
            Lumainus.Docling.VastAI.StartTracker,
            Lumainus.Docling.VastAI.InstanceManager,
            Lumainus.Docling.VastAI.ActivityTracker,
            Lumainus.Docling.VastAI.AutoShutdown,
            Lumainus.Docling.VastAI.ProvisioningState
          ]
      else
        children
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LumainusWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LumainusWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp vast_ai_enabled? do
    case Application.get_env(:lumainus, :vast_ai) do
      nil -> false
      config -> Keyword.has_key?(config, :api_key)
    end
  end

  defp docker_auto_manage_enabled? do
    config = Application.get_env(:lumainus, :docling, [])
    Keyword.get(config, :docker_auto_manage, true)
  end
end
