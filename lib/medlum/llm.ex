defmodule Medlum.LLM do
  @moduledoc """
  Facade for invoking large language models with structured-output support.

  Today this module routes requests through `gemini_ex`, but the surface area is
  intentionally small so additional providers can be wired in later without
  touching the rest of the application.
  """

  @behaviour Medlum.LLM.Client

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
    finish_message = extract_finish_message(response)
    {has_content, parts_count} = extract_response_metadata(response)

    %{
      "object" => object,
      "text" => text,
      "usage" => usage_map(response),
      "request_id" => nil,
      "repair_status" => repair_status,
      "finish_reason" => finish_reason,
      "finish_message" => finish_message,
      "has_content" => has_content,
      "parts_count" => parts_count,
      # gemini_ex 0.6.4+ fields
      "response_id" => response.response_id,
      "model_version" => response.model_version,
      "thoughts_token_count" => extract_thoughts_token_count(response),
      "traffic_type" => extract_traffic_type(response)
    }
  end

  # Extract finish_reason from the first candidate
  defp extract_finish_reason(%GenerateContentResponse{candidates: [%{finish_reason: reason} | _]}) do
    reason
  end

  defp extract_finish_reason(_), do: nil

  # Extract finish_message from the first candidate (gemini_ex 0.6.4+)
  defp extract_finish_message(%GenerateContentResponse{candidates: [%{finish_message: msg} | _]})
       when is_binary(msg) do
    msg
  end

  defp extract_finish_message(_), do: nil

  # Extract thoughts_token_count from usage_metadata (gemini_ex 0.6.4+)
  defp extract_thoughts_token_count(%GenerateContentResponse{
         usage_metadata: %{thoughts_token_count: count}
       })
       when is_integer(count) do
    count
  end

  defp extract_thoughts_token_count(_), do: nil

  # Extract traffic_type from usage_metadata (gemini_ex 0.6.4+)
  defp extract_traffic_type(%GenerateContentResponse{usage_metadata: %{traffic_type: type}})
       when not is_nil(type) do
    to_string(type)
  end

  defp extract_traffic_type(_), do: nil

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

  @doc """
  Start a streaming LLM generation.

  Returns `{:ok, stream_id}` immediately. The caller process will receive
  messages as chunks arrive:

    - `{:llm_stream_chunk, stream_id, chunk_data}` - Text chunk received
    - `{:llm_stream_complete, stream_id, final_response}` - Stream finished
    - `{:llm_stream_error, stream_id, error}` - Stream failed

  ## Parameters
    - `model_spec` - Provider:model string (e.g., "google:gemini-2.0-flash")
    - `prompt_text` - The prompt to send
    - `schema` - JSON schema for structured output (or nil)
    - `subscriber_pid` - Process to receive stream events
    - `opts` - Options (same as generate_object/4)
  """
  @impl true
  @spec stream_generate(String.t(), String.t(), map() | nil, pid(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def stream_generate(model_spec, prompt_text, schema, subscriber_pid, opts \\ []) do
    case parse_model_spec(model_spec) do
      {:ok, {provider, model}} ->
        do_stream_generate(provider, model, prompt_text, schema, subscriber_pid, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_stream_generate("google", model, prompt_text, schema, subscriber_pid, opts) do
    request_opts = build_request_opts(model, schema, opts)
    request_body = build_stream_request_body(prompt_text, request_opts)

    case Gemini.Streaming.UnifiedManager.start_stream(model, request_body, []) do
      {:ok, stream_id} ->
        # Spawn translator process (NOT linked - we handle crashes gracefully)
        # This prevents translator crashes from killing the parent process
        spawn(fn ->
          try do
            :ok = Gemini.Streaming.UnifiedManager.subscribe(stream_id, self())
            stream_event_translator(stream_id, subscriber_pid, schema)
          rescue
            error ->
              Logger.error(
                "[LLM] Stream translator crashed: #{inspect(error)}\n" <>
                  Exception.format_stacktrace(__STACKTRACE__)
              )

              send(
                subscriber_pid,
                {:llm_stream_error, stream_id,
                 %{
                   type: :translator_crash,
                   message: "Stream translator process crashed: #{inspect(error)}"
                 }}
              )
          catch
            kind, reason ->
              Logger.error("[LLM] Stream translator caught #{kind}: #{inspect(reason)}")

              send(
                subscriber_pid,
                {:llm_stream_error, stream_id,
                 %{
                   type: :translator_crash,
                   message: "Stream translator caught #{kind}: #{inspect(reason)}"
                 }}
              )
          end
        end)

        {:ok, stream_id}

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp do_stream_generate(provider, _model, _prompt_text, _schema, _subscriber_pid, _opts) do
    {:error, "Unsupported provider #{inspect(provider)} for streaming"}
  end

  defp build_stream_request_body(prompt_text, request_opts) do
    # Build contents array
    contents = [%{parts: [%{text: prompt_text}]}]

    # Extract system instruction if present
    system_instruction = Keyword.get(request_opts, :system_instruction)
    cached_content = Keyword.get(request_opts, :cached_content)

    # Build generation config
    generation_config =
      []
      |> maybe_put_generation(:temperature, Keyword.get(request_opts, :temperature))
      |> maybe_put_generation(:maxOutputTokens, Keyword.get(request_opts, :max_output_tokens))
      |> maybe_put_generation(:topP, Keyword.get(request_opts, :top_p))
      |> maybe_put_generation(:topK, Keyword.get(request_opts, :top_k))
      |> maybe_put_generation(:candidateCount, Keyword.get(request_opts, :candidate_count))
      |> maybe_put_generation(:stopSequences, Keyword.get(request_opts, :stop_sequences))
      |> maybe_put_generation(:presencePenalty, Keyword.get(request_opts, :presence_penalty))
      |> maybe_put_generation(:frequencyPenalty, Keyword.get(request_opts, :frequency_penalty))
      |> maybe_put_generation(:responseMimeType, Keyword.get(request_opts, :response_mime_type))
      |> maybe_put_generation(:responseSchema, Keyword.get(request_opts, :response_schema))
      |> maybe_put_generation(:seed, Keyword.get(request_opts, :seed))
      |> maybe_put_generation(:thinkingConfig, Keyword.get(request_opts, :thinking_config))
      |> Map.new()

    # Build request body
    body = %{contents: contents}

    body =
      if system_instruction do
        Map.put(body, :systemInstruction, %{parts: [%{text: system_instruction}]})
      else
        body
      end

    body =
      if cached_content do
        Map.put(body, :cachedContent, cached_content)
      else
        body
      end

    body =
      if map_size(generation_config) > 0 do
        Map.put(body, :generationConfig, generation_config)
      else
        body
      end

    body
  end

  defp maybe_put_generation(list, _key, nil) when is_list(list), do: list

  defp maybe_put_generation(list, key, value) when is_list(list) do
    [{key, value} | list]
  end

  defp stream_event_translator(stream_id, subscriber_pid, schema) do
    accumulator = %{
      text_chunks: [],
      usage: nil,
      finish_reason: nil,
      finish_message: nil
    }

    stream_event_loop(stream_id, subscriber_pid, schema, accumulator)
  end

  defp stream_event_loop(stream_id, subscriber_pid, schema, acc) do
    receive do
      {:stream_event, ^stream_id, %{type: :data, data: data}} ->
        text = extract_chunk_text(data)
        usage = extract_chunk_usage(data)
        finish_reason = extract_chunk_finish_reason(data)
        finish_message = extract_chunk_finish_message(data)

        if text && text != "" do
          send(
            subscriber_pid,
            {:llm_stream_chunk, stream_id,
             %{
               text: text,
               usage: usage
             }}
          )
        end

        new_acc = %{
          acc
          | text_chunks: if(text, do: acc.text_chunks ++ [text], else: acc.text_chunks),
            usage: usage || acc.usage,
            finish_reason: finish_reason || acc.finish_reason,
            finish_message: finish_message || acc.finish_message
        }

        stream_event_loop(stream_id, subscriber_pid, schema, new_acc)

      {:stream_complete, ^stream_id} ->
        full_text = Enum.join(acc.text_chunks, "")

        final_response =
          build_final_response(
            full_text,
            acc.usage,
            acc.finish_reason,
            acc.finish_message,
            schema
          )

        send(subscriber_pid, {:llm_stream_complete, stream_id, final_response})

      {:stream_error, ^stream_id, error} ->
        send(subscriber_pid, {:llm_stream_error, stream_id, normalize_error(error)})
    after
      600_000 ->
        send(
          subscriber_pid,
          {:llm_stream_error, stream_id,
           %{
             type: :timeout,
             message: "Stream timed out after 10 minutes"
           }}
        )
    end
  end

  defp extract_chunk_text(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]}) do
    parts
    |> Enum.map_join("", fn
      %{"text" => text} -> text
      _ -> ""
    end)
  end

  defp extract_chunk_text(_), do: nil

  defp extract_chunk_usage(%{"usageMetadata" => usage}) when is_map(usage) do
    %{
      "total_tokens" => Map.get(usage, "totalTokenCount"),
      "input_tokens" => Map.get(usage, "promptTokenCount"),
      "output_tokens" => Map.get(usage, "candidatesTokenCount"),
      "cached_input_tokens" => Map.get(usage, "cachedContentTokenCount")
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp extract_chunk_usage(_), do: nil

  defp extract_chunk_finish_reason(%{"candidates" => [%{"finishReason" => reason} | _]}) do
    reason
  end

  defp extract_chunk_finish_reason(_), do: nil

  defp extract_chunk_finish_message(%{"candidates" => [%{"finishMessage" => msg} | _]})
       when is_binary(msg) do
    msg
  end

  defp extract_chunk_finish_message(_), do: nil

  defp build_final_response(full_text, usage, finish_reason, finish_message, schema) do
    {object, repair_status} = decode_object(full_text, schema)

    %{
      "object" => object,
      "text" => full_text,
      "usage" => usage || %{},
      "request_id" => nil,
      "repair_status" => repair_status,
      "finish_reason" => finish_reason,
      "finish_message" => finish_message,
      "has_content" => full_text != "",
      "parts_count" => if(full_text != "", do: 1, else: 0),
      "response_id" => nil,
      "model_version" => nil,
      "thoughts_token_count" => nil,
      "traffic_type" => nil
    }
  end
end
