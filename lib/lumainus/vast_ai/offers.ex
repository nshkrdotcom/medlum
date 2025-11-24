defmodule Lumainus.VastAI.Offers do
  @moduledoc """
  Offer search helpers.

  Uses POST /api/v0/bundles/ with JSON body containing filter conditions.
  Each filter is an object with operators: eq, gte, lte, gt, lt, in.
  """

  alias Lumainus.VastAI.Client

  @doc """
  Search for GPU offers.

  ## Options
    * `:filters` - Map of filter conditions (default: RTX 3090, 1 GPU, verified, rentable)
    * `:order` - Sort field (default: "dph_total" for cheapest first)
    * `:type` - "on-demand", "bid", or "reserved" (default: "on-demand")
    * `:limit` - Max results to return
    * `:disk_space` - Storage in GB for pricing calc
  """
  def search(opts \\ []) do
    filters = Keyword.get(opts, :filters, default_filters())
    order_field = Keyword.get(opts, :order, "dph_total")
    order_dir = Keyword.get(opts, :order_dir, "asc")
    type = Keyword.get(opts, :type, "on-demand")
    limit = Keyword.get(opts, :limit, 10)

    body =
      filters
      |> Map.put(:order, [[order_field, order_dir]])
      |> Map.put(:type, type)
      |> Map.put(:limit, limit)

    Client.post("/bundles/", body, opts)
  end

  @doc """
  Get the cheapest offer matching filters.
  """
  def cheapest(opts \\ []) do
    opts = Keyword.put_new(opts, :order, "dph_total")
    opts = Keyword.put_new(opts, :limit, 1)

    case search(opts) do
      {:ok, %{"offers" => [first | _]}} -> {:ok, first}
      {:ok, %{"offers" => []}} -> {:error, :no_offers}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      error -> error
    end
  end

  @doc """
  Build filters map from keyword options.

  ## Example
      build_filters(gpu_name: "RTX 3090", num_gpus: 1, dph_total: {:lte, 0.5})
  """
  def build_filters(opts) do
    opts
    |> Enum.reduce(%{}, fn
      {:gpu_name, v}, acc -> Map.put(acc, :gpu_name, %{eq: v})
      {:num_gpus, v}, acc -> Map.put(acc, :num_gpus, %{eq: v})
      {:gpu_ram, v}, acc -> Map.put(acc, :gpu_ram, %{gte: v})
      {:reliability, v}, acc -> Map.put(acc, :reliability, %{gte: v})
      {:verified, v}, acc -> Map.put(acc, :verified, %{eq: v})
      {:rentable, v}, acc -> Map.put(acc, :rentable, %{eq: v})
      {:geolocation, list}, acc when is_list(list) -> Map.put(acc, :geolocation, %{in: list})
      {:geolocation, v}, acc -> Map.put(acc, :geolocation, %{eq: v})
      {:dph_total, {:lte, v}}, acc -> Map.put(acc, :dph_total, %{lte: v})
      {:dph_total, {:lt, v}}, acc -> Map.put(acc, :dph_total, %{lt: v})
      {:cuda_vers, v}, acc -> Map.put(acc, :cuda_max_good, %{gte: v})
      {:datacenter, v}, acc -> Map.put(acc, :datacenter, %{eq: v})
      {:disk_space, v}, acc -> Map.put(acc, :disk_space, %{gte: v})
      _, acc -> acc
    end)
  end

  def default_filters do
    %{
      gpu_name: %{eq: "RTX 3090"},
      num_gpus: %{eq: 1},
      verified: %{eq: true},
      rentable: %{eq: true}
    }
  end
end
