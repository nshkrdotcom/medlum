defmodule Lumainus.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  alias Oban

  @impl true
  def start(_type, _args) do
    configure_req_llm_keys()

    children = [
      LumainusWeb.Telemetry,
      Lumainus.Repo,
      {Oban, Application.fetch_env!(:lumainus, Oban)},
      {DNSCluster, query: Application.get_env(:lumainus_web, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: LumainusWeb.PubSub},
      # Start a worker by calling: LumainusWeb.Worker.start_link(arg)
      # {LumainusWeb.Worker, arg},
      # Start to serve requests, typically the last entry
      LumainusWeb.Endpoint
    ]

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

  defp configure_req_llm_keys do
    key =
      System.get_env("GOOGLE_API_KEY") ||
        System.get_env("GEMINI_API_KEY")

    if key && Code.ensure_loaded?(ReqLLM) do
      ReqLLM.put_key(:google_api_key, key)
    end
  end
end
