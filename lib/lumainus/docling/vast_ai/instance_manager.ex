defmodule Lumainus.Docling.VastAI.InstanceManager do
  @moduledoc """
  Manages Vast.ai GPU instance lifecycle.

  - Provisions instances on-demand
  - Monitors health
  - Destroys idle instances
  - Tracks active instance endpoint

  ## Configuration

      config :lumainus, :docling,
        vast_ai: [
          api_key: "...",
          gpu_name: "RTX_3090",
          min_disk_gb: 20,
          idle_timeout_minutes: 15
        ]

  ## Usage

      # Get or provision an instance
      {:ok, endpoint} = InstanceManager.ensure_instance()

      # Update activity (resets idle timer)
      :ok = InstanceManager.update_activity()

      # Destroy instance
      :ok = InstanceManager.destroy_instance()
  """

  use GenServer
  require Logger

  @idle_check_interval_ms 60_000

  # =============================================================================
  # Public API
  # =============================================================================

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Ensure an instance is running and return its endpoint.

  If no instance exists, provisions a new one. Otherwise returns the cached endpoint.
  """
  def ensure_instance(server \\ __MODULE__) do
    GenServer.call(server, :ensure_instance, 120_000)
  end

  @doc """
  Get current instance endpoint if available.
  """
  def get_endpoint(server \\ __MODULE__) do
    GenServer.call(server, :get_endpoint)
  end

  @doc """
  Get current instance ID.
  """
  def current_instance_id(server \\ __MODULE__) do
    GenServer.call(server, :current_instance_id)
  end

  @doc """
  Destroy current instance.
  """
  def destroy_instance(server \\ __MODULE__) do
    GenServer.call(server, :destroy_instance)
  end

  @doc """
  Update last activity timestamp (resets idle timer).
  """
  def update_activity(server \\ __MODULE__) do
    GenServer.cast(server, :update_activity)
  end

  # =============================================================================
  # GenServer Callbacks
  # =============================================================================

  @impl true
  def init(_opts) do
    {:ok,
     %{
       instance_id: nil,
       endpoint: nil,
       last_activity: nil,
       provisioning: false
     }}
  end

  @impl true
  def handle_call(:ensure_instance, _from, %{endpoint: endpoint} = state)
      when not is_nil(endpoint) do
    state = %{state | last_activity: System.monotonic_time(:millisecond)}
    {:reply, {:ok, endpoint}, state}
  end

  def handle_call(:ensure_instance, _from, state) do
    case provision_instance() do
      {:ok, instance_id, endpoint} ->
        state = %{
          state
          | instance_id: instance_id,
            endpoint: endpoint,
            last_activity: System.monotonic_time(:millisecond)
        }

        schedule_idle_check()
        {:reply, {:ok, endpoint}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_endpoint, _from, state) do
    case state.endpoint do
      nil -> {:reply, {:error, :no_instance}, state}
      endpoint -> {:reply, {:ok, endpoint}, state}
    end
  end

  def handle_call(:current_instance_id, _from, state) do
    {:reply, state.instance_id, state}
  end

  def handle_call(:destroy_instance, _from, state) do
    if state.instance_id do
      destroy_vast_instance(state.instance_id)
    end

    {:reply, :ok, %{state | instance_id: nil, endpoint: nil, last_activity: nil}}
  end

  @impl true
  def handle_cast(:update_activity, state) do
    {:noreply, %{state | last_activity: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_info(:check_idle, state) do
    now = System.monotonic_time(:millisecond)
    idle_time = now - (state.last_activity || now)
    idle_timeout = idle_timeout_ms()

    if idle_time > idle_timeout and state.instance_id do
      Logger.info(
        "[VastAI] Destroying idle instance #{state.instance_id} (idle for #{div(idle_time, 60_000)} minutes)"
      )

      destroy_vast_instance(state.instance_id)
      {:noreply, %{state | instance_id: nil, endpoint: nil, last_activity: nil}}
    else
      schedule_idle_check()
      {:noreply, state}
    end
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp schedule_idle_check do
    Process.send_after(self(), :check_idle, @idle_check_interval_ms)
  end

  defp provision_instance do
    config = vast_ai_config()

    # Check for mock provisioner first (for testing)
    case Keyword.get(config, :provisioner) do
      nil ->
        # Real provisioning via Python script or Elixir HTTP client
        provision_via_api(config)

      provisioner when is_function(provisioner, 0) ->
        provisioner.()
    end
  end

  defp destroy_vast_instance(instance_id) do
    config = vast_ai_config()

    # Check for mock destroyer first (for testing)
    case Keyword.get(config, :destroyer) do
      nil ->
        # Real destruction via Python script or Elixir HTTP client
        destroy_via_api(instance_id, config)

      destroyer when is_function(destroyer, 1) ->
        destroyer.(instance_id)
    end
  end

  defp provision_via_api(_config) do
    # TODO: Implement actual Vast.ai API provisioning
    # This would either:
    # 1. Call Python script: manage_vast.py provision
    # 2. Use Elixir HTTP client to call Vast.ai API directly
    #
    # For now, return an error indicating not implemented
    Logger.warning("[VastAI] API provisioning not yet implemented")
    {:error, :not_implemented}
  end

  defp destroy_via_api(instance_id, _config) do
    # TODO: Implement actual Vast.ai API destruction
    Logger.info("[VastAI] Destroying instance #{instance_id}")
    :ok
  end

  defp vast_ai_config do
    Application.get_env(:lumainus, :docling, [])
    |> Keyword.get(:vast_ai, [])
  end

  defp idle_timeout_ms do
    config = vast_ai_config()
    minutes = Keyword.get(config, :idle_timeout_minutes, 15)
    minutes * 60 * 1000
  end
end
