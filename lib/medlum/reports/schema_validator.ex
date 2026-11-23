defmodule Medlum.Reports.SchemaValidator do
  @moduledoc """
  Validates JSON Schemas for Gemini API compatibility.

  Gemini's structured output API has specific requirements:
  - Root must be `{"type": "object"}`
  - All arrays MUST have an `items` property
  - Properties defined in `properties` object
  - `required` array must reference existing properties
  - Valid JSON Schema types only: string, number, integer, boolean, object, array

  This module provides validation at save time to catch errors before they
  reach the Gemini API at runtime.
  """

  @valid_types ["string", "number", "integer", "boolean", "object", "array"]

  @doc """
  Returns true if the schema is valid for Gemini API use.

  ## Examples

      iex> SchemaValidator.valid?(%{"type" => "object", "properties" => %{}})
      true

      iex> SchemaValidator.valid?(%{"type" => "string"})
      false
  """
  def valid?(schema), do: match?({:ok, _}, validate(schema))

  @doc """
  Validates a JSON Schema for Gemini API compatibility.

  Returns `{:ok, schema}` if valid, or `{:error, message}` with a descriptive error.

  ## Examples

      iex> SchemaValidator.validate(%{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}})
      {:ok, %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}}

      iex> SchemaValidator.validate(%{"type" => "string"})
      {:error, "Root type must be 'object'"}
  """
  def validate(schema) when is_map(schema) do
    with :ok <- validate_root_type(schema),
         :ok <- validate_properties(schema),
         :ok <- validate_required(schema),
         :ok <- validate_arrays(schema) do
      {:ok, schema}
    end
  end

  def validate(nil), do: {:error, "Schema must be a JSON object"}
  def validate(_), do: {:error, "Schema must be a JSON object"}

  # Validate that root type is "object"
  defp validate_root_type(%{"type" => "object"}), do: :ok

  defp validate_root_type(%{"type" => type}),
    do: {:error, "Root type must be 'object', got '#{type}'"}

  defp validate_root_type(_), do: {:error, "Root type must be 'object'"}

  # Validate properties object exists and each property is valid
  defp validate_properties(%{"properties" => props}) when is_map(props) do
    Enum.reduce_while(props, :ok, fn {name, spec}, :ok ->
      case validate_property(name, spec) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_properties(_), do: {:error, "Missing 'properties' object"}

  # Validate individual property
  defp validate_property(name, %{"type" => type} = spec) do
    cond do
      type not in @valid_types ->
        {:error, "Property '#{name}' has invalid type '#{type}'"}

      type == "array" and not Map.has_key?(spec, "items") ->
        {:error, "Array property '#{name}' must have 'items' definition"}

      type == "object" and Map.has_key?(spec, "properties") ->
        # Recursively validate nested object
        validate_nested_object(name, spec)

      type == "array" and Map.has_key?(spec, "items") ->
        # Validate items schema
        validate_array_items(name, Map.get(spec, "items"))

      true ->
        :ok
    end
  end

  defp validate_property(name, _) do
    {:error, "Property '#{name}' missing 'type'"}
  end

  # Validate nested object properties
  defp validate_nested_object(parent_name, %{"properties" => nested_props} = spec)
       when is_map(nested_props) do
    result =
      Enum.reduce_while(nested_props, :ok, fn {name, nested_spec}, :ok ->
        case validate_property("#{parent_name}.#{name}", nested_spec) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

    with :ok <- result do
      validate_required_for_nested(parent_name, spec)
    end
  end

  defp validate_nested_object(_, _), do: :ok

  # Validate array items schema
  defp validate_array_items(_parent_name, %{"type" => "object", "properties" => _} = items) do
    # Items is an object schema - validate it recursively
    case validate(items) do
      {:ok, _} -> :ok
      {:error, msg} -> {:error, "In array items: #{msg}"}
    end
  end

  defp validate_array_items(_parent_name, %{"type" => type}) when type in @valid_types, do: :ok

  defp validate_array_items(_parent_name, %{"type" => type}),
    do: {:error, "Array items has invalid type '#{type}'"}

  defp validate_array_items(parent_name, %{} = items) when map_size(items) == 0,
    do: {:error, "Array '#{parent_name}' items schema is empty"}

  defp validate_array_items(parent_name, _),
    do: {:error, "Array '#{parent_name}' has invalid items schema"}

  # Validate required fields exist in properties
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

  # Validate required for nested objects
  defp validate_required_for_nested(parent_name, %{"required" => required, "properties" => props})
       when is_list(required) do
    missing = Enum.reject(required, &Map.has_key?(props, &1))

    if Enum.empty?(missing) do
      :ok
    else
      {:error, "In '#{parent_name}': required fields not in properties: #{inspect(missing)}"}
    end
  end

  defp validate_required_for_nested(_, _), do: :ok

  # Find all arrays missing items definition, recursively
  defp validate_arrays(schema) do
    case find_arrays_without_items(schema) do
      [] -> :ok
      paths -> {:error, "Arrays missing 'items': #{Enum.join(paths, ", ")}"}
    end
  end

  defp find_arrays_without_items(value, path \\ "$")

  defp find_arrays_without_items(%{"type" => "array"} = spec, path) do
    has_items? = Map.has_key?(spec, "items")

    nested_paths =
      if has_items? do
        find_arrays_without_items(Map.get(spec, "items"), path <> ".items")
      else
        []
      end

    if(has_items?, do: [], else: [path]) ++ nested_paths
  end

  defp find_arrays_without_items(%{"properties" => props}, path) when is_map(props) do
    props
    |> Enum.flat_map(fn {k, v} ->
      find_arrays_without_items(v, path <> ".properties." <> k)
    end)
  end

  defp find_arrays_without_items(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {v, idx} ->
      find_arrays_without_items(v, "#{path}[#{idx}]")
    end)
  end

  defp find_arrays_without_items(_value, _path), do: []

  @doc """
  Validates a JSON string and returns the parsed schema if valid.

  This is useful for UI form validation where the schema is entered as text.

  ## Examples

      iex> SchemaValidator.validate_json("{\"type\": \"object\", \"properties\": {}}")
      {:ok, %{"type" => "object", "properties" => %{}}}

      iex> SchemaValidator.validate_json("not json")
      {:error, "Invalid JSON syntax"}
  """
  def validate_json(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, schema} ->
        validate(schema)

      {:error, _} ->
        {:error, "Invalid JSON syntax"}
    end
  end

  def validate_json(_), do: {:error, "Schema must be a JSON string"}
end
