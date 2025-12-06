# 06: Central Model Registry

## Problem

Model strings/specs are built in multiple places:

```elixir
# Scattered throughout codebase
"google/gemini-2.0-flash-lite"
"google/gemini-1.5-flash"
Gemini.Config.get_model(:flash_lite_latest)
```

No central mapping. Easy to:
- Use wrong model for use case
- Drift between environments
- Miss model deprecations
- Hardcode strings that should be configurable

## Current State

Model specs constructed inline in:
- `SectionRunner` - For report generation
- `LLM` module - Provider/model parsing
- Tests - Hardcoded strings
- Config - Cache model settings

## Proposed Solution

### Central Model Registry

```elixir
# lib/lumainus/ai/models.ex

defmodule Lumainus.AI.Models do
  @moduledoc """
  Central registry for LLM model configurations.

  Maps use cases to model specs with associated metadata.
  All LLM calls should use this registry rather than hardcoded model strings.
  """

  @type use_case ::
    :report_section |
    :report_section_cached |
    :document_summary |
    :quick_extraction |
    :complex_reasoning

  @type model_spec :: %{
    provider: String.t(),
    model: String.t(),
    full_spec: String.t(),
    min_context_tokens: pos_integer(),
    supports_caching: boolean(),
    tier: :fast | :standard | :premium
  }

  @models %{
    report_section: %{
      provider: "google",
      model: "gemini-2.0-flash-lite",
      full_spec: "google/gemini-2.0-flash-lite",
      min_context_tokens: 32_000,
      supports_caching: true,
      tier: :fast
    },
    report_section_cached: %{
      provider: "google",
      model: "gemini-2.0-flash-lite",
      full_spec: "google/gemini-2.0-flash-lite",
      min_context_tokens: 32_000,
      supports_caching: true,
      tier: :fast
    },
    document_summary: %{
      provider: "google",
      model: "gemini-2.0-flash-lite",
      full_spec: "google/gemini-2.0-flash-lite",
      min_context_tokens: 32_000,
      supports_caching: false,
      tier: :fast
    },
    complex_reasoning: %{
      provider: "google",
      model: "gemini-1.5-pro",
      full_spec: "google/gemini-1.5-pro",
      min_context_tokens: 128_000,
      supports_caching: true,
      tier: :premium
    }
  }

  @doc """
  Get model spec for a use case.

  ## Examples

      iex> Models.get(:report_section)
      {:ok, %{provider: "google", model: "gemini-2.0-flash-lite", ...}}

      iex> Models.get(:unknown)
      {:error, :unknown_use_case}
  """
  def get(use_case) when is_atom(use_case) do
    case Map.get(@models, use_case) do
      nil -> {:error, :unknown_use_case}
      spec -> {:ok, spec}
    end
  end

  @doc """
  Get model spec string for a use case.

  Raises on unknown use case (for pipeline use).
  """
  def get!(use_case) do
    case get(use_case) do
      {:ok, spec} -> spec
      {:error, :unknown_use_case} -> raise "Unknown model use case: #{use_case}"
    end
  end

  @doc """
  Get just the full spec string.
  """
  def spec_string(use_case) do
    case get(use_case) do
      {:ok, %{full_spec: spec}} -> {:ok, spec}
      error -> error
    end
  end

  def spec_string!(use_case) do
    get!(use_case).full_spec
  end

  @doc """
  List all registered use cases.
  """
  def list_use_cases do
    Map.keys(@models)
  end

  @doc """
  List models by tier.
  """
  def by_tier(tier) do
    @models
    |> Enum.filter(fn {_k, v} -> v.tier == tier end)
    |> Enum.map(fn {k, _v} -> k end)
  end

  @doc """
  Check if a use case supports caching.
  """
  def supports_caching?(use_case) do
    case get(use_case) do
      {:ok, %{supports_caching: true}} -> true
      _ -> false
    end
  end
end
```

### Environment-Based Overrides

```elixir
# lib/lumainus/ai/models.ex

defmodule Lumainus.AI.Models do
  @compile_time_models %{...}

  @doc """
  Get model with runtime override support.
  """
  def get(use_case) do
    case Application.get_env(:lumainus, :model_overrides, %{})[use_case] do
      nil ->
        Map.get(@compile_time_models, use_case)
        |> case do
          nil -> {:error, :unknown_use_case}
          spec -> {:ok, spec}
        end

      override when is_binary(override) ->
        # Simple string override
        base = Map.get(@compile_time_models, use_case, %{})
        {:ok, %{base | full_spec: override, model: parse_model(override)}}

      override when is_map(override) ->
        # Full spec override
        base = Map.get(@compile_time_models, use_case, %{})
        {:ok, Map.merge(base, override)}
    end
  end
end
```

### Configuration

```elixir
# config/config.exs

config :lumainus, :model_overrides, %{
  # Override for testing/development
  # report_section: "google/gemini-1.5-flash"
}

# config/prod.exs
config :lumainus, :model_overrides, %{
  # Production overrides if needed
}
```

### Update SectionRunner

```elixir
# lib/lumainus/ai/section_runner.ex

alias Lumainus.AI.Models

defp get_model_spec(section_run, _options) do
  use_case =
    if has_cached_content?(section_run) do
      :report_section_cached
    else
      :report_section
    end

  Models.spec_string!(use_case)
end
```

## Benefits

1. **Single source of truth** - All models defined in one place
2. **Use case semantics** - Code reads intent, not implementation
3. **Easy overrides** - Config-based model switching
4. **Metadata** - Token limits, caching support documented
5. **Tier awareness** - Can route by cost/speed tier

## Migration

### Phase 1: Create Registry

1. Create `Lumainus.AI.Models` module
2. Define all current use cases
3. Add to docs

### Phase 2: Update Callers

1. Replace hardcoded strings with `Models.spec_string!/1`
2. Update tests to use registry
3. Add validation for unknown use cases

### Phase 3: Add Overrides

1. Add config-based override support
2. Document override mechanism
3. Add telemetry for model selection

## Files to Modify

- `lib/lumainus/ai/models.ex` - New module
- `lib/lumainus/ai/section_runner.ex` - Use registry
- `lib/lumainus/llm.ex` - Validate against registry
- `config/config.exs` - Override config

## Testing

1. Known use case returns spec
2. Unknown use case returns error
3. Override applied correctly
4. Caching check works
5. Tier filtering works
