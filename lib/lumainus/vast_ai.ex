defmodule Lumainus.VastAI do
  @moduledoc """
  High-level Vast.ai operations (search, provision, destroy, status).
  """

  alias Lumainus.VastAI.{Instances, Offers}

  # Custom GPU image with docling pre-installed
  # See docling_service/DEPLOYMENT.md for build instructions
  @default_image "ghcr.io/nshkrdotcom/lumainus-docling-gpu:latest"

  def provision(opts \\ []) do
    max_price = Keyword.get(opts, :max_price, 0.18)
    disk_gb = Keyword.get(opts, :disk_gb, 16)
    label = Keyword.get(opts, :label, "docling-dev")
    onstart = Keyword.get(opts, :onstart)
    image = Keyword.get(opts, :image, @default_image)

    # For private registries (ghcr.io private packages)
    # Set GHCR_TOKEN env var or config :lumainus, :ghcr_token
    docker_login = Keyword.get(opts, :docker_login) || fetch_docker_login(image)

    filters =
      Offers.build_filters(
        gpu_name: "RTX 3090",
        num_gpus: 1,
        verified: true,
        rentable: true,
        geolocation: Keyword.get(opts, :geolocation, ["US", "CA"]),
        dph_total: {:lte, max_price}
      )

    create_params =
      %{
        image: image,
        disk: disk_gb,
        label: label,
        onstart: onstart,
        runtype: "ssh"
      }
      |> maybe_add_docker_login(docker_login)

    with {:ok, offer} <- Offers.cheapest(filters: filters),
         true <- offer["dph_total"] <= max_price || {:error, :price_too_high},
         {:ok, resp} <- Instances.create(offer["id"], create_params),
         %{"new_contract" => instance_id} <- resp do
      {:ok, instance_id}
    end
  end

  defp maybe_add_docker_login(params, nil), do: params

  defp maybe_add_docker_login(params, docker_login),
    do: Map.put(params, :docker_login, docker_login)

  defp fetch_docker_login(image) do
    # Only add docker_login for ghcr.io images
    if String.starts_with?(image, "ghcr.io/") do
      ghcr_user = Application.get_env(:lumainus, :ghcr_user) || "nshkrdotcom"

      ghcr_token =
        Application.get_env(:lumainus, :ghcr_token) ||
          System.get_env("GHCR_TOKEN")

      if ghcr_token do
        "#{ghcr_user}:#{ghcr_token}"
      else
        nil
      end
    else
      nil
    end
  end

  def wait_for_ready(instance_id, timeout_ms \\ 300_000),
    do: Instances.wait_for_ready(instance_id, timeout_ms)

  def destroy(instance_id), do: Instances.destroy(instance_id)

  def start(instance_id), do: Instances.start(instance_id)

  def stop(instance_id), do: Instances.stop(instance_id)

  def status(instance_id), do: Instances.get(instance_id)
end
