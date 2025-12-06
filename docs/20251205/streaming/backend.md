# Backend Streaming Implementation Design

## Executive Summary

This document details the backend implementation for streaming LLM responses in the Lumainus Phoenix/Elixir application. The design leverages existing `gemini_ex` streaming infrastructure (`HTTPStreaming.stream_to_process/6` and `UnifiedManager`) while maintaining backward compatibility with the current non-streaming implementation.

---

## Current Architecture

### Data Flow (Non-Streaming)

```
                                   +-----------------+
                                   |   ReportsLive   |
                                   | (LiveView)      |
                                   +--------+--------+
                                            |
                      1. run_sections()     |
                                            v
                                   +-----------------+
                                   |    Reports      |
                                   | Context         |
                                   +--------+--------+
                                            |
                      2. Oban.insert()      |
                                            v
                                   +-----------------+
                                   | SectionRunWorker|
                                   | (Oban Worker)   |
                                   +--------+--------+
                                            |
                      3. run_section()      |
                                            v
                                   +-----------------+
                                   | SectionRunner   |
                                   +--------+--------+
                                            |
                      4. invoke_llm()       |
                                            v
                                   +-----------------+
                                   |  Lumainus.LLM   |
                                   +--------+--------+
                                            |
                      5. generate_object()  |
                                            v
                                   +-----------------+
                                   | Gemini.generate |
                                   | (gemini_ex)     |
                                   +-----------------+
```

### Key Files and Their Responsibilities

| File | Current Role |
|------|--------------|
| `lib/lumainus/llm.ex` | Facade for LLM calls, normalizes responses, handles errors |
| `lib/lumainus/ai/section_runner.ex` | Orchestrates section generation, builds prompts, persists results |
| `lib/lumainus/reports/section_run_worker.ex` | Oban worker that triggers section runs asynchronously |
| `lib/lumainus/reports.ex` | Context module with PubSub patterns |

### Existing PubSub Pattern

```elixir
# Topic naming
@run_topic_prefix "report-run"
defp run_topic(record_set_id), do: "#{@run_topic_prefix}:#{record_set_id}"

# Subscription
PubSub.subscribe(LumainusWeb.PubSub, run_topic(record_set_id))

# Notification (section completion)
PubSub.broadcast(
  LumainusWeb.PubSub,
  run_topic(record_set_id),
  {:section_run_updated, record_set_id}
)
```

---

## Streaming Architecture

### Data Flow (Streaming)

```
                                   +-----------------+
                                   |   ReportsLive   |
                                   | (LiveView)      |<------------+
                                   +--------+--------+             |
                                            |                      |
                      1. run_sections()     |                      |
                         stream: true       |                      |
                                            v                      |
                                   +-----------------+             |
                                   |    Reports      |             | 6. PubSub broadcasts
                                   | Context         |             |    {:llm_chunk, ...}
                                   +--------+--------+             |    {:section_run_updated}
                                            |                      |
                      2. Oban.insert()      |                      |
                         stream: true       |                      |
                                            v                      |
                                   +-----------------+             |
                                   | SectionRunWorker|-------------+
                                   | (Oban Worker)   |
                                   +--------+--------+
                                            |
                      3. run_section_streaming()
                                            |
                                            v
                                   +-----------------+
                                   | SectionRunner   |
                                   | (handles events)|
                                   +--------+--------+
                                            |
                      4. stream_generate()  |
                                            v
                                   +-----------------+
                                   |  Lumainus.LLM   |
                                   +--------+--------+
                                            |
                      5. UnifiedManager     |
                         .start_stream()    |
                                            v
                                   +-----------------+
                                   | gemini_ex       |
                                   | HTTPStreaming   |
                                   +-----------------+
```

---

## Implementation Details

### 1. LLM Module Changes (`lib/lumainus/llm.ex`)

#### New Streaming Function

```elixir
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

  case Gemini.Streaming.UnifiedManager.start_stream(model, request_body, opts) do
    {:ok, stream_id} ->
      :ok = Gemini.Streaming.UnifiedManager.subscribe(stream_id, subscriber_pid)

      spawn_link(fn ->
        stream_event_translator(stream_id, subscriber_pid, schema)
      end)

      {:ok, stream_id}

    {:error, reason} ->
      {:error, normalize_error(reason)}
  end
end
```

#### Stream Event Translation

```elixir
defp stream_event_translator(stream_id, subscriber_pid, schema) do
  :ok = Gemini.Streaming.UnifiedManager.subscribe(stream_id, self())

  accumulator = %{
    text_chunks: [],
    usage: nil,
    finish_reason: nil
  }

  stream_event_loop(stream_id, subscriber_pid, schema, accumulator)
end

defp stream_event_loop(stream_id, subscriber_pid, schema, acc) do
  receive do
    {:stream_event, ^stream_id, %{type: :data, data: data}} ->
      text = extract_chunk_text(data)
      usage = extract_chunk_usage(data)
      finish_reason = extract_chunk_finish_reason(data)

      if text && text != "" do
        send(subscriber_pid, {:llm_stream_chunk, stream_id, %{
          text: text,
          usage: usage
        }})
      end

      new_acc = %{acc |
        text_chunks: if(text, do: acc.text_chunks ++ [text], else: acc.text_chunks),
        usage: usage || acc.usage,
        finish_reason: finish_reason || acc.finish_reason
      }

      stream_event_loop(stream_id, subscriber_pid, schema, new_acc)

    {:stream_complete, ^stream_id} ->
      full_text = Enum.join(acc.text_chunks, "")
      final_response = build_final_response(full_text, acc.usage, acc.finish_reason, schema)
      send(subscriber_pid, {:llm_stream_complete, stream_id, final_response})

    {:stream_error, ^stream_id, error} ->
      send(subscriber_pid, {:llm_stream_error, stream_id, normalize_error(error)})

  after
    600_000 ->
      send(subscriber_pid, {:llm_stream_error, stream_id, %{
        type: :timeout,
        message: "Stream timed out after 10 minutes"
      }})
  end
end
```

### 2. SectionRunner Changes (`lib/lumainus/ai/section_runner.ex`)

#### New Streaming Entry Point

```elixir
@doc """
Run a section with streaming output.

Unlike `run_section/5`, this function:
1. Immediately marks the section as "running"
2. Broadcasts text chunks via PubSub as they arrive
3. Accumulates the full response for final persistence
"""
@spec run_section_streaming(Scope.t(), ReportSectionRun.t(), Patient.t(), [DocumentUpload.t()], keyword()) ::
        {:ok, ReportSectionRun.t()} | {:error, ReportSectionRun.t()}
def run_section_streaming(scope, %ReportSectionRun{} = section_run, patient, documents, opts \\ []) do
  # ... setup code same as run_section ...

  record_set_id = report_run.record_set_id
  section_run_id = section_run.id

  case invoke_llm_streaming(model_spec, prompt_text, schema, options, %{
         record_set_id: record_set_id,
         section_run_id: section_run_id
       }) do
    {:ok, stream_id} ->
      handle_stream_events(
        stream_id,
        section_run,
        llm,
        prompt_context,
        doc_payloads,
        started,
        record_set_id
      )

    {:error, reason} ->
      {:error, persist_failure(section_run, llm, reason, ...)}
  end
end
```

#### Stream Event Handler with PubSub Broadcast

```elixir
defp handle_stream_events(stream_id, section_run, llm, prompt_context, doc_payloads, started, record_set_id) do
  receive do
    {:llm_stream_chunk, ^stream_id, chunk} ->
      broadcast_chunk(record_set_id, section_run.id, chunk)
      handle_stream_events(stream_id, section_run, llm, prompt_context, doc_payloads, started, record_set_id)

    {:llm_stream_complete, ^stream_id, response} ->
      duration = duration_ms(started)
      normalized = normalize_response(response)
      {:ok, persist_success(section_run, llm, normalized, prompt_context, doc_payloads, duration)}

    {:llm_stream_error, ^stream_id, reason} ->
      duration = duration_ms(started)
      {:error, persist_failure(section_run, llm, reason, ...)}

  after
    600_000 ->
      {:error, persist_failure(section_run, llm, %{type: :timeout}, ...)}
  end
end

defp broadcast_chunk(record_set_id, section_run_id, chunk) do
  Phoenix.PubSub.broadcast(
    LumainusWeb.PubSub,
    "report-run:#{record_set_id}",
    {:llm_chunk, %{
      section_run_id: section_run_id,
      text: chunk.text,
      usage: chunk.usage
    }}
  )
end
```

### 3. Worker Changes (`lib/lumainus/reports/section_run_worker.ex`)

```elixir
@impl true
def perform(%Oban.Job{args: %{"section_run_id" => section_run_id} = args}) do
  stream? = Map.get(args, "stream", false)

  # ... existing preload code ...

  result =
    if stream? do
      SectionRunner.run_section_streaming(scope, section_run, patient, documents)
    else
      SectionRunner.run_section(scope, section_run, patient, documents)
    end

  RunReconciler.maybe_finalize(report_run.id)
  Reports.notify_section_run_update(report_run.record_set_id)

  case result do
    {:ok, _run} -> :ok
    {:error, _run} -> :ok
  end
end
```

### 4. Reports Context Changes (`lib/lumainus/reports.ex`)

```elixir
def run_sections(%Scope{} = scope, patient, record_set, template, section_ids, opts \\ []) do
  stream? = Keyword.get(opts, :stream, false)

  # ... existing code ...

  case enqueue_section_runs(run, section_runs, Keyword.put(opts, :stream, stream?)) do
    # ...
  end
end

defp enqueue_section_runs(run, section_runs, opts) do
  stream? = Keyword.get(opts, :stream, false)

  Enum.reduce_while(section_runs, :ok, fn section_run, _acc ->
    job_args = %{"section_run_id" => section_run.id}
    job_args = if stream?, do: Map.put(job_args, "stream", true), else: job_args

    # ... rest of enqueue logic
  end)
end
```

---

## PubSub Messages

| Message | Purpose |
|---------|---------|
| `{:section_run_updated, record_set_id}` | Existing - section completed |
| `{:llm_chunk, %{section_run_id, text, usage}}` | New - streaming chunk |

---

## Error Handling

| Scenario | Handling |
|----------|----------|
| Network timeout | Retry via Oban (max 3 attempts) |
| Rate limiting | Oban snooze with backoff |
| Malformed response | JSON repair, fallback to markdown |
| Process crash | Oban marks failed, can retry |
| Stream interruption | Broadcast error, clean up |

---

## Migration Path

### Phase 1: Add Infrastructure (No Breaking Changes)
1. Add `stream_generate/5` to `Lumainus.LLM`
2. Add `run_section_streaming/5` to `SectionRunner`
3. Add `stream` parameter to worker args
4. Add new PubSub message types

### Phase 2: Feature Flag
```elixir
defp streaming_enabled? do
  Application.get_env(:lumainus, :features, [])
  |> Keyword.get(:llm_streaming, false)
end
```

### Phase 3: Gradual Rollout
1. Enable for internal testing
2. Add UI toggle
3. Default to streaming
