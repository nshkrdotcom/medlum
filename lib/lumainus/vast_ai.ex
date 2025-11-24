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

    filters =
      Offers.build_filters(
        gpu_name: "RTX 3090",
        num_gpus: 1,
        verified: true,
        rentable: true,
        geolocation: Keyword.get(opts, :geolocation, ["US", "CA"]),
        dph_total: {:lte, max_price}
      )

    with {:ok, offer} <- Offers.cheapest(filters: filters),
         true <- offer["dph_total"] <= max_price || {:error, :price_too_high},
         {:ok, resp} <-
           Instances.create(offer["id"], %{
             image: Keyword.get(opts, :image, @default_image),
             disk: disk_gb,
             label: label,
             onstart: onstart,
             runtype: "ssh"
           }),
         %{"new_contract" => instance_id} <- resp do
      {:ok, instance_id}
    end
  end

  def wait_for_ready(instance_id, timeout_ms \\ 300_000),
    do: Instances.wait_for_ready(instance_id, timeout_ms)

  def destroy(instance_id), do: Instances.destroy(instance_id)

  def start(instance_id), do: Instances.start(instance_id)

  def stop(instance_id), do: Instances.stop(instance_id)

  def status(instance_id), do: Instances.get(instance_id)
end
