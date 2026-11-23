# Vast.ai Elixir Client Implementation Guide

## Module Structure

```
lib/medlum/vast_ai/
├── client.ex          # HTTP client, auth, base requests
├── instances.ex       # Instance management
├── offers.ex          # Search and offers
├── ssh_keys.ex        # SSH key management
├── billing.ex         # Invoices, earnings, credits
├── autoscalers.ex     # Serverless autoscaling
├── teams.ex           # Team management
└── types.ex           # Type definitions
```

## Base Client

```elixir
defmodule Medlum.VastAI.Client do
  @moduledoc """
  HTTP client for Vast.ai API.
  """

  @base_url "https://console.vast.ai/api/v0"

  def get(path, opts \\ []) do
    request(:get, path, nil, opts)
  end

  def post(path, body, opts \\ []) do
    request(:post, path, body, opts)
  end

  def put(path, body, opts \\ []) do
    request(:put, path, body, opts)
  end

  def delete(path, opts \\ []) do
    request(:delete, path, nil, opts)
  end

  defp request(method, path, body, opts) do
    api_key = Keyword.get(opts, :api_key) || get_api_key()
    url = @base_url <> path
    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"},
      {"Accept", "application/json"}
    ]

    body_json = if body, do: Jason.encode!(body), else: ""

    case Req.request(method: method, url: url, headers: headers, body: body_json) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_api_key do
    Application.get_env(:medlum, :vast_ai)[:api_key] ||
      System.get_env("VAST_API_KEY") ||
      raise "VAST_API_KEY not configured"
  end
end
```

## Instance Management

```elixir
defmodule Medlum.VastAI.Instances do
  @moduledoc """
  Instance management operations.
  """

  alias Medlum.VastAI.Client

  @doc """
  List all user instances.
  """
  def list(opts \\ []) do
    Client.get("/instances/", opts)
  end

  @doc """
  Get instance details.
  """
  def get(instance_id, opts \\ []) do
    Client.get("/instances/#{instance_id}/", opts)
  end

  @doc """
  Create instance from offer.
  """
  def create(offer_id, params, opts \\ []) do
    body = Map.merge(%{client_id: "me"}, params)
    Client.put("/instances/#{offer_id}/", body, opts)
  end

  @doc """
  Destroy instance permanently.
  """
  def destroy(instance_id, opts \\ []) do
    Client.delete("/instances/#{instance_id}/", opts)
  end

  @doc """
  Start a stopped instance.
  """
  def start(instance_id, opts \\ []) do
    Client.put("/instances/#{instance_id}/", %{state: "running"}, opts)
  end

  @doc """
  Stop a running instance.
  """
  def stop(instance_id, opts \\ []) do
    Client.put("/instances/#{instance_id}/", %{state: "stopped"}, opts)
  end

  @doc """
  Reboot instance.
  """
  def reboot(instance_id, opts \\ []) do
    Client.post("/instances/reboot/#{instance_id}/", %{}, opts)
  end

  @doc """
  Get instance logs.
  """
  def logs(instance_id, tail \\ 1000, opts \\ []) do
    Client.get("/instances/request_logs/#{instance_id}?tail=#{tail}", opts)
  end

  @doc """
  Execute command on instance.
  """
  def execute(instance_id, command, opts \\ []) do
    Client.post("/instances/command/#{instance_id}/", %{command: command}, opts)
  end

  @doc """
  Label an instance.
  """
  def label(instance_id, label, opts \\ []) do
    Client.put("/instances/#{instance_id}/", %{label: label}, opts)
  end

  @doc """
  Change bid price for spot instance.
  """
  def change_bid(instance_id, price, opts \\ []) do
    Client.put("/instances/bid_price/#{instance_id}/", %{price: price}, opts)
  end
end
```

## Search Offers

```elixir
defmodule Medlum.VastAI.Offers do
  @moduledoc """
  Search for GPU offers.
  """

  alias Medlum.VastAI.Client

  @doc """
  Search for available GPU offers.

  ## Options
    * `:query` - Search query string
    * `:type` - Pricing type: :on_demand, :bid, :reserved
    * `:order` - Sort order (e.g., "score-", "dph_total")
    * `:storage` - Assumed storage in GiB for pricing
    * `:disable_bundling` - Show identical offers
  """
  def search(opts \\ []) do
    query = build_query_string(opts)
    Client.get("/bundles/?#{query}", opts)
  end

  defp build_query_string(opts) do
    params = %{
      q: Keyword.get(opts, :query, "verified=true rentable=true"),
      order: Keyword.get(opts, :order, "score-"),
      type: pricing_type(Keyword.get(opts, :type, :on_demand)),
      disk_space: Keyword.get(opts, :storage, 5.0)
    }

    params
    |> maybe_add(:disable_bundling, Keyword.get(opts, :disable_bundling))
    |> URI.encode_query()
  end

  defp pricing_type(:on_demand), do: "on-demand"
  defp pricing_type(:bid), do: "bid"
  defp pricing_type(:reserved), do: "reserved"

  defp maybe_add(params, _key, nil), do: params
  defp maybe_add(params, key, value), do: Map.put(params, key, value)

  @doc """
  Get the cheapest offer matching criteria.
  """
  def cheapest(opts \\ []) do
    opts = Keyword.put(opts, :order, "dph_total")

    case search(opts) do
      {:ok, %{"offers" => [first | _]}} -> {:ok, first}
      {:ok, %{"offers" => []}} -> {:error, :no_offers}
      error -> error
    end
  end

  @doc """
  Get the best performance offer.
  """
  def best_performance(opts \\ []) do
    opts = Keyword.put(opts, :order, "dlperf-")
    search(opts)
  end
end
```

## High-Level Workflows

```elixir
defmodule Medlum.VastAI do
  @moduledoc """
  High-level Vast.ai operations.
  """

  alias Medlum.VastAI.{Offers, Instances}

  @doc """
  Launch a new GPU instance with the given specs.

  ## Example

      Medlum.VastAI.launch_instance(
        gpu_name: "RTX_4090",
        num_gpus: 1,
        image: "pytorch/pytorch",
        disk: 50
      )
  """
  def launch_instance(opts) do
    query_opts = Keyword.take(opts, [
      :gpu_name, :num_gpus, :gpu_ram, :reliability,
      :datacenter, :cuda_vers, :geolocation
    ])

    query = build_search_query(query_opts)

    instance_params = %{
      image: Keyword.fetch!(opts, :image),
      disk: Keyword.get(opts, :disk, 10),
      label: Keyword.get(opts, :label),
      onstart: Keyword.get(opts, :onstart),
      runtype: Keyword.get(opts, :runtype, "ssh"),
      env: Keyword.get(opts, :env, %{})
    }

    with {:ok, offer} <- Offers.cheapest(query: query),
         {:ok, result} <- Instances.create(offer["id"], instance_params) do
      {:ok, result["new_contract"]}
    end
  end

  @doc """
  Wait for instance to be ready.
  """
  def wait_for_ready(instance_id, timeout \\ 300_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.interval(5_000)
    |> Stream.take_while(fn _ ->
      System.monotonic_time(:millisecond) < deadline
    end)
    |> Enum.reduce_while(:waiting, fn _, _ ->
      case Instances.get(instance_id) do
        {:ok, %{"actual_status" => "running"}} ->
          {:halt, :ready}

        {:ok, %{"actual_status" => "exited"}} ->
          {:halt, {:error, :instance_exited}}

        {:ok, _} ->
          {:cont, :waiting}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      :ready -> {:ok, instance_id}
      :waiting -> {:error, :timeout}
      error -> error
    end
  end

  @doc """
  Get SSH connection info for an instance.
  """
  def ssh_info(instance_id) do
    case Instances.get(instance_id) do
      {:ok, instance} ->
        {:ok, %{
          host: instance["ssh_host"],
          port: instance["ssh_port"],
          command: "ssh -p #{instance["ssh_port"]} root@#{instance["ssh_host"]}"
        }}

      error ->
        error
    end
  end

  @doc """
  Cleanup - destroy all instances with a label.
  """
  def destroy_by_label(label) do
    with {:ok, %{"instances" => instances}} <- Instances.list() do
      instances
      |> Enum.filter(&(&1["label"] == label))
      |> Enum.map(&Instances.destroy(&1["id"]))
    end
  end

  defp build_search_query(opts) do
    opts
    |> Enum.map(fn
      {:gpu_name, v} -> "gpu_name=#{String.replace(v, " ", "_")}"
      {:num_gpus, v} -> "num_gpus=#{v}"
      {:gpu_ram, v} -> "gpu_ram>=#{v}"
      {:reliability, v} -> "reliability>#{v}"
      {:datacenter, true} -> "datacenter=True"
      {:cuda_vers, v} -> "cuda_vers>=#{v}"
      {:geolocation, v} -> "geolocation=#{v}"
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end
end
```

## Configuration

```elixir
# config/config.exs
config :medlum, :vast_ai,
  api_key: System.get_env("VAST_API_KEY")

# config/runtime.exs (for releases)
config :medlum, :vast_ai,
  api_key: System.fetch_env!("VAST_API_KEY")
```

## Error Handling

```elixir
defmodule Medlum.VastAI.Error do
  defexception [:message, :code, :status]

  def from_response(%{status: status, body: body}) do
    %__MODULE__{
      message: body["msg"] || "Unknown error",
      code: body["error"] || "unknown",
      status: status
    }
  end
end
```

## Testing

```elixir
defmodule Medlum.VastAI.MockClient do
  @moduledoc """
  Mock client for testing.
  """

  def get("/instances/", _opts) do
    {:ok, %{"instances" => []}}
  end

  def get("/bundles/?" <> _query, _opts) do
    {:ok, %{
      "offers" => [
        %{
          "id" => 12345,
          "gpu_name" => "RTX 4090",
          "num_gpus" => 1,
          "dph_total" => 0.45
        }
      ]
    }}
  end
end
```

## Usage Examples

### Launch a Training Instance

```elixir
# Launch a 4x RTX 4090 instance for training
{:ok, instance_id} = Medlum.VastAI.launch_instance(
  gpu_name: "RTX_4090",
  num_gpus: 4,
  gpu_ram: 20,
  reliability: 0.98,
  image: "pytorch/pytorch:2.1.0-cuda12.1-cudnn8-runtime",
  disk: 100,
  label: "training-job-#{Date.utc_today()}",
  onstart: """
  #!/bin/bash
  pip install wandb transformers datasets
  python /workspace/train.py
  """,
  env: %{
    "WANDB_API_KEY" => "...",
    "HF_TOKEN" => "..."
  }
)

# Wait for it to be ready
{:ok, ^instance_id} = Medlum.VastAI.wait_for_ready(instance_id)

# Get SSH info
{:ok, ssh} = Medlum.VastAI.ssh_info(instance_id)
IO.puts("Connect with: #{ssh.command}")
```

### Batch Processing

```elixir
# Launch multiple instances for parallel processing
tasks = 1..10

instance_ids =
  tasks
  |> Task.async_stream(fn task_id ->
    Medlum.VastAI.launch_instance(
      gpu_name: "RTX_3090",
      num_gpus: 1,
      image: "my-processor:latest",
      label: "batch-#{task_id}",
      env: %{"TASK_ID" => to_string(task_id)}
    )
  end)
  |> Enum.map(fn {:ok, {:ok, id}} -> id end)

# Cleanup when done
Medlum.VastAI.destroy_by_label("batch-")
```

### Monitor Costs

```elixir
alias Medlum.VastAI.Client

# Get current spend
{:ok, user} = Client.get("/users/current/")
IO.puts("Balance: $#{user["balance"]}")

# Get recent invoices
{:ok, invoices} = Client.get("/invoices?start_date=2024-01-01")
total = Enum.sum(Enum.map(invoices["invoices"], & &1["amount"]))
IO.puts("Total spent: $#{total}")
```
