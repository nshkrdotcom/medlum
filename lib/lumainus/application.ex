defmodule Lumainus.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  alias Oban

  @impl true
  def start(_type, _args) do
    children = [
      LumainusWeb.Telemetry,
      Lumainus.Repo,
      {Oban, Application.fetch_env!(:lumainus, Oban)},
      {DNSCluster, query: Application.get_env(:lumainus_web, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: LumainusWeb.PubSub},
      # Finch for HTTP client (used by SSE consumer)
      {Finch, name: Lumainus.Finch},
      # Task supervisor for SSE streaming tasks
      {Task.Supervisor, name: Lumainus.TaskSupervisor},
      # Start to serve requests, typically the last entry
      LumainusWeb.Endpoint
    ]

    children =
      if Application.get_env(:lumainus, :disable_ingestion_health_checker, false) do
        children
      else
        children ++ [Lumainus.Documents.IngestionHealthChecker]
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
end
