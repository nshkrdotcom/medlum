# Vast.ai Search Query Syntax

## Overview

The search query is used to filter GPU offers. It's a space-separated list of comparisons.

## Query Syntax

```
query = comparison comparison...
comparison = field op value
```

### Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `=` | Equal | `num_gpus=1` |
| `!=` | Not equal | `gpu_name!=RTX_3090` |
| `>` | Greater than | `gpu_ram>20` |
| `>=` | Greater or equal | `reliability>=0.98` |
| `<` | Less than | `dph_total<0.50` |
| `<=` | Less or equal | `cuda_vers<=12.0` |
| `in` | In list | `geolocation in [US,CA]` |
| `notin` | Not in list | `geolocation notin [CN,RU]` |

### Values

- **Boolean**: `True`, `False`
- **Number**: `1`, `0.98`, `610`
- **String**: No quotes, use underscores for spaces: `RTX_4090`
- **Special**: `any` - match any value

## Available Fields

### GPU Fields

| Field | Type | Description |
|-------|------|-------------|
| `gpu_name` | string | GPU model (use underscores: `RTX_4090`) |
| `num_gpus` | int | Number of GPUs |
| `gpu_ram` | float | GPU VRAM in GB |
| `gpu_mem_bw` | float | GPU memory bandwidth in GB/s |
| `gpu_frac` | float | Ratio of GPUs in offer to system |
| `gpu_display_active` | bool | GPU has display attached |
| `total_flops` | float | Total TFLOPs from all GPUs |
| `compute_cap` | int | CUDA compute capability × 100 (e.g., 860 for 8.6) |
| `bw_nvlink` | float | NVLink bandwidth |

### CPU Fields

| Field | Type | Description |
|-------|------|-------------|
| `cpu_cores` | int | Virtual CPU cores |
| `cpu_cores_effective` | float | Effective vCPUs you get |
| `cpu_ram` | float | System RAM in GB |
| `has_avx` | bool | CPU supports AVX |

### Storage Fields

| Field | Type | Description |
|-------|------|-------------|
| `disk_space` | float | Disk storage in GB |
| `disk_bw` | float | Disk read bandwidth in MB/s |
| `storage_cost` | float | Storage cost in $/GB/month |

### Network Fields

| Field | Type | Description |
|-------|------|-------------|
| `inet_up` | float | Upload speed in Mb/s |
| `inet_down` | float | Download speed in Mb/s |
| `inet_up_cost` | float | Upload cost in $/GB |
| `inet_down_cost` | float | Download cost in $/GB |
| `direct_port_count` | int | Open ports on host router |
| `static_ip` | bool | Static/stable IP address |

### System Fields

| Field | Type | Description |
|-------|------|-------------|
| `cuda_vers` | float | Max supported CUDA version |
| `driver_version` | string | NVIDIA driver version (e.g., "535.86.05") |
| `ubuntu_version` | string | Ubuntu OS version |
| `pci_gen` | float | PCIe generation |
| `pcie_bw` | float | PCIe bandwidth (CPU to GPU) |

### Pricing Fields

| Field | Type | Description |
|-------|------|-------------|
| `dph` / `dph_total` | float | $/hour rental cost |
| `min_bid` | float | Minimum bid for spot instances |
| `dlperf` | float | Deep learning performance score |
| `dlperf_usd` | float | DL performance per dollar |
| `flops_usd` | float | TFLOPs per dollar |

### Status Fields

| Field | Type | Description |
|-------|------|-------------|
| `rentable` | bool | Currently rentable |
| `rented` | bool | Allow duplicates/conflicts |
| `verified` | bool | Machine is verified |
| `datacenter` | bool | Datacenter only |
| `external` | bool | Include external offers |
| `reliability` | float | Reliability score (0-1) |
| `duration` | float | Max rental duration in days |

### Location Fields

| Field | Type | Description |
|-------|------|-------------|
| `geolocation` | string | Two-letter country code |
| `machine_id` | int | Specific machine ID |
| `id` | int | Offer ID |

## Default Query

If not overridden with `-n`, the default is:
```
external=false rentable=true verified=true
```

## Sorting

Use the `order` parameter with comma-separated fields. Postfix with `-` for descending:

```elixir
# Sort by score descending (default)
order: "score-"

# Sort by number of GPUs ascending, then by price descending
order: "num_gpus,dph_total-"

# Sort by TFLOPs descending
order: "total_flops-"
```

## Pricing Type

Specify with the `type` option:

- `:on_demand` - Fixed price (default)
- `:bid` - Spot/interruptible instances
- `:reserved` - Long-term reservations

## Example Queries

### High-End Training Setup
```elixir
# 4x RTX 4090 with high reliability
query = "num_gpus>=4 gpu_name=RTX_4090 reliability>0.99 verified=True"
```

### Budget Development
```elixir
# Single GPU under $0.30/hr
query = "num_gpus=1 dph_total<0.30 gpu_ram>=8"
```

### LLM Inference
```elixir
# High VRAM for large models
query = "gpu_ram>=40 num_gpus>=2 inet_down>200"
```

### Datacenter Only
```elixir
# Reliable datacenter GPUs
query = "datacenter=True reliability>0.98 cuda_vers>=12.0"
```

### Geographic Restriction
```elixir
# US or Canada only
query = "geolocation in [US,CA] verified=True"
```

### Spot Instances
```elixir
# Cheap spot instances
query = "min_bid<0.20 num_gpus=1"
type = :bid
```

### Multi-GPU NVLink
```elixir
# NVLink-connected GPUs
query = "bw_nvlink>100 num_gpus>=4"
```

## Elixir Implementation

```elixir
defmodule Lumainus.VastAI.Search do
  @moduledoc """
  Build search queries for Vast.ai offers.
  """

  def build_query(opts \\ []) do
    opts
    |> Keyword.take([
      :gpu_name, :num_gpus, :gpu_ram, :compute_cap, :total_flops,
      :cpu_cores, :cpu_ram, :disk_space, :cuda_vers, :inet_up,
      :inet_down, :direct_port_count, :datacenter, :verified,
      :rentable, :rented, :reliability, :geolocation, :dph_total
    ])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(&format_comparison/1)
    |> Enum.join(" ")
  end

  defp format_comparison({key, {op, value}}) do
    "#{key}#{op}#{format_value(value)}"
  end

  defp format_comparison({key, value}) when is_boolean(value) do
    "#{key}=#{if value, do: "True", else: "False"}"
  end

  defp format_comparison({key, value}) do
    "#{key}=#{format_value(value)}"
  end

  defp format_value(value) when is_binary(value) do
    String.replace(value, " ", "_")
  end

  defp format_value(value), do: value

  # Usage example
  def example do
    query = build_query(
      gpu_name: "RTX_4090",
      num_gpus: 1,
      gpu_ram: {:>=, 20},
      reliability: {:>, 0.98},
      verified: true
    )
    # Returns: "gpu_name=RTX_4090 num_gpus=1 gpu_ram>=20 reliability>0.98 verified=True"
  end
end
```

## Common GPU Names

| GPU | `gpu_name` value | VRAM |
|-----|-----------------|------|
| RTX 4090 | `RTX_4090` | 24 GB |
| RTX 4080 | `RTX_4080` | 16 GB |
| RTX 3090 | `RTX_3090` | 24 GB |
| RTX 3080 | `RTX_3080` | 10/12 GB |
| A100 80GB | `A100_80GB` | 80 GB |
| A100 40GB | `A100_40GB` | 40 GB |
| H100 | `H100_80GB` | 80 GB |
| A6000 | `RTX_A6000` | 48 GB |
| L40S | `L40S` | 48 GB |

## Storage Parameter

When searching, you can specify assumed storage for pricing calculation:

```elixir
# Assume 50 GB storage for price calculation
storage: 50.0  # in GiB, default is 5.0
```
