defmodule Lumainus.LLM do
  @moduledoc """
  Facade for invoking large language models with structured-output support.

  Today this module routes requests through `gemini_ex`, but the surface area is
  intentionally small so additional providers can be wired in later without
  touching the rest of the application.
  """

  @behaviour Lumainus.LLM.Client

  alias Gemini
  alias Gemini.Types.Response.GenerateContentResponse

  @impl true
  def generate_object(model_spec, prompt_text, schema, opts \\ []) do
    case parse_model_spec(model_spec) do
      {:ok, {provider, model}} ->
        do_generate(provider, model, prompt_text, schema, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_generate("google", model, prompt_text, schema, opts) do
    request_opts = build_request_opts(model, schema, opts)

    case Gemini.generate(prompt_text, request_opts) do
      {:ok, %GenerateContentResponse{} = response} ->
        {:ok, normalize_response(response, schema)}

      {:error, error} ->
        {:error, error}
    end
  rescue
    exception ->
      {:error, Exception.message(exception)}
  end

  defp do_generate(provider, _model, _prompt_text, _schema, _opts) do
    {:error, "Unsupported provider #{inspect(provider)}"}
  end

  defp parse_model_spec(model_spec) when is_binary(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      [provider, model] when provider != "" and model != "" -> {:ok, {provider, model}}
      [model] when model != "" -> {:ok, {"google", model}}
      _ -> {:error, "Invalid model specification: #{inspect(model_spec)}"}
    end
  end

  defp parse_model_spec(_), do: {:error, "Invalid model specification"}

  @doc false
  def build_request_opts(model, schema, opts) do
    []
    |> Keyword.put(:model, model)
    # Sampling parameters
    |> maybe_put(:temperature, Keyword.get(opts, :temperature))
    |> maybe_put(:max_output_tokens, Keyword.get(opts, :max_output_tokens))
    |> maybe_put(:top_p, Keyword.get(opts, :top_p))
    |> maybe_put(:top_k, Keyword.get(opts, :top_k))
    |> maybe_put(:candidate_count, Keyword.get(opts, :candidate_count))
    # Context
    |> maybe_put(:system_instruction, Keyword.get(opts, :system_instruction))
    |> maybe_put(:seed, Keyword.get(opts, :seed))
    # Constraints
    |> maybe_put(:stop_sequences, Keyword.get(opts, :stop_sequences))
    |> maybe_put(:presence_penalty, Keyword.get(opts, :presence_penalty))
    |> maybe_put(:frequency_penalty, Keyword.get(opts, :frequency_penalty))
    # Response format
    |> maybe_put(:response_schema, schema)
    |> maybe_put(:response_mime_type, determine_response_mime_type(schema, opts))
  end

  # Determine response MIME type:
  # 1. If schema is provided, use "application/json" (Gemini requirement)
  # 2. Otherwise, use the response_mime_type from opts if provided
  # 3. Default to nil (let Gemini decide)
  defp determine_response_mime_type(schema, _opts) when is_map(schema) and map_size(schema) > 0 do
    "application/json"
  end

  defp determine_response_mime_type(_, opts) do
    Keyword.get(opts, :response_mime_type)
  end

  defp normalize_response(%GenerateContentResponse{} = response, schema) do
    text = extract_text(response)

    %{
      "object" => decode_object(text, schema),
      "text" => text,
      "usage" => usage_map(response),
      "request_id" => nil
    }
  end

  defp extract_text(%GenerateContentResponse{} = response) do
    case Gemini.extract_text(response) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  defp decode_object(text, schema) when is_map(schema) do
    with {:ok, object} <- Jason.decode(to_string(text)) do
      stringify_keys(object)
    else
      _ -> default_object(text)
    end
  end

  defp decode_object(text, _schema), do: default_object(text)

  defp default_object(text) when is_binary(text) and text != "" do
    %{"markdown" => text}
  end

  defp default_object(_text), do: %{}

  defp usage_map(%GenerateContentResponse{usage_metadata: usage}) when is_map(usage) do
    %{
      "total_tokens" => Map.get(usage, :total_token_count),
      "input_tokens" => Map.get(usage, :prompt_token_count),
      "output_tokens" => Map.get(usage, :candidates_token_count),
      "cached_input_tokens" => Map.get(usage, :cached_content_token_count)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp usage_map(_), do: %{}

  defp stringify_keys(value) when is_map(value) do
    value
    |> Enum.map(fn {key, val} -> {to_string(key), stringify_keys(val)} end)
    |> Enum.into(%{})
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
