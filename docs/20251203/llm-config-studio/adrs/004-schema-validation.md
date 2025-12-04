# ADR-004: JSON Schema Validation for Gemini

## Status
Proposed

## Context

Users can edit `output_schema` (JSON Schema) in the UI. Invalid schemas cause runtime failures when Gemini rejects the request. Currently:

1. No validation at save time
2. Schemas are passed directly to Gemini API
3. Runtime fix `ensure_array_items/1` patches missing `items` on arrays
4. Migration 20251204 was needed to fix existing bad schemas

**Gemini Requirements:**
- Root must be `{"type": "object"}`
- All arrays MUST have `items` property
- Properties defined in `properties` object
- `required` array must reference existing properties
- Valid JSON Schema types only

## Decision

Implement client-side and server-side JSON Schema validation before saving.

### Validation Rules

```elixir
defmodule Lumainus.Reports.SchemaValidator do
  @moduledoc """
  Validates JSON Schemas for Gemini API compatibility.
  """

  @valid_types ["string", "number", "integer", "boolean", "object", "array"]

  def valid?(schema), do: match?({:ok, _}, validate(schema))

  def validate(schema) when is_map(schema) do
    with :ok <- validate_root_type(schema),
         :ok <- validate_properties(schema),
         :ok <- validate_required(schema),
         :ok <- validate_arrays(schema) do
      {:ok, schema}
    end
  end

  def validate(_), do: {:error, "Schema must be a JSON object"}

  defp validate_root_type(%{"type" => "object"}), do: :ok
  defp validate_root_type(_), do: {:error, "Root type must be 'object'"}

  defp validate_properties(%{"properties" => props}) when is_map(props) do
    Enum.reduce_while(props, :ok, fn {name, spec}, :ok ->
      case validate_property(name, spec) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
  defp validate_properties(_), do: {:error, "Missing 'properties' object"}

  defp validate_property(name, %{"type" => type} = spec) do
    cond do
      type not in @valid_types ->
        {:error, "Property '#{name}' has invalid type '#{type}'"}
      type == "array" and not Map.has_key?(spec, "items") ->
        {:error, "Array property '#{name}' must have 'items' definition"}
      type == "object" and Map.has_key?(spec, "properties") ->
        validate_properties(spec)
      true ->
        :ok
    end
  end
  defp validate_property(name, _) do
    {:error, "Property '#{name}' missing 'type'"}
  end

  defp validate_required(%{"required" => required, "properties" => props})
       when is_list(required) do
    missing = Enum.reject(required, &Map.has_key?(props, &1))
    if Enum.empty?(missing) do
      :ok
    else
      {:error, "Required fields not in properties: #{inspect(missing)}"}
    end
  end
  defp validate_required(_), do: :ok

  defp validate_arrays(schema) do
    case find_arrays_without_items(schema) do
      [] -> :ok
      paths -> {:error, "Arrays missing 'items': #{Enum.join(paths, ", ")}"}
    end
  end

  defp find_arrays_without_items(value, path \\ "$")

  defp find_arrays_without_items(%{"type" => "array"} = spec, path) do
    has_items? = Map.has_key?(spec, "items")
    nested_paths = find_arrays_without_items(Map.get(spec, "items"), path <> ".items")

    (if has_items?, do: [], else: [path]) ++ nested_paths
  end

  defp find_arrays_without_items(%{"properties" => props}, path) when is_map(props) do
    props
    |> Enum.flat_map(fn {k, v} -> find_arrays_without_items(v, path <> ".properties." <> k) end)
  end

  defp find_arrays_without_items(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {v, idx} -> find_arrays_without_items(v, "#{path}[#{idx}]") end)
  end

  defp find_arrays_without_items(_value, _path), do: []
end
```

### LiveView Integration

```elixir
# In the config LiveView
def handle_event("validate_schema", %{"schema_json" => json}, socket) do
  case Jason.decode(json) do
    {:ok, schema} ->
      case SchemaValidator.validate(schema) do
        {:ok, _} ->
          {:noreply, assign(socket, schema_error: nil, schema_valid: true)}
        {:error, msg} ->
          {:noreply, assign(socket, schema_error: msg, schema_valid: false)}
      end
    {:error, _} ->
      {:noreply, assign(socket, schema_error: "Invalid JSON syntax", schema_valid: false)}
  end
end

def handle_event("save_section", params, socket) do
  # Block save if schema invalid
  if socket.assigns.schema_valid == false do
    {:noreply, put_flash(socket, :error, "Fix schema errors before saving")}
  else
    # Proceed with save...
  end
end
```

### Server-Side Enforcement

- Call `SchemaValidator.validate/1` inside `ReportSectionTemplate.changeset/2` and any template-level update paths to prevent bad schemas from being persisted even if the UI bypasses checks.
- Keep the existing migration `20251204000000_fix_citation_array_schemas.exs` as a guardrail for legacy data; the validator should prevent reintroduction of the same issue.

### UI Feedback

```heex
<div class="space-y-2">
  <label class="label">Output Schema (JSON)</label>
  <textarea
    name="section[output_schema_json]"
    phx-change="validate_schema"
    phx-debounce="500"
    class={[
      "textarea font-mono text-sm w-full h-64",
      @schema_error && "border-red-500",
      @schema_valid && "border-green-500"
    ]}
  >{Jason.encode!(@section.output_schema, pretty: true)}</textarea>

  <%= if @schema_error do %>
    <p class="text-sm text-red-600 flex items-center gap-2">
      <.icon name="hero-exclamation-circle" class="size-4" />
      {@schema_error}
    </p>
  <% end %>

  <%= if @schema_valid do %>
    <p class="text-sm text-green-600 flex items-center gap-2">
      <.icon name="hero-check-circle" class="size-4" />
      Schema is valid for Gemini API
    </p>
  <% end %>
</div>
```

### Validation Checklist

| Rule | Error Message |
|------|---------------|
| Root is object | "Root type must be 'object'" |
| Has properties | "Missing 'properties' object" |
| Valid types | "Property 'X' has invalid type 'Y'" |
| Arrays have items | "Array property 'X' must have 'items' definition" |
| Required exists | "Required fields not in properties: [...]" |
| Valid JSON | "Invalid JSON syntax" |

## Consequences

### Positive
- Catch errors at save time, not runtime
- Clear feedback on what's wrong
- Prevents bad schemas from reaching Gemini
- Visual validation state (green/red border)

### Negative
- Additional validation code to maintain
- Debounced validation adds slight delay
- Complex schemas may have edge cases

### Future Enhancements
- Schema builder UI (point-and-click)
- Schema templates for common patterns
- Import from TypeScript/OpenAPI
