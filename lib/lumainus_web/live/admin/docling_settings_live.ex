defmodule LumainusWeb.Admin.DoclingSettingsLive do
  use LumainusWeb, :live_view

  alias Lumainus.Docling
  alias Lumainus.Docling.Settings

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_settings()
     |> assign_health()}
  end

  @impl true
  def handle_event("save", %{"setting" => params}, socket) do
    case Settings.update_settings(params) do
      {:ok, _setting} ->
        {:noreply,
         socket
         |> put_flash(:info, "Docling configuration updated")
         |> assign_settings()
         |> assign_health()}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
    end
  end

  defp assign_settings(socket) do
    {:ok, setting} = Settings.fetch_or_init()
    changeset = Settings.change_settings(%{})
    assign(socket, changeset: changeset, form: to_form(changeset), setting: setting)
  end

  defp assign_health(socket) do
    assign(socket,
      local_health: health(:local),
      fast_health: health(:fast)
    )
  end

  defp health(:fast) do
    case Docling.config()[:remote_url] do
      nil ->
        %{status: "unconfigured", details: %{error: "Set remote_url to enable Fast mode"}}

      "" ->
        %{status: "unconfigured", details: %{error: "Set remote_url to enable Fast mode"}}

      _ ->
        case Docling.health(backend: :fast) do
          {:ok, details} -> %{status: "healthy", details: details}
          {:error, reason} -> %{status: "unreachable", details: %{error: inspect(reason)}}
        end
    end
  end

  defp health(:local) do
    case Docling.health(backend: :local) do
      {:ok, details} -> %{status: "healthy", details: details}
      {:error, reason} -> %{status: "unreachable", details: %{error: inspect(reason)}}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <div>
        <h1 class="text-3xl font-bold text-gray-900">Docling Configuration</h1>
        <p class="mt-2 text-sm text-gray-600">
          Configure the Standard (local) and Fast (GPU) Docling backends. Changes apply immediately for all users.
        </p>
        <p class="mt-1 text-xs text-amber-600">
          Environment variables still override these values in test or when `:prefer_env_overrides` is set.
        </p>
      </div>

      <div class="grid gap-4 md:grid-cols-2">
        {render_health_card("Standard (local)", @local_health)}
        {render_health_card("Fast (GPU)", @fast_health)}
      </div>

      <div class="bg-white shadow-sm rounded-lg p-6">
        <h2 class="text-xl font-semibold mb-4">Runtime settings</h2>
        <.form
          for={@form}
          id="docling-settings"
          phx-submit="save"
          class="grid gap-4 md:grid-cols-2"
        >
          <.input
            type="select"
            field={@form[:backend]}
            label="Default backend"
            options={[
              {"Standard (local)", "local"},
              {"Fast (GPU via remote)", "fast"},
              {"Remote (HTTP)", "remote"},
              {"Vast AI (provisioned)", "vast_ai"}
            ]}
          />

          <.input
            type="text"
            field={@form[:local_url]}
            label="Local Docling URL"
            placeholder="http://127.0.0.1:8042 (loopback only)"
            inputmode="url"
          />

          <.input
            type="text"
            field={@form[:remote_url]}
            label="Fast (GPU) Docling URL"
            placeholder="https://gpu-host:8042"
            inputmode="url"
            pattern="https://.*"
          />

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

          <div class="md:col-span-2 flex items-center gap-3">
            <.button type="submit" class="btn btn-primary">Save</.button>
            <p class="text-xs text-slate-500">
              Tip: Set <code>DOCLING_REMOTE_URL</code>
              before enabling Fast mode. Default backend applies when a user has not chosen a preference.
              Remote URLs must use https; http is only allowed for localhost/127.0.0.1.
            </p>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp render_health_card(title, %{status: status} = health) do
    color =
      case status do
        "healthy" -> "bg-green-100 text-green-800"
        "unreachable" -> "bg-red-100 text-red-800"
        _ -> "bg-gray-100 text-gray-800"
      end

    assigns = %{title: title, health: health, color: color}

    ~H"""
    <div class="bg-white shadow-sm rounded-lg p-4 space-y-2">
      <div class="flex items-center justify-between">
        <p class="text-sm font-medium text-slate-700">{@title}</p>
        <span class={"inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold #{@color}"}>
          {String.capitalize(@health.status)}
        </span>
      </div>
      <p class="text-xs text-slate-500">
        {health_message(@health)}
      </p>
    </div>
    """
  end

  defp health_message(%{status: "healthy", details: details}) do
    case details do
      %{"version" => version} -> "Responding (#{version})"
      _ -> "Responding"
    end
  end

  defp health_message(%{status: "unreachable", details: %{error: error}}),
    do: "Unreachable: #{error}"

  defp health_message(%{status: "unconfigured"}), do: "Remote URL not set"
  defp health_message(_), do: "Unknown"
end
