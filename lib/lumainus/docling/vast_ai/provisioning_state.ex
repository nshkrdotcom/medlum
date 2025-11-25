defmodule Lumainus.Docling.VastAI.ProvisioningState do
  @moduledoc """
  Shared state for GPU provisioning progress.

  Allows provisioning status and logs to be shared across LiveViews
  and persisted across page navigations. Also logs all events to the
  database via the GPU context for permanent audit trail.
  """
  use GenServer

  alias Lumainus.GPU

  @pubsub LumainusWeb.PubSub
  @topic "vast_ai:provisioning"

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Get current provisioning state"
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc "Start a new provisioning session"
  def start_provisioning(use_https \\ true, opts \\ []) do
    GenServer.call(__MODULE__, {:start_provisioning, use_https, opts})
  end

  @doc "Add a log entry"
  def add_log(level, message, opts \\ []) do
    GenServer.cast(__MODULE__, {:add_log, level, message, opts})
  end

  @doc "Update provisioning status message"
  def update_status(status) do
    GenServer.cast(__MODULE__, {:update_status, status})
  end

  @doc "Mark provisioning as complete"
  def complete(instance_id, endpoint) do
    GenServer.cast(__MODULE__, {:complete, instance_id, endpoint})
  end

  @doc "Mark provisioning as failed"
  def fail(reason) do
    GenServer.cast(__MODULE__, {:fail, reason})
  end

  @doc "Cancel provisioning"
  def cancel do
    GenServer.cast(__MODULE__, :cancel)
  end

  @doc "Clear logs"
  def clear_logs do
    GenServer.cast(__MODULE__, :clear_logs)
  end

  @doc "Subscribe to provisioning updates"
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc "Get the current correlation ID for this provisioning session"
  def get_correlation_id do
    GenServer.call(__MODULE__, :get_correlation_id)
  end

  @doc "Get the current session"
  def get_session do
    GenServer.call(__MODULE__, :get_session)
  end

  @doc "Update session with instance details"
  def update_session_details(instance_data) do
    GenServer.cast(__MODULE__, {:update_session_details, instance_data})
  end

  # Server callbacks

  @impl true
  def init(_) do
    {:ok, initial_state()}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:get_correlation_id, _from, state) do
    {:reply, state.correlation_id, state}
  end

  def handle_call(:get_session, _from, state) do
    {:reply, state.session, state}
  end

  def handle_call({:start_provisioning, use_https, opts}, _from, _state) do
    # Create database session and get correlation ID
    {correlation_id, session} =
      GPU.start_provisioning(
        label: Keyword.get(opts, :label, "vast_ai_provisioning"),
        image: Keyword.get(opts, :image),
        metadata: %{use_https: use_https}
      )

    state = %{
      provisioning: true,
      status: "Starting provisioning...",
      logs: [log_entry(:info, "Provisioning started")],
      use_https: use_https,
      started_at: DateTime.utc_now(),
      instance_id: nil,
      endpoint: nil,
      error: nil,
      correlation_id: correlation_id,
      session: session
    }

    broadcast(:provisioning_started, state)
    {:reply, {:ok, correlation_id, session}, state}
  end

  @impl true
  def handle_cast({:add_log, level, message, opts}, state) do
    entry = log_entry(level, message)
    logs = [entry | state.logs] |> Enum.take(100)
    state = %{state | logs: logs}

    # Log to database with correlation
    if state.correlation_id do
      db_level =
        case level do
          :success -> "info"
          :warning -> "warning"
          :error -> "error"
          _ -> "info"
        end

      event_type = Keyword.get(opts, :event_type, :log)
      details = Keyword.get(opts, :details, %{})

      GPU.log_provisioning(state.correlation_id, event_type, message,
        severity: db_level,
        instance_id: state.instance_id || Keyword.get(opts, :instance_id),
        details: details
      )
    end

    broadcast(:log_added, entry)
    {:noreply, state}
  end

  def handle_cast({:update_status, status}, state) do
    state = %{state | status: status}

    # Log status change to database
    if state.correlation_id do
      GPU.log_provisioning(state.correlation_id, :status_change, status,
        instance_id: state.instance_id,
        severity: "info"
      )
    end

    broadcast(:status_updated, status)
    {:noreply, state}
  end

  def handle_cast({:update_session_details, instance_data}, state) do
    # Update session with instance details from Vast.ai response
    if state.session do
      case GPU.update_session_details(state.session, instance_data) do
        {:ok, updated_session} ->
          instance_id = instance_data["id"]
          {:noreply, %{state | session: updated_session, instance_id: instance_id}}

        _ ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_cast({:complete, instance_id, endpoint}, state) do
    entry =
      log_entry(:success, "Provisioning complete! Instance #{instance_id} ready at #{endpoint}")

    logs = [entry | state.logs] |> Enum.take(100)

    # Complete provisioning in database
    if state.correlation_id && state.session do
      GPU.complete_provisioning(state.correlation_id, state.session, endpoint,
        instance_id: instance_id
      )
    end

    state = %{
      state
      | provisioning: false,
        status: nil,
        logs: logs,
        instance_id: instance_id,
        endpoint: endpoint
    }

    broadcast(:provisioning_complete, %{instance_id: instance_id, endpoint: endpoint})
    {:noreply, state}
  end

  def handle_cast({:fail, reason}, state) do
    entry = log_entry(:error, "Provisioning failed: #{inspect(reason)}")
    logs = [entry | state.logs] |> Enum.take(100)

    # Fail provisioning in database
    if state.correlation_id do
      GPU.fail_provisioning(state.correlation_id, state.session, reason,
        instance_id: state.instance_id
      )
    end

    state = %{state | provisioning: false, status: nil, logs: logs, error: reason}
    broadcast(:provisioning_failed, reason)
    {:noreply, state}
  end

  def handle_cast(:cancel, state) do
    entry = log_entry(:warning, "Provisioning cancelled by user")
    logs = [entry | state.logs] |> Enum.take(100)

    # Log cancellation to database
    if state.correlation_id do
      GPU.log_provisioning(state.correlation_id, :cancelled, "Provisioning cancelled by user",
        severity: "warning",
        instance_id: state.instance_id
      )

      # Update session status
      if state.session do
        GPU.update_session_status(state.session, "failed", reason: "user_request")
      end
    end

    state = %{state | provisioning: false, status: nil, logs: logs}
    broadcast(:provisioning_cancelled, nil)
    {:noreply, state}
  end

  def handle_cast(:clear_logs, state) do
    state = %{state | logs: []}
    broadcast(:logs_cleared, nil)
    {:noreply, state}
  end

  # Private

  defp initial_state do
    %{
      provisioning: false,
      status: nil,
      logs: [],
      use_https: true,
      started_at: nil,
      instance_id: nil,
      endpoint: nil,
      error: nil,
      correlation_id: nil,
      session: nil
    }
  end

  defp log_entry(level, message) do
    %{
      level: level,
      message: message,
      timestamp: DateTime.utc_now()
    }
  end

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:provisioning_event, event, payload})
  end
end
