defmodule LumainusWeb.Admin.DoclingSettingsLive do
  @moduledoc """
  Admin interface for configuring Docling backends.

  ## Backend Architecture

  There are 5 backends organized into two user-facing modes:

  ### Local Mode (free) - admin selects one via `active_local_backend`
  - `native_cpu` (port 8040) - Host Python/uvicorn, CPU only
  - `native_gpu` (port 8041) - Host Python/uvicorn, with CUDA
  - `docker_cpu` (port 8042) - Docker container, CPU mode
  - `docker_gpu` (port 8043) - Docker container, GPU mode

  ### Cloud Mode ($$$)
  - `vast_ai` (port 8044) - Vast.ai remote GPU

  Users choose between "Local" and "Cloud". This page configures the system defaults
  and which local backend is active.
  """

  use LumainusWeb, :live_view

  require Logger

  alias Lumainus.Docling.Settings
  alias Lumainus.Conversion.Infrastructure.HealthManager

  @backends [
    {:native_cpu, "Native CPU", "8040", false},
    {:native_gpu, "Native GPU", "8041", true},
    {:docker_cpu, "Docker CPU", "8042", false},
    {:docker_gpu, "Docker GPU", "8043", true},
    {:vast_ai, "Cloud (Vast.ai)", "8044", true}
  ]

  alias Lumainus.Docling.VastAI.InstanceManager

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to GPU status changes for live updates
    if connected?(socket) do
      InstanceManager.subscribe()
    end

    {:ok,
     socket
     |> assign_settings()
     |> assign_all_health()}
  end

  # Handle GPU status changes from InstanceManager
  @impl true
  def handle_info({:gpu_status_changed, _status_map}, socket) do
    # Re-derive health from current state (instant, no HTTP)
    {:noreply, assign_all_health(socket)}
  end

  @impl true
  def handle_event("save", %{"setting" => params}, socket) do
    case Settings.update_settings(params) do
      {:ok, _setting} ->
        {:noreply,
         socket
         |> put_flash(:info, "Docling configuration updated")
         |> assign_settings()
         |> assign_all_health()}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("refresh_health", _params, socket) do
    {:noreply, assign_all_health(socket)}
  end

  defp assign_settings(socket) do
    {:ok, setting} = Settings.fetch_or_init()
    changeset = Settings.change_settings(%{})
    assign(socket, changeset: changeset, form: to_form(changeset), setting: setting)
  end

  defp assign_all_health(socket) do
    health_map =
      @backends
      |> Enum.map(fn {backend, _name, _port, _gpu} ->
        {backend, check_backend_health(backend)}
      end)
      |> Map.new()

    assign(socket, health: health_map)
  end

  # For vast_ai, use InstanceManager state instead of HTTP health check
  # The state machine handles periodic health checks in the background
  # Uses 200ms timeout to avoid blocking if InstanceManager is stuck on SSH
  defp check_backend_health(:vast_ai) do
    alias Lumainus.Docling.VastAI.InstanceManager

    if Process.whereis(InstanceManager) do
      status =
        try do
          GenServer.call(InstanceManager, :status, 200)
        catch
          :exit, {:timeout, _} ->
            %{status: :timeout, error: "InstanceManager blocked"}

          :exit, _ ->
            %{status: :error, error: "InstanceManager unavailable"}
        end

      case status do
        %{status: :running, healthy: true, endpoint: endpoint} ->
          %{status: "healthy", details: %{endpoint: endpoint, source: "state_machine"}}

        %{status: :running, healthy: false, health_check_error: error} ->
          %{
            status: "unreachable",
            details: %{error: error || "Health check failed", endpoint: status.endpoint}
          }

        %{status: :running, healthy: nil, endpoint: endpoint} ->
          # Not yet checked - show as checking
          %{
            status: "checking",
            details: %{endpoint: endpoint, message: "Health check pending..."}
          }

        %{status: :loading} ->
          %{status: "loading", details: %{message: "Instance starting up..."}}

        %{status: :stopped, instance_id: id} when not is_nil(id) ->
          %{status: "stopped", details: %{instance_id: id, message: "Instance stopped"}}

        %{status: :none} ->
          {:ok, settings} = Settings.fetch_or_init()

          case settings.cloud_url do
            nil ->
              %{
                status: "unconfigured",
                details: %{error: "No instance and no cloud URL configured"}
              }

            "" ->
              %{
                status: "unconfigured",
                details: %{error: "No instance and no cloud URL configured"}
              }

            _url ->
              %{status: "no_instance", details: %{message: "No active instance"}}
          end

        %{status: :timeout, error: error} ->
          %{
            status: "blocked",
            details: %{error: error, message: "InstanceManager busy (SSH timeout?)"}
          }

        %{status: :error, error: error} ->
          %{status: "error", details: %{error: error}}

        _ ->
          %{status: "unknown", details: %{}}
      end
    else
      %{status: "error", details: %{error: "InstanceManager not running"}}
    end
  end

  defp check_backend_health(backend) do
    # Use v2 HealthManager for health checks
    if Process.whereis(HealthManager) do
      check_backend_health_v2(backend)
    else
      %{status: "unavailable", details: %{error: "HealthManager not running"}}
    end
  end

  # v2 HealthManager-based health check
  defp check_backend_health_v2(backend) do
    v2_name = v2_backend_name(backend)
    status = HealthManager.status(v2_name)
    latency = HealthManager.latency(v2_name)
    health_status_from_v2(status, latency)
  end

  defp health_status_from_v2(:healthy, latency_ms) do
    %{
      status: "healthy",
      details: %{latency_ms: latency_ms, source: "v2_health_manager"}
    }
  end

  defp health_status_from_v2(:unhealthy, _latency) do
    %{
      status: "unreachable",
      details: %{error: "Backend unhealthy", source: "v2_health_manager"}
    }
  end

  defp health_status_from_v2(:unknown, _latency) do
    %{
      status: "checking",
      details: %{message: "Health check pending...", source: "v2_health_manager"}
    }
  end

  # Map UI backend names to v2 HealthManager backend names
  defp v2_backend_name(:native_cpu), do: :local_cpu
  defp v2_backend_name(:native_gpu), do: :local_gpu
  defp v2_backend_name(:vast_ai), do: :cloud
  defp v2_backend_name(backend), do: backend

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-6 max-w-6xl mx-auto">
      <div>
        <h1 class="text-3xl font-bold text-gray-900 dark:text-gray-100">Docling Configuration</h1>
        <p class="mt-2 text-sm text-gray-600 dark:text-gray-300">
          Configure Docling PDF processing backends. Users choose between "Local" (free) and "Cloud" ($$$).
          You control which local backend is active and the URLs for each.
        </p>
      </div>

      <%!-- Health Status Grid --%>
      <div class="bg-white dark:bg-gray-800 shadow-sm rounded-lg p-4">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-lg font-semibold text-gray-900 dark:text-gray-100">Backend Health</h2>
          <button
            type="button"
            phx-click="refresh_health"
            class="text-sm text-blue-600 hover:text-blue-800"
          >
            Refresh
          </button>
        </div>
        <div class="grid gap-3 md:grid-cols-5">
          <%= for {backend, name, port, gpu} <- backends() do %>
            <.health_card
              backend={backend}
              name={name}
              port={port}
              gpu={gpu}
              health={@health[backend]}
              active={is_active_backend?(backend, @setting)}
            />
          <% end %>
        </div>
      </div>

      <%!-- Settings Form --%>
      <div class="bg-white dark:bg-gray-800 shadow-sm rounded-lg p-6">
        <h2 class="text-xl font-semibold mb-4 text-gray-900 dark:text-gray-100">Runtime Settings</h2>
        <.form for={@form} id="docling-settings" phx-submit="save" class="space-y-6">
          <%!-- Mode & Backend Selection --%>
          <div class="grid gap-4 md:grid-cols-2">
            <.input
              type="select"
              field={@form[:default_mode]}
              label="Default mode for new users"
              options={[
                {"Local (free)", "local"},
                {"Cloud ($$$)", "cloud"}
              ]}
            />

            <.input
              type="select"
              field={@form[:active_local_backend]}
              label="Active local backend"
              options={[
                {"Native CPU (port 8040)", "native_cpu"},
                {"Native GPU (port 8041)", "native_gpu"},
                {"Docker CPU (port 8042)", "docker_cpu"},
                {"Docker GPU (port 8043)", "docker_gpu"},
                {"Cloud / Vast.ai (port 8044)", "vast_ai"}
              ]}
            />
          </div>

          <%!-- Local Backend URLs --%>
          <div>
            <h3 class="text-md font-medium text-gray-700 dark:text-gray-200 mb-3">
              Local Backend URLs
            </h3>
            <div class="grid gap-4 md:grid-cols-2">
              <.input
                type="text"
                field={@form[:native_cpu_url]}
                label="Native CPU (port 8040)"
                placeholder="http://127.0.0.1:8040"
                inputmode="url"
              />
              <.input
                type="text"
                field={@form[:native_gpu_url]}
                label="Native GPU (port 8041)"
                placeholder="http://127.0.0.1:8041"
                inputmode="url"
              />
              <.input
                type="text"
                field={@form[:docker_cpu_url]}
                label="Docker CPU (port 8042)"
                placeholder="http://127.0.0.1:8042"
                inputmode="url"
              />
              <.input
                type="text"
                field={@form[:docker_gpu_url]}
                label="Docker GPU (port 8043)"
                placeholder="http://127.0.0.1:8043"
                inputmode="url"
              />
            </div>
          </div>

          <%!-- Cloud Backend URL --%>
          <div>
            <h3 class="text-md font-medium text-gray-700 dark:text-gray-200 mb-3">
              Cloud Backend URL
            </h3>
            <.input
              type="text"
              field={@form[:cloud_url]}
              label="Vast.ai / Cloud GPU (port 8044)"
              placeholder="https://your-vast-instance:8044"
              inputmode="url"
            />
            <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">
              Set via Vast.ai provisioning or manually. Must use HTTPS for non-localhost.
            </p>
          </div>

          <%!-- Timing Settings --%>
          <div>
            <h3 class="text-md font-medium text-gray-700 dark:text-gray-200 mb-3">Timing</h3>
            <div class="grid gap-4 md:grid-cols-3">
              <.input
                type="number"
                field={@form[:timeout_ms]}
                label="Timeout (ms)"
                min="1"
              />
              <.input
                type="number"
                field={@form[:poll_interval_ms]}
                label="Poll interval (ms)"
                min="50"
              />
              <.input
                type="number"
                field={@form[:progress_min_interval_ms]}
                label="Progress debounce (ms)"
                min="0"
              />
            </div>
          </div>

          <%!-- Submit --%>
          <div class="flex items-center gap-3 pt-4 border-t">
            <.button type="submit" class="btn btn-primary">Save Configuration</.button>
            <p class="text-xs text-slate-500 dark:text-slate-400">
              Changes apply immediately. Environment variables override these values in test mode.
            </p>
          </div>
        </.form>
      </div>

      <%!-- Port Reference --%>
      <div class="bg-gray-50 dark:bg-gray-700 rounded-lg p-4">
        <h3 class="text-sm font-medium text-gray-700 dark:text-gray-200 mb-2">Port Reference</h3>
        <div class="text-xs text-gray-600 dark:text-gray-300 font-mono grid grid-cols-2 md:grid-cols-5 gap-2">
          <div>8040: native_cpu</div>
          <div>8041: native_gpu</div>
          <div>8042: docker_cpu</div>
          <div>8043: docker_gpu</div>
          <div>8044: vast_ai</div>
        </div>
      </div>
    </div>
    """
  end

  defp health_card(assigns) do
    status = assigns.health[:status] || "unknown"

    color =
      case status do
        "healthy" ->
          "bg-green-100 dark:bg-green-900/30 border-green-300 dark:border-green-700 text-green-800 dark:text-green-200"

        "unreachable" ->
          "bg-red-100 dark:bg-red-900/30 border-red-300 dark:border-red-700 text-red-800 dark:text-red-200"

        "unconfigured" ->
          "bg-gray-100 dark:bg-gray-700 border-gray-300 dark:border-gray-600 text-gray-600 dark:text-gray-300"

        _ ->
          "bg-yellow-100 dark:bg-yellow-900/30 border-yellow-300 dark:border-yellow-700 text-yellow-800 dark:text-yellow-200"
      end

    active_ring = if assigns.active, do: "ring-2 ring-blue-500", else: ""

    assigns = assign(assigns, color: color, active_ring: active_ring, status: status)

    ~H"""
    <div class={"rounded-lg border p-3 #{@color} #{@active_ring}"}>
      <div class="flex items-center justify-between mb-1">
        <span class="text-xs font-medium">{@name}</span>
        <%= if @gpu do %>
          <span class="text-xs px-1 bg-purple-200 dark:bg-purple-900/50 text-purple-800 dark:text-purple-200 rounded">
            GPU
          </span>
        <% end %>
      </div>
      <div class="text-xs opacity-75">:{@port}</div>
      <div class="mt-2 flex items-center gap-1">
        <span class={"w-2 h-2 rounded-full #{status_dot_color(@status)}"}></span>
        <span class="text-xs capitalize">{@status}</span>
      </div>
      <%= if show_error?(@status, @health) do %>
        <div
          class="mt-1 text-[10px] leading-tight text-red-700 dark:text-red-300 line-clamp-2"
          title={error_full_text(@health)}
        >
          {error_summary(@health)}
        </div>
      <% end %>
      <%= if @active do %>
        <div class="mt-1 text-xs font-semibold text-blue-600 dark:text-blue-400">Active</div>
      <% end %>
    </div>
    """
  end

  defp status_dot_color("healthy"), do: "bg-green-500"
  defp status_dot_color("unreachable"), do: "bg-red-500"
  defp status_dot_color("unconfigured"), do: "bg-gray-400"
  defp status_dot_color(_), do: "bg-yellow-500"

  defp backends, do: @backends

  defp is_active_backend?(backend, setting) do
    active = setting.active_local_backend || "docker_cpu"
    to_string(backend) == active
  end

  defp friendly_transport_error(:timeout), do: "Connection timed out"
  defp friendly_transport_error(:closed), do: "Connection closed"
  defp friendly_transport_error(:econnrefused), do: "Connection refused"
  defp friendly_transport_error(:nxdomain), do: "DNS lookup failed"
  defp friendly_transport_error(other), do: "Network error: #{inspect(other)}"

  defp show_error?("healthy", _health), do: false
  defp show_error?("unconfigured", _health), do: false
  defp show_error?(_status, _health), do: true

  defp error_summary(%{details: %{error: "fallback_failed", detail: detail}}) do
    cond do
      # All attempts failed - service likely not running
      is_map(detail) and is_list(detail[:attempts]) ->
        failed_count = length(detail[:attempts])
        "Service unreachable (#{failed_count} endpoints tried)"

      # No IP available
      is_map(detail) and is_list(detail[:ip_attempts]) ->
        "Cannot resolve IP address"

      true ->
        "Fallback failed"
    end
  end

  defp error_summary(%{details: %{error: error}}) when is_binary(error) do
    error
  end

  defp error_summary(%{details: details}) when is_map(details) do
    inspect(details, limit: 50)
  end

  defp error_summary(_), do: "unreachable"

  defp error_full_text(%{details: %{detail: detail}}) when is_map(detail) do
    format_fallback_detail(detail)
  end

  defp error_full_text(%{details: details}) when is_map(details) do
    inspect(details, pretty: true, limit: 200)
  end

  defp error_full_text(_), do: ""

  defp format_fallback_detail(%{attempts: attempts} = detail) when is_list(attempts) do
    primary = detail[:primary_reason]
    attempt_lines = format_attempts(attempts)

    lines = []
    lines = if primary, do: ["Primary: #{inspect(primary)}" | lines], else: lines
    lines = if attempt_lines, do: ["Fallback attempts:\n#{attempt_lines}" | lines], else: lines
    Enum.join(lines, "\n")
  end

  defp format_fallback_detail(%{ip_attempts: ip_attempts}) when is_list(ip_attempts) do
    "IP resolution failed:\n" <>
      Enum.map_join(ip_attempts, "\n", fn
        %{source: src, error: err} -> "  #{src}: #{inspect(err)}"
        %{source: src, value: val} -> "  #{src}: #{val}"
        other -> "  #{inspect(other)}"
      end)
  end

  defp format_fallback_detail(detail), do: inspect(detail, pretty: true, limit: 200)

  defp format_attempts(nil), do: nil

  defp format_attempts(attempts) when is_list(attempts) do
    attempts
    |> Enum.map(fn
      %{url: url, result: :ok} ->
        "  #{url} -> OK"

      %{url: url, result: {:error, {:transport_error, reason}}} ->
        "  #{url} -> #{friendly_transport_error(reason)}"

      %{url: url, result: {:error, reason}} ->
        "  #{url} -> #{inspect(reason)}"

      %{url: url, result: res} ->
        "  #{url} -> #{inspect(res)}"

      other ->
        "  #{inspect(other)}"
    end)
    |> Enum.join("\n")
  end

  defp format_attempts(_), do: nil
end
