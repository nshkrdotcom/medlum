defmodule Medlum.GPU do
  @moduledoc """
  Context for GPU instance management and event logging.

  Provides a comprehensive API for:
  - Logging all GPU-related events
  - Managing instance sessions
  - Querying event history
  - Cost tracking and analytics
  """

  import Ecto.Query
  alias Medlum.Repo
  alias Medlum.GPU.{Event, Session}

  # ============================================================================
  # Event Logging
  # ============================================================================

  @doc """
  Log a GPU event.

  ## Examples

      GPU.log(:provisioning, :search_started, "Searching for GPU offers",
        correlation_id: uuid,
        details: %{filters: filters}
      )

      GPU.log(:error, :provisioning_failed, "Instance creation failed",
        severity: "error",
        instance_id: 12345,
        error_type: "api_error",
        error_message: "Rate limited"
      )
  """
  def log(category, type, message, opts \\ []) do
    attrs = Event.build(category, type, message, opts)

    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
    |> broadcast_event()
  end

  @doc "Log with automatic correlation ID generation"
  def log_with_correlation(category, type, message, opts \\ []) do
    correlation_id = Keyword.get(opts, :correlation_id, Ecto.UUID.generate())
    log(category, type, message, Keyword.put(opts, :correlation_id, correlation_id))
  end

  @doc "Log an error event with full details"
  def log_error(category, type, message, error, opts \\ []) do
    {error_type, error_message, stacktrace} = format_error(error)

    opts =
      opts
      |> Keyword.put(:severity, "error")
      |> Keyword.put(:error_type, error_type)
      |> Keyword.put(:error_message, error_message)
      |> Keyword.put(:stacktrace, stacktrace)

    log(category, type, message, opts)
  end

  @doc "Log a timed operation (records duration)"
  def log_timed(category, type, message, started_at, opts \\ []) do
    completed_at = DateTime.utc_now()
    duration_ms = DateTime.diff(completed_at, started_at, :millisecond)

    opts =
      opts
      |> Keyword.put(:started_at, started_at)
      |> Keyword.put(:completed_at, completed_at)
      |> Keyword.put(:duration_ms, duration_ms)

    log(category, type, message, opts)
  end

  defp format_error(%{__exception__: true} = exception) do
    {exception.__struct__ |> to_string(), Exception.message(exception), nil}
  end

  defp format_error({:error, reason}) when is_atom(reason) do
    {to_string(reason), to_string(reason), nil}
  end

  defp format_error({:error, reason}) when is_binary(reason) do
    {"error", reason, nil}
  end

  defp format_error(error) when is_atom(error) do
    {to_string(error), to_string(error), nil}
  end

  defp format_error(error) do
    {"unknown", inspect(error), nil}
  end

  defp broadcast_event({:ok, event} = result) do
    Phoenix.PubSub.broadcast(
      MedlumWeb.PubSub,
      "gpu:events",
      {:gpu_event, event}
    )

    result
  end

  defp broadcast_event(result), do: result

  @doc "Subscribe to GPU events"
  def subscribe_events do
    Phoenix.PubSub.subscribe(MedlumWeb.PubSub, "gpu:events")
  end

  # ============================================================================
  # Event Queries
  # ============================================================================

  @doc "List recent events with filtering"
  def list_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    query =
      Event
      |> order_by([e], desc: e.inserted_at)
      |> limit(^limit)
      |> offset(^offset)

    query =
      case Keyword.get(opts, :instance_id) do
        nil -> query
        id -> where(query, [e], e.instance_id == ^id)
      end

    query =
      case Keyword.get(opts, :category) do
        nil -> query
        cat -> where(query, [e], e.event_category == ^cat)
      end

    query =
      case Keyword.get(opts, :severity) do
        nil -> query
        sev -> where(query, [e], e.severity == ^sev)
      end

    query =
      case Keyword.get(opts, :correlation_id) do
        nil -> query
        id -> where(query, [e], e.correlation_id == ^id)
      end

    query =
      case Keyword.get(opts, :since) do
        nil -> query
        dt -> where(query, [e], e.inserted_at >= ^dt)
      end

    query =
      case Keyword.get(opts, :until) do
        nil -> query
        dt -> where(query, [e], e.inserted_at <= ^dt)
      end

    Repo.all(query)
  end

  @doc "Get events for a specific correlation ID (a provisioning session)"
  def get_correlated_events(correlation_id) do
    Event
    |> where([e], e.correlation_id == ^correlation_id)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  @doc "Get event counts by category for a time period"
  def event_counts_by_category(since \\ nil) do
    since = since || DateTime.add(DateTime.utc_now(), -24, :hour)

    Event
    |> where([e], e.inserted_at >= ^since)
    |> group_by([e], e.event_category)
    |> select([e], {e.event_category, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Get error events in the last N hours"
  def recent_errors(hours \\ 24) do
    since = DateTime.add(DateTime.utc_now(), -hours, :hour)

    Event
    |> where([e], e.severity in ["error", "critical"])
    |> where([e], e.inserted_at >= ^since)
    |> order_by([e], desc: e.inserted_at)
    |> Repo.all()
  end

  # ============================================================================
  # Session Management
  # ============================================================================

  @doc "Create a new instance session"
  def create_session(attrs) do
    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Get the current active session (if any)"
  def get_active_session do
    Session
    |> where([s], is_nil(s.destroyed_at))
    |> where([s], s.status not in ["destroyed", "failed"])
    |> order_by([s], desc: s.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Get session by instance_id"
  def get_session_by_instance(instance_id) do
    Session
    |> where([s], s.instance_id == ^instance_id)
    |> order_by([s], desc: s.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Get session by ID"
  def get_session(id), do: Repo.get(Session, id)

  @doc "Update session status"
  def update_session_status(session, status, opts \\ []) do
    session
    |> Session.status_changeset(status, opts)
    |> Repo.update()
    |> tap(fn
      {:ok, session} ->
        log(
          :lifecycle,
          String.to_atom("status_#{status}"),
          "Instance status changed to #{status}",
          instance_id: session.instance_id,
          instance_status: status,
          source: "instance_manager"
        )

      _ ->
        :ok
    end)
  end

  @doc "Update session with instance details from Vast.ai response"
  def update_session_details(session, instance_data) do
    attrs =
      %{
        instance_id: instance_data["id"],
        offer_id: instance_data["bundle_id"],
        machine_id: instance_data["machine_id"],
        gpu_name: instance_data["gpu_name"],
        gpu_ram_mb: instance_data["gpu_ram"],
        cpu_name: instance_data["cpu_name"],
        cpu_cores: instance_data["cpu_cores"],
        ram_mb: instance_data["cpu_ram"],
        geolocation: instance_data["geolocation"],
        public_ip: instance_data["public_ipaddr"],
        ssh_host: instance_data["ssh_host"],
        ssh_port: instance_data["ssh_port"],
        hourly_cost: instance_data["dph_total"] && Decimal.from_float(instance_data["dph_total"])
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    session
    |> Session.changeset(attrs)
    |> Repo.update()
  end

  @doc "Record activity on session"
  def record_session_activity(session) do
    session
    |> Session.activity_changeset()
    |> Repo.update()
  end

  @doc "Update idle time on session"
  def update_session_idle(session, idle_minutes) do
    session
    |> Session.idle_changeset(idle_minutes)
    |> Repo.update()
  end

  @doc "Mark session as destroyed"
  def destroy_session(session, reason \\ "manual") do
    # Calculate final cost
    total_cost = Session.calculate_cost(session)

    session
    |> Session.changeset(%{
      status: "destroyed",
      destroyed_at: DateTime.utc_now(),
      destroy_reason: reason,
      total_cost: total_cost
    })
    |> Repo.update()
    |> tap(fn
      {:ok, session} ->
        log(:lifecycle, :instance_destroyed, "Instance destroyed: #{reason}",
          instance_id: session.instance_id,
          instance_status: "destroyed",
          details: %{reason: reason, total_cost: Decimal.to_string(total_cost)},
          source: "instance_manager"
        )

      _ ->
        :ok
    end)
  end

  @doc "List all sessions"
  def list_sessions(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    query =
      Session
      |> order_by([s], desc: s.inserted_at)
      |> limit(^limit)

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [s], s.status == ^status)
      end

    query =
      case Keyword.get(opts, :include_destroyed) do
        true -> query
        _ -> where(query, [s], is_nil(s.destroyed_at))
      end

    Repo.all(query)
  end

  @doc "Get session history (all sessions including destroyed)"
  def session_history(limit \\ 20) do
    Session
    |> order_by([s], desc: s.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # ============================================================================
  # Analytics
  # ============================================================================

  @doc "Get total cost for a time period"
  def total_cost(since \\ nil) do
    since = since || DateTime.add(DateTime.utc_now(), -30, :day)

    Session
    |> where([s], s.provisioned_at >= ^since)
    |> select([s], sum(s.total_cost))
    |> Repo.one() || Decimal.new(0)
  end

  @doc "Get total runtime minutes for a time period"
  def total_runtime(since \\ nil) do
    since = since || DateTime.add(DateTime.utc_now(), -30, :day)

    sessions =
      Session
      |> where([s], s.provisioned_at >= ^since)
      |> where([s], not is_nil(s.provisioned_at))
      |> Repo.all()

    Enum.reduce(sessions, 0, fn session, acc ->
      end_time = session.destroyed_at || DateTime.utc_now()
      start_time = session.provisioned_at || session.inserted_at
      minutes = DateTime.diff(end_time, start_time, :minute)
      acc + max(minutes, 0)
    end)
  end

  @doc "Get summary stats for dashboard"
  def summary_stats do
    now = DateTime.utc_now()
    day_ago = DateTime.add(now, -24, :hour)
    week_ago = DateTime.add(now, -7, :day)
    month_ago = DateTime.add(now, -30, :day)

    active_session = get_active_session()

    %{
      active_instance: active_session != nil,
      active_session: active_session,
      events_24h: Event |> where([e], e.inserted_at >= ^day_ago) |> Repo.aggregate(:count),
      errors_24h:
        Event
        |> where([e], e.inserted_at >= ^day_ago and e.severity in ["error", "critical"])
        |> Repo.aggregate(:count),
      sessions_7d: Session |> where([s], s.inserted_at >= ^week_ago) |> Repo.aggregate(:count),
      cost_30d: total_cost(month_ago),
      runtime_30d: total_runtime(month_ago)
    }
  end

  # ============================================================================
  # Provisioning Event Helpers
  # ============================================================================

  @doc "Start a new provisioning session and return correlation ID"
  def start_provisioning(opts \\ []) do
    correlation_id = Ecto.UUID.generate()

    # Create session
    {:ok, session} =
      create_session(%{
        status: "provisioning",
        label: Keyword.get(opts, :label),
        image: Keyword.get(opts, :image),
        metadata: Keyword.get(opts, :metadata, %{})
      })

    # Log start event
    log(:provisioning, :started, "GPU provisioning started",
      correlation_id: correlation_id,
      source: "provisioning",
      details: opts |> Keyword.take([:label, :image, :filters]) |> Map.new()
    )

    {correlation_id, session}
  end

  @doc "Log provisioning step"
  def log_provisioning(correlation_id, type, message, opts \\ []) do
    log(:provisioning, type, message, Keyword.put(opts, :correlation_id, correlation_id))
  end

  @doc "Complete provisioning successfully"
  def complete_provisioning(correlation_id, session, endpoint, opts \\ []) do
    instance_id = Keyword.get(opts, :instance_id)

    # Update session to ready
    {:ok, session} = update_session_status(session, "ready")

    {:ok, session} =
      Session.changeset(session, %{
        endpoint: endpoint,
        https_enabled: String.starts_with?(endpoint || "", "https")
      })
      |> Repo.update()

    # Log completion
    log(:provisioning, :completed, "GPU provisioning completed successfully",
      correlation_id: correlation_id,
      instance_id: instance_id,
      endpoint: endpoint,
      severity: "info",
      source: "provisioning"
    )

    {:ok, session}
  end

  @doc "Fail provisioning"
  def fail_provisioning(correlation_id, session, reason, opts \\ []) do
    # Update session to failed
    if session do
      update_session_status(session, "failed", reason: inspect(reason))
    end

    # Log failure
    log_error(:provisioning, :failed, "GPU provisioning failed", reason,
      correlation_id: correlation_id,
      instance_id: Keyword.get(opts, :instance_id),
      source: "provisioning"
    )
  end

  # ============================================================================
  # Auto-shutdown Event Helpers
  # ============================================================================

  @doc "Log auto-shutdown check"
  def log_auto_shutdown_check(instance_id, idle_minutes, threshold_minutes)
      when is_integer(idle_minutes) and is_integer(threshold_minutes) do
    log(:auto_shutdown, :idle_check, "Idle check: #{idle_minutes}/#{threshold_minutes} minutes",
      instance_id: instance_id,
      severity: if(idle_minutes >= threshold_minutes, do: "warning", else: "debug"),
      source: "auto_shutdown",
      details: %{
        idle_minutes: idle_minutes,
        threshold_minutes: threshold_minutes,
        will_shutdown: idle_minutes >= threshold_minutes
      }
    )
  end

  @doc "Log auto-shutdown triggered"
  def log_auto_shutdown_triggered(instance_id, idle_minutes) do
    log(:auto_shutdown, :triggered, "Auto-shutdown triggered after #{idle_minutes} minutes idle",
      instance_id: instance_id,
      severity: "warning",
      source: "auto_shutdown",
      details: %{idle_minutes: idle_minutes}
    )
  end

  # ============================================================================
  # Cron Event Helpers
  # ============================================================================

  @doc "Log cron job execution"
  def log_cron(job_name, message, opts \\ []) do
    log(
      :cron,
      String.to_atom(job_name),
      message,
      Keyword.merge([source: "cron", severity: "info"], opts)
    )
  end

  @doc "Log cron job error"
  def log_cron_error(job_name, message, error) do
    log_error(:cron, String.to_atom(job_name), message, error, source: "cron")
  end
end
