defmodule LumainusWeb.Admin.GPUEventsLive do
  @moduledoc """
  LiveView for GPU instance event history and analytics.

  Shows comprehensive event logs, session history, and cost analytics
  for GPU instance management.
  """
  use LumainusWeb, :live_view

  alias Lumainus.GPU

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to real-time GPU events
      GPU.subscribe_events()
      send(self(), :load_data)
    end

    {:ok,
     socket
     |> assign(
       loading: true,
       events: [],
       sessions: [],
       stats: nil,
       filters: default_filters(),
       selected_session: nil,
       view_mode: :events
     )}
  end

  @impl true
  def handle_info(:load_data, socket) do
    socket =
      socket
      |> load_events()
      |> load_sessions()
      |> load_stats()
      |> assign(loading: false)

    {:noreply, socket}
  end

  def handle_info({:gpu_event, event}, socket) do
    # Add new event to the list in real-time
    events = [event | socket.assigns.events] |> Enum.take(100)
    {:noreply, assign(socket, events: events)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(loading: true)
     |> load_events()
     |> load_sessions()
     |> load_stats()
     |> assign(loading: false)}
  end

  def handle_event("filter", params, socket) do
    filters = %{
      category: params["category"] || nil,
      severity: params["severity"] || nil,
      instance_id: parse_int_or_nil(params["instance_id"]),
      hours: parse_int(params["hours"], 24)
    }

    {:noreply,
     socket
     |> assign(filters: filters)
     |> load_events()}
  end

  def handle_event("view_session", %{"id" => id}, socket) do
    session = GPU.get_session(id)

    events =
      if session, do: GPU.list_events(instance_id: session.instance_id, limit: 200), else: []

    {:noreply,
     assign(socket, selected_session: session, session_events: events, view_mode: :session_detail)}
  end

  def handle_event("back_to_list", _params, socket) do
    {:noreply, assign(socket, selected_session: nil, view_mode: :events)}
  end

  def handle_event("switch_view", %{"view" => view}, socket) do
    view_mode = String.to_existing_atom(view)
    {:noreply, assign(socket, view_mode: view_mode)}
  end

  def handle_event("view_correlation", %{"id" => correlation_id}, socket) do
    events = GPU.get_correlated_events(correlation_id)
    {:noreply, assign(socket, correlated_events: events, view_mode: :correlation)}
  end

  # Private

  defp load_events(socket) do
    filters = socket.assigns.filters
    since = DateTime.add(DateTime.utc_now(), -filters.hours, :hour)

    opts = [limit: 100, since: since]
    opts = if filters.category, do: Keyword.put(opts, :category, filters.category), else: opts
    opts = if filters.severity, do: Keyword.put(opts, :severity, filters.severity), else: opts

    opts =
      if filters.instance_id, do: Keyword.put(opts, :instance_id, filters.instance_id), else: opts

    events = GPU.list_events(opts)
    assign(socket, events: events)
  end

  defp load_sessions(socket) do
    sessions = GPU.session_history(20)
    assign(socket, sessions: sessions)
  end

  defp load_stats(socket) do
    stats = GPU.summary_stats()
    assign(socket, stats: stats)
  end

  defp default_filters do
    %{
      category: nil,
      severity: nil,
      instance_id: nil,
      hours: 24
    }
  end

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default
  defp parse_int(val, _default) when is_integer(val), do: val

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int_or_nil(nil), do: nil
  defp parse_int_or_nil(""), do: nil

  defp parse_int_or_nil(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp severity_badge_class("debug"),
    do: "bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-300"

  defp severity_badge_class("info"),
    do: "bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-300"

  defp severity_badge_class("warning"),
    do: "bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300"

  defp severity_badge_class("error"),
    do: "bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300"

  defp severity_badge_class("critical"),
    do: "bg-red-200 text-red-900 dark:bg-red-800 dark:text-red-100"

  defp severity_badge_class(_), do: "bg-gray-100 text-gray-800"

  defp category_badge_class("provisioning"),
    do: "bg-purple-100 text-purple-800 dark:bg-purple-900/30 dark:text-purple-300"

  defp category_badge_class("lifecycle"),
    do: "bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300"

  defp category_badge_class("auto_shutdown"),
    do: "bg-orange-100 text-orange-800 dark:bg-orange-900/30 dark:text-orange-300"

  defp category_badge_class("health"),
    do: "bg-cyan-100 text-cyan-800 dark:bg-cyan-900/30 dark:text-cyan-300"

  defp category_badge_class("cron"),
    do: "bg-indigo-100 text-indigo-800 dark:bg-indigo-900/30 dark:text-indigo-300"

  defp category_badge_class("error"),
    do: "bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300"

  defp category_badge_class(_),
    do: "bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-300"

  defp session_status_class("ready"),
    do: "bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300"

  defp session_status_class("running"),
    do: "bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300"

  defp session_status_class("provisioning"),
    do: "bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-300"

  defp session_status_class("booting"),
    do: "bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-300"

  defp session_status_class("destroyed"),
    do: "bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-300"

  defp session_status_class("failed"),
    do: "bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300"

  defp session_status_class(_),
    do: "bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-300"

  defp format_datetime(nil), do: "-"
  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp format_datetime_short(nil), do: "-"
  defp format_datetime_short(dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp format_cost(nil), do: "-"
  defp format_cost(decimal), do: "$#{Decimal.round(decimal, 4)}"

  defp format_duration(nil, nil), do: "-"
  defp format_duration(start, nil), do: format_duration(start, DateTime.utc_now())

  defp format_duration(start, finish) do
    seconds = DateTime.diff(finish, start, :second)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <!-- Header -->
      <div class="flex items-center justify-between">
        <div>
          <div class="flex items-center gap-3 mb-1">
            <.link
              navigate={~p"/admin/vast_ai"}
              class="text-sm text-blue-600 hover:text-blue-800 dark:text-blue-400"
            >
              &larr; Back to Vast.ai
            </.link>
          </div>
          <h1 class="text-3xl font-bold text-gray-900 dark:text-gray-100">GPU Event History</h1>
          <p class="mt-2 text-sm text-gray-600 dark:text-gray-300">
            Comprehensive audit trail for GPU instance lifecycle events
          </p>
        </div>
        <button
          type="button"
          phx-click="refresh"
          disabled={@loading}
          class="px-4 py-2 text-sm font-medium text-gray-700 dark:text-gray-200 bg-white dark:bg-gray-700 border border-gray-300 dark:border-gray-600 rounded-md hover:bg-gray-50 dark:hover:bg-gray-600 disabled:opacity-50"
        >
          {if @loading, do: "Loading...", else: "Refresh"}
        </button>
      </div>
      
    <!-- Stats Cards -->
      <%= if @stats do %>
        <div class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-6 gap-4">
          <div class="bg-white dark:bg-gray-800 rounded-lg p-4 shadow-sm">
            <div class="text-sm text-gray-500 dark:text-gray-400">Active Instance</div>
            <div class="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">
              {if @stats.active_instance, do: "Yes", else: "No"}
            </div>
          </div>
          <div class="bg-white dark:bg-gray-800 rounded-lg p-4 shadow-sm">
            <div class="text-sm text-gray-500 dark:text-gray-400">Events (24h)</div>
            <div class="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">
              {@stats.events_24h}
            </div>
          </div>
          <div class="bg-white dark:bg-gray-800 rounded-lg p-4 shadow-sm">
            <div class="text-sm text-gray-500 dark:text-gray-400">Errors (24h)</div>
            <div class={[
              "mt-1 text-2xl font-semibold",
              if(@stats.errors_24h > 0, do: "text-red-600", else: "text-gray-900 dark:text-gray-100")
            ]}>
              {@stats.errors_24h}
            </div>
          </div>
          <div class="bg-white dark:bg-gray-800 rounded-lg p-4 shadow-sm">
            <div class="text-sm text-gray-500 dark:text-gray-400">Sessions (7d)</div>
            <div class="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">
              {@stats.sessions_7d}
            </div>
          </div>
          <div class="bg-white dark:bg-gray-800 rounded-lg p-4 shadow-sm">
            <div class="text-sm text-gray-500 dark:text-gray-400">Cost (30d)</div>
            <div class="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">
              {format_cost(@stats.cost_30d)}
            </div>
          </div>
          <div class="bg-white dark:bg-gray-800 rounded-lg p-4 shadow-sm">
            <div class="text-sm text-gray-500 dark:text-gray-400">Runtime (30d)</div>
            <div class="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">
              {@stats.runtime_30d} min
            </div>
          </div>
        </div>
      <% end %>
      
    <!-- View Tabs -->
      <div class="border-b border-gray-200 dark:border-gray-700">
        <nav class="-mb-px flex space-x-8">
          <button
            type="button"
            phx-click="switch_view"
            phx-value-view="events"
            class={[
              "py-4 px-1 border-b-2 font-medium text-sm",
              if(@view_mode == :events,
                do: "border-blue-500 text-blue-600 dark:text-blue-400",
                else:
                  "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300 dark:text-gray-400"
              )
            ]}
          >
            Events
          </button>
          <button
            type="button"
            phx-click="switch_view"
            phx-value-view="sessions"
            class={[
              "py-4 px-1 border-b-2 font-medium text-sm",
              if(@view_mode == :sessions,
                do: "border-blue-500 text-blue-600 dark:text-blue-400",
                else:
                  "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300 dark:text-gray-400"
              )
            ]}
          >
            Sessions
          </button>
        </nav>
      </div>
      
    <!-- Session Detail View -->
      <%= if @view_mode == :session_detail && @selected_session do %>
        <div class="bg-white dark:bg-gray-800 rounded-lg shadow-sm p-6">
          <div class="flex items-center justify-between mb-6">
            <button
              type="button"
              phx-click="back_to_list"
              class="text-sm text-blue-600 hover:text-blue-800 dark:text-blue-400"
            >
              &larr; Back to list
            </button>
            <span class={[
              "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium",
              session_status_class(@selected_session.status)
            ]}>
              {@selected_session.status}
            </span>
          </div>

          <div class="grid md:grid-cols-2 gap-6">
            <div>
              <h3 class="text-lg font-semibold text-gray-900 dark:text-gray-100 mb-4">
                Session Details
              </h3>
              <dl class="space-y-2 text-sm">
                <div class="flex justify-between">
                  <dt class="text-gray-500 dark:text-gray-400">Instance ID</dt>
                  <dd class="font-mono text-gray-900 dark:text-gray-100">
                    {@selected_session.instance_id || "-"}
                  </dd>
                </div>
                <div class="flex justify-between">
                  <dt class="text-gray-500 dark:text-gray-400">GPU</dt>
                  <dd class="text-gray-900 dark:text-gray-100">
                    {@selected_session.gpu_name || "-"}
                  </dd>
                </div>
                <div class="flex justify-between">
                  <dt class="text-gray-500 dark:text-gray-400">Location</dt>
                  <dd class="text-gray-900 dark:text-gray-100">
                    {@selected_session.geolocation || "-"}
                  </dd>
                </div>
                <div class="flex justify-between">
                  <dt class="text-gray-500 dark:text-gray-400">Endpoint</dt>
                  <dd class="font-mono text-xs text-gray-900 dark:text-gray-100">
                    {@selected_session.endpoint || "-"}
                  </dd>
                </div>
                <div class="flex justify-between">
                  <dt class="text-gray-500 dark:text-gray-400">Hourly Cost</dt>
                  <dd class="text-gray-900 dark:text-gray-100">
                    {format_cost(@selected_session.hourly_cost)}
                  </dd>
                </div>
                <div class="flex justify-between">
                  <dt class="text-gray-500 dark:text-gray-400">Total Cost</dt>
                  <dd class="font-semibold text-gray-900 dark:text-gray-100">
                    {format_cost(@selected_session.total_cost)}
                  </dd>
                </div>
              </dl>
            </div>

            <div>
              <h3 class="text-lg font-semibold text-gray-900 dark:text-gray-100 mb-4">Timeline</h3>
              <dl class="space-y-2 text-sm">
                <div class="flex justify-between">
                  <dt class="text-gray-500 dark:text-gray-400">Created</dt>
                  <dd class="font-mono text-gray-900 dark:text-gray-100">
                    {format_datetime(@selected_session.inserted_at)}
                  </dd>
                </div>
                <div class="flex justify-between">
                  <dt class="text-gray-500 dark:text-gray-400">Provisioned</dt>
                  <dd class="font-mono text-gray-900 dark:text-gray-100">
                    {format_datetime(@selected_session.provisioned_at)}
                  </dd>
                </div>
                <div class="flex justify-between">
                  <dt class="text-gray-500 dark:text-gray-400">Ready</dt>
                  <dd class="font-mono text-gray-900 dark:text-gray-100">
                    {format_datetime(@selected_session.ready_at)}
                  </dd>
                </div>
                <div class="flex justify-between">
                  <dt class="text-gray-500 dark:text-gray-400">Destroyed</dt>
                  <dd class="font-mono text-gray-900 dark:text-gray-100">
                    {format_datetime(@selected_session.destroyed_at)}
                  </dd>
                </div>
                <div class="flex justify-between">
                  <dt class="text-gray-500 dark:text-gray-400">Destroy Reason</dt>
                  <dd class="text-gray-900 dark:text-gray-100">
                    {@selected_session.destroy_reason || "-"}
                  </dd>
                </div>
                <div class="flex justify-between">
                  <dt class="text-gray-500 dark:text-gray-400">Duration</dt>
                  <dd class="font-semibold text-gray-900 dark:text-gray-100">
                    {format_duration(@selected_session.provisioned_at, @selected_session.destroyed_at)}
                  </dd>
                </div>
              </dl>
            </div>
          </div>
          
    <!-- Session Events -->
          <%= if assigns[:session_events] && @session_events != [] do %>
            <div class="mt-6 border-t border-gray-200 dark:border-gray-700 pt-6">
              <h3 class="text-lg font-semibold text-gray-900 dark:text-gray-100 mb-4">
                Session Events ({length(@session_events)})
              </h3>
              <div class="space-y-2 max-h-96 overflow-y-auto">
                <%= for event <- @session_events do %>
                  <div class="flex items-start gap-3 text-sm p-2 bg-gray-50 dark:bg-gray-700 rounded">
                    <span class="font-mono text-xs text-gray-500 dark:text-gray-400 whitespace-nowrap">
                      {format_datetime_short(event.inserted_at)}
                    </span>
                    <span class={[
                      "inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium",
                      severity_badge_class(event.severity)
                    ]}>
                      {event.severity}
                    </span>
                    <span class={[
                      "inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium",
                      category_badge_class(event.event_category)
                    ]}>
                      {event.event_category}
                    </span>
                    <span class="text-gray-900 dark:text-gray-100 flex-1">{event.message}</span>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
      
    <!-- Events View -->
      <%= if @view_mode == :events do %>
        <!-- Filters -->
        <div class="bg-white dark:bg-gray-800 rounded-lg shadow-sm p-4">
          <.form for={%{}} phx-change="filter" class="flex flex-wrap gap-4 items-end">
            <div>
              <label class="block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1">
                Category
              </label>
              <select
                name="category"
                class="rounded-md border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 text-sm"
              >
                <option value="">All</option>
                <option value="provisioning" selected={@filters.category == "provisioning"}>
                  Provisioning
                </option>
                <option value="lifecycle" selected={@filters.category == "lifecycle"}>
                  Lifecycle
                </option>
                <option value="auto_shutdown" selected={@filters.category == "auto_shutdown"}>
                  Auto-Shutdown
                </option>
                <option value="health" selected={@filters.category == "health"}>Health</option>
                <option value="cron" selected={@filters.category == "cron"}>Cron</option>
                <option value="error" selected={@filters.category == "error"}>Error</option>
              </select>
            </div>
            <div>
              <label class="block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1">
                Severity
              </label>
              <select
                name="severity"
                class="rounded-md border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 text-sm"
              >
                <option value="">All</option>
                <option value="debug" selected={@filters.severity == "debug"}>Debug</option>
                <option value="info" selected={@filters.severity == "info"}>Info</option>
                <option value="warning" selected={@filters.severity == "warning"}>Warning</option>
                <option value="error" selected={@filters.severity == "error"}>Error</option>
                <option value="critical" selected={@filters.severity == "critical"}>Critical</option>
              </select>
            </div>
            <div>
              <label class="block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1">
                Instance ID
              </label>
              <input
                type="text"
                name="instance_id"
                value={@filters.instance_id}
                placeholder="e.g. 12345"
                class="w-28 rounded-md border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 text-sm"
              />
            </div>
            <div>
              <label class="block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1">
                Time Range
              </label>
              <select
                name="hours"
                class="rounded-md border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 text-sm"
              >
                <option value="1" selected={@filters.hours == 1}>Last 1 hour</option>
                <option value="6" selected={@filters.hours == 6}>Last 6 hours</option>
                <option value="24" selected={@filters.hours == 24}>Last 24 hours</option>
                <option value="168" selected={@filters.hours == 168}>Last 7 days</option>
                <option value="720" selected={@filters.hours == 720}>Last 30 days</option>
              </select>
            </div>
          </.form>
        </div>
        
    <!-- Events Table -->
        <div class="bg-white dark:bg-gray-800 rounded-lg shadow-sm overflow-hidden">
          <div class="overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
              <thead class="bg-gray-50 dark:bg-gray-700">
                <tr>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                    Time
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                    Severity
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                    Category
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                    Type
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                    Instance
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                    Message
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody class="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                <%= if @events == [] do %>
                  <tr>
                    <td colspan="7" class="px-4 py-8 text-center text-gray-500 dark:text-gray-400">
                      No events found. GPU events will appear here when instances are provisioned or destroyed.
                    </td>
                  </tr>
                <% else %>
                  <%= for event <- @events do %>
                    <tr class="hover:bg-gray-50 dark:hover:bg-gray-700">
                      <td class="px-4 py-3 whitespace-nowrap text-xs font-mono text-gray-500 dark:text-gray-400">
                        {format_datetime_short(event.inserted_at)}
                      </td>
                      <td class="px-4 py-3 whitespace-nowrap">
                        <span class={[
                          "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
                          severity_badge_class(event.severity)
                        ]}>
                          {event.severity}
                        </span>
                      </td>
                      <td class="px-4 py-3 whitespace-nowrap">
                        <span class={[
                          "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
                          category_badge_class(event.event_category)
                        ]}>
                          {event.event_category}
                        </span>
                      </td>
                      <td class="px-4 py-3 whitespace-nowrap text-sm text-gray-900 dark:text-gray-100">
                        {event.event_type}
                      </td>
                      <td class="px-4 py-3 whitespace-nowrap text-sm font-mono text-gray-900 dark:text-gray-100">
                        {event.instance_id || "-"}
                      </td>
                      <td
                        class="px-4 py-3 text-sm text-gray-900 dark:text-gray-100 max-w-md truncate"
                        title={event.message}
                      >
                        {event.message}
                      </td>
                      <td class="px-4 py-3 whitespace-nowrap">
                        <%= if event.correlation_id do %>
                          <button
                            type="button"
                            phx-click="view_correlation"
                            phx-value-id={event.correlation_id}
                            class="text-xs text-blue-600 hover:text-blue-800 dark:text-blue-400"
                          >
                            View Related
                          </button>
                        <% end %>
                      </td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      <% end %>
      
    <!-- Sessions View -->
      <%= if @view_mode == :sessions do %>
        <div class="bg-white dark:bg-gray-800 rounded-lg shadow-sm overflow-hidden">
          <div class="overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
              <thead class="bg-gray-50 dark:bg-gray-700">
                <tr>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                    Created
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                    Status
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                    Instance
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                    GPU
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                    Location
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                    Duration
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                    Cost
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                    Destroy Reason
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase">
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody class="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                <%= if @sessions == [] do %>
                  <tr>
                    <td colspan="9" class="px-4 py-8 text-center text-gray-500 dark:text-gray-400">
                      No sessions yet. Sessions are created when GPU instances are provisioned.
                    </td>
                  </tr>
                <% else %>
                  <%= for session <- @sessions do %>
                    <tr class="hover:bg-gray-50 dark:hover:bg-gray-700">
                      <td class="px-4 py-3 whitespace-nowrap text-xs font-mono text-gray-500 dark:text-gray-400">
                        {format_datetime(session.inserted_at)}
                      </td>
                      <td class="px-4 py-3 whitespace-nowrap">
                        <span class={[
                          "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
                          session_status_class(session.status)
                        ]}>
                          {session.status}
                        </span>
                      </td>
                      <td class="px-4 py-3 whitespace-nowrap text-sm font-mono text-gray-900 dark:text-gray-100">
                        {session.instance_id || "-"}
                      </td>
                      <td class="px-4 py-3 whitespace-nowrap text-sm text-gray-900 dark:text-gray-100">
                        {session.gpu_name || "-"}
                      </td>
                      <td class="px-4 py-3 whitespace-nowrap text-sm text-gray-900 dark:text-gray-100">
                        {session.geolocation || "-"}
                      </td>
                      <td class="px-4 py-3 whitespace-nowrap text-sm text-gray-900 dark:text-gray-100">
                        {format_duration(session.provisioned_at, session.destroyed_at)}
                      </td>
                      <td class="px-4 py-3 whitespace-nowrap text-sm font-mono text-gray-900 dark:text-gray-100">
                        {format_cost(session.total_cost)}
                      </td>
                      <td class="px-4 py-3 whitespace-nowrap text-sm text-gray-900 dark:text-gray-100">
                        {session.destroy_reason || "-"}
                      </td>
                      <td class="px-4 py-3 whitespace-nowrap">
                        <button
                          type="button"
                          phx-click="view_session"
                          phx-value-id={session.id}
                          class="text-xs text-blue-600 hover:text-blue-800 dark:text-blue-400"
                        >
                          Details
                        </button>
                      </td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      <% end %>
      
    <!-- Correlation View -->
      <%= if @view_mode == :correlation && assigns[:correlated_events] do %>
        <div class="bg-white dark:bg-gray-800 rounded-lg shadow-sm p-6">
          <div class="flex items-center justify-between mb-6">
            <button
              type="button"
              phx-click="switch_view"
              phx-value-view="events"
              class="text-sm text-blue-600 hover:text-blue-800 dark:text-blue-400"
            >
              &larr; Back to events
            </button>
            <h3 class="text-lg font-semibold text-gray-900 dark:text-gray-100">
              Correlated Events ({length(@correlated_events)})
            </h3>
          </div>

          <div class="space-y-2">
            <%= for event <- @correlated_events do %>
              <div class="flex items-start gap-3 text-sm p-3 bg-gray-50 dark:bg-gray-700 rounded-lg">
                <span class="font-mono text-xs text-gray-500 dark:text-gray-400 whitespace-nowrap">
                  {format_datetime(event.inserted_at)}
                </span>
                <span class={[
                  "inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium",
                  severity_badge_class(event.severity)
                ]}>
                  {event.severity}
                </span>
                <span class={[
                  "inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium",
                  category_badge_class(event.event_category)
                ]}>
                  {event.event_category}
                </span>
                <span class="text-xs text-gray-600 dark:text-gray-300">
                  {event.event_type}
                </span>
                <span class="text-gray-900 dark:text-gray-100 flex-1">{event.message}</span>
                <%= if event.instance_id do %>
                  <span class="font-mono text-xs text-gray-500">#{event.instance_id}</span>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
