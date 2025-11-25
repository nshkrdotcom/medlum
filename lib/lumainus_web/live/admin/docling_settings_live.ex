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

  alias Lumainus.Docling
  alias Lumainus.Docling.Settings

  @backends [
    {:native_cpu, "Native CPU", "8040", false},
    {:native_gpu, "Native GPU", "8041", true},
    {:docker_cpu, "Docker CPU", "8042", false},
    {:docker_gpu, "Docker GPU", "8043", true},
    {:vast_ai, "Cloud (Vast.ai)", "8044", true}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_settings()
     |> assign_all_health()}
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

  defp check_backend_health(:vast_ai) do
    case Docling.config()[:cloud_url] do
      nil -> %{status: "unconfigured", details: %{error: "Cloud URL not set"}}
      "" -> %{status: "unconfigured", details: %{error: "Cloud URL not set"}}
      _url -> do_health_check(:vast_ai)
    end
  end

  defp check_backend_health(backend) do
    url_key = backend_url_key(backend)

    case Docling.config()[url_key] do
      nil -> %{status: "unconfigured", details: %{error: "URL not configured"}}
      "" -> %{status: "unconfigured", details: %{error: "URL not configured"}}
      _url -> do_health_check(backend)
    end
  end

  defp do_health_check(backend) do
    case Docling.health(backend: backend) do
      {:ok, details} -> %{status: "healthy", details: details}
      {:error, reason} -> %{status: "unreachable", details: %{error: inspect(reason)}}
    end
  rescue
    e -> %{status: "error", details: %{error: Exception.message(e)}}
  end

  defp backend_url_key(:native_cpu), do: :native_cpu_url
  defp backend_url_key(:native_gpu), do: :native_gpu_url
  defp backend_url_key(:docker_cpu), do: :docker_cpu_url
  defp backend_url_key(:docker_gpu), do: :docker_gpu_url
  defp backend_url_key(:vast_ai), do: :cloud_url
  defp backend_url_key(_), do: :local_url

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
end
