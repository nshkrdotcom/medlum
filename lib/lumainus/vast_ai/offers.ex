defmodule Lumainus.VastAI.Offers do
  @moduledoc """
  Offer search helpers.
  """

  alias Lumainus.VastAI.{Client, Search}

  def search(opts \\ []) do
    query = Keyword.get(opts, :query, default_query())
    order = Keyword.get(opts, :order, "dph_total")
    type = Keyword.get(opts, :type, "on-demand")
    storage = Keyword.get(opts, :storage, 10.0)
    disable_bundling = Keyword.get(opts, :disable_bundling, true)

    params =
      %{
        q: query,
        order: order,
        type: type,
        disk_space: storage,
        disable_bundling: disable_bundling
      }
      |> URI.encode_query()

    Client.get("/bundles/?#{params}", opts)
  end

  def cheapest(opts \\ []) do
    opts = Keyword.put_new(opts, :order, "dph_total")

    case search(opts) do
      {:ok, %{"offers" => [first | _]}} -> {:ok, first}
      {:ok, %{"offers" => []}} -> {:error, :no_offers}
      error -> error
    end
  end

  def default_query do
    Search.build_query(
      gpu_name: "RTX_3090",
      num_gpus: 1,
      verified: true,
      rentable: true
    )
  end
end
