# 05: Stream Flag Validation and Documentation

## Problem

The `stream` option flows through the system silently with no validation:

```elixir
# reports.ex:470-474
stream? = Keyword.get(opts, :stream, false)
job_args = if stream?, do: Map.put(job_args, "stream", true), else: job_args
```

Callers may not understand that `stream: true` means:
- Different code path
- Different rate limiting behavior (currently bypassed)
- Different error handling
- Different response processing

## Current Flow

```
Reports.run_sections(scope, patient, record_set, template, section_ids, stream: true)
    |
    +-- stream? = Keyword.get(opts, :stream, false)  # No validation
    |
    +-- job_args = Map.put(job_args, "stream", true)  # Silently passed
           |
           +-- Oban job created with stream flag
                  |
                  +-- SectionRunWorker reads flag
                         |
                         +-- Different behavior based on flag
```

## Problems

1. **No type validation** - Any truthy value accepted
2. **No documentation** - Caller doesn't know implications
3. **No telemetry** - Can't observe streaming vs batch ratio
4. **Silent behavior change** - No warning about rate limiting bypass

## Proposed Solution

### Option Type with Validation

```elixir
# lib/medlum/reports/types.ex

defmodule Medlum.Reports.Types do
  @moduledoc """
  Type definitions and validation for Reports module.
  """

  @type execution_mode :: :streaming | :batch

  @type run_sections_opts :: [
    mode: execution_mode(),
    priority: :normal | :high,
    timeout_ms: pos_integer()
  ]

  @doc """
  Validate and normalize run_sections options.
  """
  def validate_run_options(opts) do
    with {:ok, mode} <- validate_mode(opts),
         {:ok, priority} <- validate_priority(opts),
         {:ok, timeout} <- validate_timeout(opts) do
      {:ok, [mode: mode, priority: priority, timeout_ms: timeout]}
    end
  end

  defp validate_mode(opts) do
    case Keyword.get(opts, :mode, :batch) do
      :streaming -> {:ok, :streaming}
      :batch -> {:ok, :batch}
      # Legacy support
      true -> {:ok, :streaming}
      false -> {:ok, :batch}
      other -> {:error, {:invalid_mode, other, "must be :streaming or :batch"}}
    end
  end

  defp validate_priority(opts) do
    case Keyword.get(opts, :priority, :normal) do
      :normal -> {:ok, :normal}
      :high -> {:ok, :high}
      other -> {:error, {:invalid_priority, other}}
    end
  end

  defp validate_timeout(opts) do
    case Keyword.get(opts, :timeout_ms, 120_000) do
      timeout when is_integer(timeout) and timeout > 0 -> {:ok, timeout}
      other -> {:error, {:invalid_timeout, other}}
    end
  end
end
```

### Update Reports.run_sections

```elixir
# lib/medlum/reports.ex

@doc """
Run sections for a report.

## Options

  * `:mode` - Execution mode (default: `:batch`)
    * `:batch` - Wait for full response before returning
    * `:streaming` - Send incremental updates via PubSub

  * `:priority` - Job priority (default: `:normal`)

  * `:timeout_ms` - Timeout per section (default: 120_000)

## Mode Implications

| Mode | Rate Limiting | Progress Updates | Error Handling |
|------|---------------|------------------|----------------|
| `:batch` | Full support | On completion | Retry on failure |
| `:streaming` | Limited* | Real-time | Partial results |

*Note: Streaming mode may bypass some rate limiting until gemini_ex 0.7.2.
For strict rate limiting, use `:batch` mode.

## Examples

    # Batch mode (default, recommended)
    Reports.run_sections(scope, patient, record_set, template, section_ids)

    # Streaming mode (for real-time updates)
    Reports.run_sections(scope, patient, record_set, template, section_ids,
      mode: :streaming
    )
"""
def run_sections(scope, patient, record_set, template, section_ids, opts \\ []) do
  case Types.validate_run_options(opts) do
    {:ok, validated_opts} ->
      do_run_sections(scope, patient, record_set, template, section_ids, validated_opts)

    {:error, {field, value, message}} ->
      {:error, {:invalid_option, field, value, message}}
  end
end
```

### Telemetry for Mode Selection

```elixir
# lib/medlum/reports.ex

defp do_run_sections(scope, patient, record_set, template, section_ids, opts) do
  mode = Keyword.get(opts, :mode, :batch)

  :telemetry.execute(
    [:medlum, :reports, :run_sections, :start],
    %{section_count: length(section_ids)},
    %{
      mode: mode,
      template_id: template.id,
      scope: scope.type
    }
  )

  # ... rest of implementation
end
```

### Deprecation Warning for Legacy `stream:` Flag

```elixir
defp validate_mode(opts) do
  case {Keyword.get(opts, :mode), Keyword.get(opts, :stream)} do
    {nil, true} ->
      Logger.warning(
        "Deprecated: `stream: true` option. Use `mode: :streaming` instead. " <>
        "Note: streaming mode has limited rate limiting until gemini_ex 0.7.2."
      )
      {:ok, :streaming}

    {nil, false} ->
      {:ok, :batch}

    {nil, nil} ->
      {:ok, :batch}

    {mode, nil} when mode in [:streaming, :batch] ->
      {:ok, mode}

    {_mode, stream} when not is_nil(stream) ->
      {:error, {:conflicting_options, "Cannot specify both :mode and :stream"}}

    {other, _} ->
      {:error, {:invalid_mode, other, "must be :streaming or :batch"}}
  end
end
```

## Benefits

1. **Type safety** - Invalid modes caught early
2. **Documentation** - Implications clearly stated
3. **Deprecation path** - Legacy `stream:` flag still works with warning
4. **Telemetry** - Can track mode usage
5. **Conflict detection** - Both `:mode` and `:stream` specified = error

## Files to Modify

- `lib/medlum/reports/types.ex` - New module
- `lib/medlum/reports.ex` - Use validation, update docs
- `lib/medlum/reports/section_run_worker.ex` - Read `:mode` instead of `:stream`

## Testing

1. Valid `:mode` options accepted
2. Invalid mode rejected with clear error
3. Legacy `stream: true` works with warning
4. Conflicting options rejected
5. Telemetry emitted with mode
