defmodule LumainusWeb.Admin.VastAILive do
  use LumainusWeb, :live_view

  alias Lumainus.VastAI.{Instances, Offers}

  @docling_image "ghcr.io/nshkrdotcom/lumainus-docling-gpu:latest"
  @pytorch_image "pytorch/pytorch:2.2.2-cuda12.1-cudnn8-runtime"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      send(self(), :load_data)
    end

    {:ok,
     socket
     |> assign(
       instances: [],
       offers: [],
       loading: true,
       provisioning: false,
       selected_offer: nil,
       error: nil,
       filters: default_filters(),
       selected_image: @docling_image,
       health_results: %{}
     )}
  end

  @impl true
  def handle_info(:load_data, socket) do
    socket =
      socket
      |> assign(loading: true)
      |> load_instances()
      |> assign(loading: false)

    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> assign(loading: true) |> load_instances() |> assign(loading: false)}
  end

  def handle_event("search_offers", params, socket) do
    filters = build_filters_from_params(params)

    socket =
      socket
      |> assign(filters: filters, loading: true)
      |> load_offers()
      |> assign(loading: false)

    {:noreply, socket}
  end

  def handle_event("select_image", %{"image" => image}, socket) do
    {:noreply, assign(socket, selected_image: image)}
  end

  def handle_event("provision", %{"offer_id" => offer_id}, socket) do
    offer_id = String.to_integer(offer_id)
    offer = Enum.find(socket.assigns.offers, &(&1["id"] == offer_id))

    if offer do
      socket = assign(socket, provisioning: true, error: nil)
      image = socket.assigns.selected_image

      create_params =
        %{
          image: image,
          disk: socket.assigns.filters.disk_gb,
          label: "lumainus-docling",
          runtype: "ssh"
        }
        |> maybe_add_docker_login(image)

      case Instances.create(offer_id, create_params) do
        {:ok, %{"new_contract" => instance_id}} ->
          {:noreply,
           socket
           |> put_flash(:info, "Instance #{instance_id} provisioned with #{short_image(image)}!")
           |> assign(provisioning: false, offers: [])
           |> load_instances()}

        {:ok, resp} ->
          {:noreply,
           socket
           |> put_flash(:info, "Provisioned: #{inspect(resp)}")
           |> assign(provisioning: false)
           |> load_instances()}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to provision: #{inspect(reason)}")
           |> assign(provisioning: false, error: reason)}
      end
    else
      {:noreply, put_flash(socket, :error, "Offer not found")}
    end
  end

  def handle_event("check_health", %{"id" => id, "ip" => ip}, socket) do
    instance_id = String.to_integer(id)
    url = "http://#{ip}:8042/health"

    result =
      case Req.get(url, receive_timeout: 10_000) do
        {:ok, %{status: 200, body: body}} -> {:ok, body}
        {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
        {:error, reason} -> {:error, inspect(reason)}
      end

    health_results = Map.put(socket.assigns.health_results, instance_id, result)
    {:noreply, assign(socket, health_results: health_results)}
  end

  def handle_event("start", %{"id" => id}, socket) do
    instance_id = String.to_integer(id)

    case Instances.start(instance_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Instance #{instance_id} starting...")
         |> load_instances()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
    end
  end

  def handle_event("stop", %{"id" => id}, socket) do
    instance_id = String.to_integer(id)

    case Instances.stop(instance_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Instance #{instance_id} stopping...")
         |> load_instances()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to stop: #{inspect(reason)}")}
    end
  end

  def handle_event("destroy", %{"id" => id}, socket) do
    instance_id = String.to_integer(id)

    case Instances.destroy(instance_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Instance #{instance_id} destroyed")
         |> load_instances()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to destroy: #{inspect(reason)}")}
    end
  end

  defp load_instances(socket) do
    case Instances.list() do
      {:ok, %{"instances" => instances}} ->
        assign(socket, instances: instances, error: nil)

      {:error, reason} ->
        assign(socket, instances: [], error: reason)
    end
  end

  defp load_offers(socket) do
    filters = socket.assigns.filters

    api_filters =
      Offers.build_filters(
        gpu_name: filters.gpu_name,
        num_gpus: filters.num_gpus,
        verified: true,
        rentable: true,
        geolocation: filters.geolocation,
        dph_total: {:lte, filters.max_price}
      )

    case Offers.search(filters: api_filters, limit: 10) do
      {:ok, %{"offers" => offers}} ->
        assign(socket, offers: offers, error: nil)

      {:error, reason} ->
        assign(socket, offers: [], error: reason)
    end
  end

  defp build_filters_from_params(params) do
    %{
      gpu_name: params["gpu_name"] || "RTX 3090",
      num_gpus: parse_int(params["num_gpus"], 1),
      max_price: parse_float(params["max_price"], 0.25),
      disk_gb: parse_int(params["disk_gb"], 16),
      geolocation: parse_geolocation(params["geolocation"])
    }
  end

  defp default_filters do
    %{
      gpu_name: "RTX 3090",
      num_gpus: 1,
      max_price: 0.25,
      disk_gb: 16,
      geolocation: ["US", "CA"]
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

  defp parse_float(nil, default), do: default
  defp parse_float("", default), do: default
  defp parse_float(val, _default) when is_float(val), do: val

  defp parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_geolocation(nil), do: ["US", "CA"]
  defp parse_geolocation(""), do: ["US", "CA"]

  defp parse_geolocation(val) when is_binary(val) do
    val |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_geolocation(val) when is_list(val), do: val

  defp short_image(image) do
    image |> String.split("/") |> List.last() |> String.split(":") |> hd()
  end

  defp docling_image, do: @docling_image
  defp pytorch_image, do: @pytorch_image

  # Add docker_login for private ghcr.io images
  defp maybe_add_docker_login(params, image) do
    if String.starts_with?(image, "ghcr.io/") do
      ghcr_user = Application.get_env(:lumainus, :ghcr_user) || "nshkrdotcom"
      ghcr_token = Application.get_env(:lumainus, :ghcr_token) || System.get_env("GHCR_TOKEN")

      if ghcr_token do
        Map.put(params, :docker_login, "#{ghcr_user}:#{ghcr_token}")
      else
        params
      end
    else
      params
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-3xl font-bold text-gray-900">Vast.ai GPU Instances</h1>
          <p class="mt-2 text-sm text-gray-600">
            Manage GPU instances for document processing
          </p>
        </div>
        <button
          type="button"
          phx-click="refresh"
          disabled={@loading}
          class="px-4 py-2 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-md hover:bg-gray-50 disabled:opacity-50"
        >
          {if @loading, do: "Loading...", else: "Refresh"}
        </button>
      </div>

      <%= if @error do %>
        <div class="bg-red-50 border border-red-200 rounded-lg p-4">
          <p class="text-sm text-red-800">Error: {@error |> inspect()}</p>
        </div>
      <% end %>
      
    <!-- Current Instances -->
      <div class="bg-white shadow-sm rounded-lg p-6">
        <h2 class="text-xl font-semibold mb-4">Active Instances ({length(@instances)})</h2>

        <%= if @instances == [] do %>
          <p class="text-center text-gray-500 py-8">
            No active instances. Search for offers below to provision one.
          </p>
        <% else %>
          <div class="space-y-4">
            <%= for instance <- @instances do %>
              <div class="border border-gray-200 rounded-lg p-4">
                <div class="flex items-start justify-between">
                  <div class="flex-1">
                    <div class="flex items-center gap-3 mb-2">
                      <span class="font-mono text-sm font-semibold">
                        #{instance["id"]}
                      </span>
                      <span class={status_badge_class(instance["actual_status"])}>
                        {instance["actual_status"] || "unknown"}
                      </span>
                      <span class="inline-flex items-center rounded-full bg-blue-100 px-2 py-1 text-xs font-medium text-blue-800">
                        {instance["gpu_name"]}
                      </span>
                    </div>

                    <div class="grid grid-cols-2 md:grid-cols-4 gap-4 text-sm text-gray-600">
                      <div>
                        <span class="font-medium">Location:</span>
                        {instance["geolocation"]}
                      </div>
                      <div>
                        <span class="font-medium">Cost:</span>
                        ${Float.round((instance["dph_total"] || 0) * 1.0, 3)}/hr
                      </div>
                      <div>
                        <span class="font-medium">GPU RAM:</span>
                        {div(instance["gpu_ram"] || 0, 1024)} GB
                      </div>
                      <div>
                        <span class="font-medium">Label:</span>
                        {instance["label"] || "—"}
                      </div>
                    </div>

                    <%= if instance["ssh_host"] do %>
                      <div class="mt-3 p-2 bg-gray-50 rounded text-xs font-mono">
                        ssh -p {instance["ssh_port"]} root@{instance["ssh_host"]}
                      </div>
                    <% end %>

                    <%= if instance["public_ipaddr"] && instance["actual_status"] == "running" do %>
                      <div class="mt-2 flex items-center gap-2">
                        <span class="text-xs text-gray-500">Docling endpoint:</span>
                        <code class="text-xs bg-blue-50 px-2 py-1 rounded">
                          http://{instance["public_ipaddr"]}:8042
                        </code>
                        <button
                          type="button"
                          phx-click="check_health"
                          phx-value-id={instance["id"]}
                          phx-value-ip={instance["public_ipaddr"]}
                          class="px-2 py-1 text-xs font-medium text-blue-700 bg-blue-100 rounded hover:bg-blue-200"
                        >
                          Test Health
                        </button>
                        <%= case @health_results[instance["id"]] do %>
                          <% {:ok, _} -> %>
                            <span class="text-xs text-green-600 font-medium">✓ Healthy</span>
                          <% {:error, err} -> %>
                            <span class="text-xs text-red-600 font-medium">✗ {err}</span>
                          <% nil -> %>
                        <% end %>
                      </div>
                    <% end %>
                  </div>

                  <div class="flex gap-2 ml-4">
                    <%= if instance["actual_status"] == "running" do %>
                      <button
                        type="button"
                        phx-click="stop"
                        phx-value-id={instance["id"]}
                        class="px-3 py-1 text-sm font-medium text-amber-700 bg-amber-100 rounded hover:bg-amber-200"
                      >
                        Stop
                      </button>
                    <% else %>
                      <button
                        type="button"
                        phx-click="start"
                        phx-value-id={instance["id"]}
                        class="px-3 py-1 text-sm font-medium text-green-700 bg-green-100 rounded hover:bg-green-200"
                      >
                        Start
                      </button>
                    <% end %>
                    <button
                      type="button"
                      phx-click="destroy"
                      phx-value-id={instance["id"]}
                      data-confirm={"Are you sure you want to destroy instance #{instance["id"]}? This cannot be undone."}
                      class="px-3 py-1 text-sm font-medium text-red-700 bg-red-100 rounded hover:bg-red-200"
                    >
                      Destroy
                    </button>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
      
    <!-- Search Offers -->
      <div class="bg-white shadow-sm rounded-lg p-6">
        <h2 class="text-xl font-semibold mb-4">Search GPU Offers</h2>

        <.form for={%{}} phx-submit="search_offers" class="grid gap-4 md:grid-cols-5 mb-6">
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">GPU Model</label>
            <select name="gpu_name" class="w-full rounded-md border-gray-300 text-sm">
              <option value="RTX 3090" selected={@filters.gpu_name == "RTX 3090"}>RTX 3090</option>
              <option value="RTX 4090" selected={@filters.gpu_name == "RTX 4090"}>RTX 4090</option>
              <option value="A100" selected={@filters.gpu_name == "A100"}>A100</option>
              <option value="H100" selected={@filters.gpu_name == "H100"}>H100</option>
            </select>
          </div>

          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1"># GPUs</label>
            <input
              type="number"
              name="num_gpus"
              value={@filters.num_gpus}
              min="1"
              max="8"
              class="w-full rounded-md border-gray-300 text-sm"
            />
          </div>

          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">Max $/hr</label>
            <input
              type="number"
              name="max_price"
              value={@filters.max_price}
              min="0.01"
              step="0.01"
              class="w-full rounded-md border-gray-300 text-sm"
            />
          </div>

          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">Disk (GB)</label>
            <input
              type="number"
              name="disk_gb"
              value={@filters.disk_gb}
              min="8"
              class="w-full rounded-md border-gray-300 text-sm"
            />
          </div>

          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">Region</label>
            <input
              type="text"
              name="geolocation"
              value={Enum.join(@filters.geolocation, ", ")}
              placeholder="US, CA"
              class="w-full rounded-md border-gray-300 text-sm"
            />
          </div>

          <div class="md:col-span-5 flex items-end gap-4">
            <button
              type="submit"
              disabled={@loading}
              class="px-4 py-2 text-sm font-medium text-white bg-blue-600 rounded-md hover:bg-blue-700 disabled:opacity-50"
            >
              {if @loading, do: "Searching...", else: "Search Offers"}
            </button>

            <div class="flex-1">
              <label class="block text-sm font-medium text-gray-700 mb-1">Docker Image</label>
              <select
                name="image"
                phx-change="select_image"
                class="w-full rounded-md border-gray-300 text-sm"
              >
                <option value={docling_image()} selected={@selected_image == docling_image()}>
                  Docling GPU (pre-built, ~3-5 min boot)
                </option>
                <option value={pytorch_image()} selected={@selected_image == pytorch_image()}>
                  PyTorch Base (needs manual setup)
                </option>
              </select>
            </div>
          </div>
        </.form>

        <%= if @offers != [] do %>
          <div class="border-t pt-4">
            <h3 class="text-lg font-medium mb-3">Available Offers ({length(@offers)})</h3>
            <div class="overflow-x-auto">
              <table class="min-w-full divide-y divide-gray-200">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      GPU
                    </th>
                    <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Location
                    </th>
                    <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      $/hr
                    </th>
                    <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      VRAM
                    </th>
                    <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Reliability
                    </th>
                    <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Action
                    </th>
                  </tr>
                </thead>
                <tbody class="bg-white divide-y divide-gray-200">
                  <%= for offer <- @offers do %>
                    <tr>
                      <td class="px-3 py-2 text-sm">{offer["gpu_name"]}</td>
                      <td class="px-3 py-2 text-sm">{offer["geolocation"]}</td>
                      <td class="px-3 py-2 text-sm font-mono">
                        ${Float.round((offer["dph_total"] || 0) * 1.0, 3)}
                      </td>
                      <td class="px-3 py-2 text-sm">{div(offer["gpu_ram"] || 0, 1024)} GB</td>
                      <td class="px-3 py-2 text-sm">
                        {Float.round((offer["reliability"] || 0) * 100, 1)}%
                      </td>
                      <td class="px-3 py-2">
                        <button
                          type="button"
                          phx-click="provision"
                          phx-value-offer_id={offer["id"]}
                          disabled={@provisioning}
                          class="px-3 py-1 text-sm font-medium text-white bg-green-600 rounded hover:bg-green-700 disabled:opacity-50"
                        >
                          {if @provisioning, do: "...", else: "Provision"}
                        </button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp status_badge_class("running") do
    "inline-flex items-center rounded-full bg-green-100 px-2 py-1 text-xs font-semibold text-green-800"
  end

  defp status_badge_class("loading") do
    "inline-flex items-center rounded-full bg-yellow-100 px-2 py-1 text-xs font-semibold text-yellow-800"
  end

  defp status_badge_class("exited") do
    "inline-flex items-center rounded-full bg-red-100 px-2 py-1 text-xs font-semibold text-red-800"
  end

  defp status_badge_class(_) do
    "inline-flex items-center rounded-full bg-gray-100 px-2 py-1 text-xs font-semibold text-gray-800"
  end
end
