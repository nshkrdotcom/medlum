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

  require Logger

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

    case gemini_generate(prompt_text, request_opts) do
      {:ok, %GenerateContentResponse{} = response} ->
        {:ok, normalize_response(response, schema)}

      {:error, error} ->
        {:error, normalize_error(error)}
    end
  rescue
    exception ->
      {:error, Exception.message(exception)}
  end

  defp do_generate(provider, _model, _prompt_text, _schema, _opts) do
    {:error, "Unsupported provider #{inspect(provider)}"}
  end

  @spec gemini_generate(String.t(), keyword()) ::
          {:ok, GenerateContentResponse.t()} | {:error, term()}
  defp gemini_generate(prompt_text, request_opts) do
    :erlang.apply(Gemini, :generate, [prompt_text, request_opts])
  end

  @spec normalize_error(term()) :: term()
  defp normalize_error({:rate_limited, retry_at, details}) do
    wrap_rate_limit_error(retry_at, details)
  end

  defp normalize_error({:transient_failure, attempts, original_error}) do
    wrap_transient_error(attempts, original_error)
  end

  defp normalize_error(%Gemini.Error{type: type, details: details})
       when type in [:rate_limit, :rate_limited] do
    wrap_rate_limit_error(extract_retry_at(details), details)
  end

  defp normalize_error(%Gemini.Error{
         type: :transient_failure,
         details: details,
         original_error: original
       }) do
    attempts = extract_attempts(details)
    wrap_transient_error(attempts, original || details)
  end

  defp normalize_error(error), do: error

  # Wrap rate-limited tuple into a consistent error map for SectionRunner
  defp wrap_rate_limit_error(retry_at, details) do
    details = details || %{}
    reason = Map.get(details, :reason) || Map.get(details, "reason") || :unknown

    %{
      type: :rate_limit,
      message: rate_limit_message(reason, retry_at),
      retry_at: retry_at,
      reason: reason,
      details: details
    }
  end

  defp rate_limit_message(:over_budget, retry_at) do
    "Token budget exceeded. Retry after #{format_retry_at(retry_at)}"
  end

  defp rate_limit_message(:retry_window, retry_at) do
    "Rate limited by API. Retry after #{format_retry_at(retry_at)}"
  end

  defp rate_limit_message(_reason, retry_at) do
    "Rate limited. Retry after #{format_retry_at(retry_at)}"
  end

  defp format_retry_at(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_retry_at(other), do: inspect(other)

  # Wrap transient failure tuple into a consistent error map
  defp wrap_transient_error(attempts, original_error) do
    %{
      type: :transient_failure,
      message: "Request failed after #{attempts} attempts",
      attempts: attempts,
      original_error: original_error
    }
  end

  defp extract_retry_at(%{} = details) do
    Map.get(details, :retry_at) ||
      Map.get(details, "retry_at") ||
      Map.get(details, :retry_after) ||
      Map.get(details, "retry_after")
  end

  defp extract_retry_at(_), do: nil

  defp extract_attempts(%{} = details) do
    Map.get(details, :attempts) || Map.get(details, "attempts") || 1
  end

  defp extract_attempts(_), do: 1

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
    # Context caching (gemini_ex 0.6.0+)
    |> maybe_put(:cached_content, Keyword.get(opts, :cached_content))
    # Constraints
    |> maybe_put(:stop_sequences, Keyword.get(opts, :stop_sequences))
    |> maybe_put(:presence_penalty, Keyword.get(opts, :presence_penalty))
    |> maybe_put(:frequency_penalty, Keyword.get(opts, :frequency_penalty))
    # Response format
    |> maybe_put(:response_schema, schema)
    |> maybe_put(:response_mime_type, determine_response_mime_type(schema, opts))
    # Thinking config - minimize thinking by default for structured output to prevent
    # thinking tokens from consuming the output budget (Gemini 2.5 enables thinking by default)
    |> maybe_put(:thinking_config, determine_thinking_config(model, opts))
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

  # Determine thinking config:
  # 1. If explicitly provided in opts, use that
  # 2. Otherwise, minimize thinking to reduce token costs:
  #    - Pro models: use 128 (minimum allowed, Pro cannot disable thinking)
  #    - Flash/other models: use 0 (disable thinking entirely)
  defp determine_thinking_config(model, opts) do
    case Keyword.get(opts, :thinking_config) do
      nil -> %{thinking_budget: default_thinking_budget(model)}
      config -> config
    end
  end

  defp default_thinking_budget(model) when is_binary(model) do
    if String.contains?(model, "pro") do
      # Pro models cannot disable thinking, 128 is minimum
      128
    else
      # Flash/Lite models can disable thinking
      0
    end
  end

  defp default_thinking_budget(_), do: 0

  defp normalize_response(%GenerateContentResponse{} = response, schema) do
    text = extract_text(response)
    {object, repair_status} = decode_object(text, schema)
    finish_reason = extract_finish_reason(response)
    {has_content, parts_count} = extract_response_metadata(response)

    %{
      "object" => object,
      "text" => text,
      "usage" => usage_map(response),
      "request_id" => nil,
      "repair_status" => repair_status,
      "finish_reason" => finish_reason,
      "has_content" => has_content,
      "parts_count" => parts_count
    }
  end

  # Extract finish_reason from the first candidate
  defp extract_finish_reason(%GenerateContentResponse{candidates: [%{finish_reason: reason} | _]}) do
    reason
  end

  defp extract_finish_reason(_), do: nil

  # Extract metadata about response content
  # Returns {has_content, parts_count}
  defp extract_response_metadata(%GenerateContentResponse{candidates: [candidate | _]}) do
    case candidate do
      %{content: nil} ->
        {false, 0}

      %{content: %{parts: nil}} ->
        {false, 0}

      %{content: %{parts: parts}} when is_list(parts) ->
        {length(parts) > 0, length(parts)}

      _ ->
        {false, 0}
    end
  end

  defp extract_response_metadata(_), do: {false, 0}

  defp extract_text(%GenerateContentResponse{} = response) do
    case Gemini.extract_text(response) do
      {:ok, text} ->
        text

      {:error, reason} ->
        # Log the error instead of silently swallowing it
        finish = extract_finish_reason(response)
        {has_content, parts_count} = extract_response_metadata(response)

        Logger.warning("""
        [LLM] extract_text failed: #{reason}
          finish_reason: #{inspect(finish)}
          has_content: #{has_content}
          parts_count: #{parts_count}
          usage: #{inspect(usage_map(response))}
        """)

        ""
    end
  end

  # Decode JSON response with repair fallback via JsonRemedy
  # Returns {object, repair_status} where repair_status is "none", "repaired", or "failed"
  defp decode_object(text, schema) when is_map(schema) do
    text_str = to_string(text)

    case Jason.decode(text_str) do
      {:ok, object} ->
        # Clean decode - no repair needed
        {stringify_keys(object), "none"}

      {:error, _} ->
        # Jason failed - try JsonRemedy repair
        try_json_repair(text_str)
    end
  end

  defp decode_object(text, _schema) do
    text_str = to_string(text)

    # No schema - still try to decode if it looks like JSON
    if String.trim(text_str) |> String.starts_with?("{") do
      case Jason.decode(text_str) do
        {:ok, object} -> {stringify_keys(object), "none"}
        {:error, _} -> try_json_repair(text_str)
      end
    else
      {default_object(text_str), "none"}
    end
  end

  # Attempt JSON repair using JsonRemedy
  defp try_json_repair(text) when is_binary(text) and text != "" do
    trimmed = String.trim(text)

    case JsonRemedy.repair(trimmed, fast_path_optimization: false, logging: true) do
      {:ok, repaired, logs} when is_list(logs) ->
        repair_status = if length(logs) > 0, do: "repaired", else: "none"

        if repair_status == "repaired" do
          Logger.info("[LLM] JSON repaired with #{length(logs)} fixes: #{inspect(logs)}")
        end

        {stringify_keys(repaired), repair_status}

      {:ok, repaired} ->
        # JsonRemedy without logs - assume repair happened since Jason failed
        Logger.info("[LLM] JSON repaired (no log details)")
        {stringify_keys(repaired), "repaired"}

      {:error, reason} ->
        # JsonRemedy failed to repair - wrap as markdown fallback
        Logger.warning("[LLM] JSON repair failed: #{inspect(reason)}, using markdown fallback")
        {default_object(text), "failed"}
    end
  end

  defp try_json_repair(_text), do: {%{}, "failed"}

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
