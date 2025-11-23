# Vast.ai Elixir Type Specifications

## Core Types

```elixir
defmodule Lumainus.VastAI.Types do
  @moduledoc """
  Type specifications for Vast.ai API integration.
  """

  # Basic types
  @type api_key :: String.t()
  @type instance_id :: pos_integer()
  @type machine_id :: pos_integer()
  @type offer_id :: pos_integer()

  # Instance states
  @type instance_state :: :running | :stopped | :scheduling | :exited | :created

  # Pricing types
  @type pricing_type :: :on_demand | :bid | :reserved

  # Run types
  @type run_type :: :ssh | :jupyter | :args
end
```

## Offer Schema

Returned from `GET /bundles/` (search offers):

```elixir
defmodule Lumainus.VastAI.Offer do
  @moduledoc """
  GPU offer/bundle available for rent.
  """

  @type t :: %__MODULE__{
    id: pos_integer(),
    machine_id: pos_integer(),

    # GPU Info
    gpu_name: String.t(),
    num_gpus: pos_integer(),
    gpu_ram: float(),
    gpu_mem_bw: float(),
    gpu_frac: float(),
    total_flops: float(),
    compute_cap: integer(),

    # CPU Info
    cpu_name: String.t(),
    cpu_cores: integer(),
    cpu_cores_effective: float(),
    cpu_ram: float(),

    # Storage
    disk_space: float(),
    disk_bw: float(),

    # Network
    inet_up: float(),
    inet_down: float(),
    inet_up_cost: float(),
    inet_down_cost: float(),
    direct_port_count: integer(),

    # Pricing
    dph_total: float(),           # $/hour total
    min_bid: float(),             # minimum bid for spot
    storage_cost: float(),        # $/GB/month

    # System Info
    cuda_vers: float(),
    driver_version: String.t(),
    ubuntu_version: String.t(),
    pci_gen: float(),
    pcie_bw: float(),
    bw_nvlink: float(),

    # Status
    rentable: boolean(),
    rented: boolean(),
    verified: boolean(),
    datacenter: boolean(),
    static_ip: boolean(),
    reliability: float(),
    duration: float(),            # max rental days

    # Location
    geolocation: String.t(),      # 2-letter country code

    # Scoring
    score: float(),
    dlperf: float(),
    dlperf_usd: float(),
    flops_usd: float()
  }

  defstruct [
    :id, :machine_id, :gpu_name, :num_gpus, :gpu_ram, :gpu_mem_bw,
    :gpu_frac, :total_flops, :compute_cap, :cpu_name, :cpu_cores,
    :cpu_cores_effective, :cpu_ram, :disk_space, :disk_bw, :inet_up,
    :inet_down, :inet_up_cost, :inet_down_cost, :direct_port_count,
    :dph_total, :min_bid, :storage_cost, :cuda_vers, :driver_version,
    :ubuntu_version, :pci_gen, :pcie_bw, :bw_nvlink, :rentable, :rented,
    :verified, :datacenter, :static_ip, :reliability, :duration,
    :geolocation, :score, :dlperf, :dlperf_usd, :flops_usd
  ]
end
```

## Instance Schema

```elixir
defmodule Lumainus.VastAI.Instance do
  @moduledoc """
  A rented GPU instance.
  """

  @type t :: %__MODULE__{
    id: pos_integer(),
    machine_id: pos_integer(),

    # Status
    actual_status: String.t(),
    intended_status: String.t(),
    cur_state: String.t(),

    # Configuration
    image_uuid: String.t(),
    docker_image: String.t(),
    label: String.t() | nil,
    disk_space: float(),

    # GPU Info
    gpu_name: String.t(),
    num_gpus: pos_integer(),
    gpu_ram: float(),
    gpu_util: float(),

    # Pricing
    dph_total: float(),
    total_cost: float(),

    # Network
    ssh_host: String.t(),
    ssh_port: integer(),
    ssh_idx: String.t(),
    direct_port_start: integer(),
    direct_port_end: integer(),
    jupyter_token: String.t() | nil,

    # Timestamps
    start_date: float(),
    end_date: float() | nil,

    # Host Info
    host_id: pos_integer(),
    geolocation: String.t()
  }

  defstruct [
    :id, :machine_id, :actual_status, :intended_status, :cur_state,
    :image_uuid, :docker_image, :label, :disk_space, :gpu_name,
    :num_gpus, :gpu_ram, :gpu_util, :dph_total, :total_cost,
    :ssh_host, :ssh_port, :ssh_idx, :direct_port_start, :direct_port_end,
    :jupyter_token, :start_date, :end_date, :host_id, :geolocation
  ]
end
```

## Create Instance Request

```elixir
defmodule Lumainus.VastAI.CreateInstanceRequest do
  @moduledoc """
  Request body for creating an instance.
  """

  @type t :: %__MODULE__{
    client_id: String.t(),
    image: String.t(),
    disk: float(),
    label: String.t() | nil,
    onstart: String.t() | nil,
    runtype: String.t(),
    image_login: String.t() | nil,
    env: map(),
    python_utf8: boolean(),
    lang_utf8: boolean(),
    use_jupyter_lab: boolean(),
    jupyter_dir: String.t() | nil,
    create_from: pos_integer() | nil,
    force: boolean()
  }

  defstruct [
    client_id: "me",
    image: nil,
    disk: 10.0,
    label: nil,
    onstart: nil,
    runtype: "ssh",
    image_login: nil,
    env: %{},
    python_utf8: false,
    lang_utf8: false,
    use_jupyter_lab: false,
    jupyter_dir: nil,
    create_from: nil,
    force: false
  ]
end
```

## Search Query

```elixir
defmodule Lumainus.VastAI.SearchQuery do
  @moduledoc """
  Search query parameters for finding offers.
  """

  @type t :: %__MODULE__{
    # GPU requirements
    gpu_name: String.t() | nil,
    num_gpus: pos_integer() | nil,
    gpu_ram: float() | nil,
    compute_cap: integer() | nil,
    total_flops: float() | nil,

    # System requirements
    cpu_cores: integer() | nil,
    cpu_ram: float() | nil,
    disk_space: float() | nil,
    cuda_vers: float() | nil,

    # Network requirements
    inet_up: float() | nil,
    inet_down: float() | nil,
    direct_port_count: integer() | nil,

    # Filters
    datacenter: boolean() | nil,
    verified: boolean() | nil,
    rentable: boolean(),
    rented: boolean() | :any,
    reliability: float() | nil,
    geolocation: String.t() | nil,
    duration: float() | nil,

    # Pricing
    dph_total: float() | nil,
    storage_cost: float() | nil,

    # Sorting
    order: String.t(),

    # Pricing type
    type: :on_demand | :bid | :reserved
  }

  defstruct [
    gpu_name: nil,
    num_gpus: nil,
    gpu_ram: nil,
    compute_cap: nil,
    total_flops: nil,
    cpu_cores: nil,
    cpu_ram: nil,
    disk_space: nil,
    cuda_vers: nil,
    inet_up: nil,
    inet_down: nil,
    direct_port_count: nil,
    datacenter: nil,
    verified: true,
    rentable: true,
    rented: false,
    reliability: nil,
    geolocation: nil,
    duration: nil,
    dph_total: nil,
    storage_cost: nil,
    order: "score-",
    type: :on_demand
  ]
end
```

## User Schema

```elixir
defmodule Lumainus.VastAI.User do
  @moduledoc """
  User account information.
  """

  @type t :: %__MODULE__{
    id: pos_integer(),
    username: String.t(),
    email: String.t(),
    balance: float(),
    balance_threshold: float(),
    ssh_key: String.t() | nil,
    api_key_id: pos_integer()
  }

  defstruct [:id, :username, :email, :balance, :balance_threshold, :ssh_key, :api_key_id]
end
```

## API Response Types

```elixir
defmodule Lumainus.VastAI.Response do
  @moduledoc """
  Common API response types.
  """

  @type success :: %{
    success: true,
    optional(:new_contract) => pos_integer(),
    optional(:msg) => String.t(),
    optional(:data) => any()
  }

  @type error :: %{
    success: false,
    error: String.t(),
    msg: String.t()
  }

  @type api_response :: success() | error()
end
```

## Invoice Schema

```elixir
defmodule Lumainus.VastAI.Invoice do
  @type t :: %__MODULE__{
    id: pos_integer(),
    timestamp: float(),
    type: String.t(),
    amount: float(),
    description: String.t(),
    instance_id: pos_integer() | nil,
    machine_id: pos_integer() | nil
  }

  defstruct [:id, :timestamp, :type, :amount, :description, :instance_id, :machine_id]
end
```

## SSH Key Schema

```elixir
defmodule Lumainus.VastAI.SSHKey do
  @type t :: %__MODULE__{
    id: pos_integer(),
    ssh_key: String.t(),
    created_at: float(),
    public_key: String.t()
  }

  defstruct [:id, :ssh_key, :created_at, :public_key]
end
```

## Autoscaler Schema

```elixir
defmodule Lumainus.VastAI.Autoscaler do
  @type t :: %__MODULE__{
    id: pos_integer(),
    endpoint_name: String.t(),
    min_load: float(),
    target_util: float(),
    cold_mult: float(),
    gpu_ram: float(),
    search_params: String.t(),
    launch_args: String.t(),
    template_hash: String.t() | nil,
    template_id: pos_integer() | nil
  }

  defstruct [
    :id, :endpoint_name, :min_load, :target_util, :cold_mult,
    :gpu_ram, :search_params, :launch_args, :template_hash, :template_id
  ]
end
```

## Machine Schema (Hosting)

```elixir
defmodule Lumainus.VastAI.Machine do
  @type t :: %__MODULE__{
    id: pos_integer(),
    hostname: String.t(),

    # GPU Info
    gpu_name: String.t(),
    num_gpus: pos_integer(),
    gpu_ram: float(),

    # Status
    listed: boolean(),
    verified: boolean(),
    reliability: float(),

    # Pricing
    price_gpu: float(),
    price_disk: float(),
    price_inetu: float(),
    price_inetd: float(),
    min_bid: float(),
    discount_rate: float()
  }

  defstruct [
    :id, :hostname, :gpu_name, :num_gpus, :gpu_ram, :listed,
    :verified, :reliability, :price_gpu, :price_disk, :price_inetu,
    :price_inetd, :min_bid, :discount_rate
  ]
end
```
