# 03: Explicit Rate Limiting Dependency

## Problem

`SectionRunner` calls LLM clients without any awareness of rate limiting:

```elixir
# section_runner.ex:263
AI.client().stream_generate(model_spec, prompt_text, schema, self(), options)

# section_runner.ex:363
AI.client().generate_object(model_spec, prompt_text, schema, options)
```

Rate limiting is an **implicit dependency** - SectionRunner trusts the client to handle it. But:

1. Streaming client doesn't handle it
2. No visibility into rate limit status
3. No ability to react to rate limiting at application level
4. No telemetry for rate limit events

## Current State

```
SectionRunner
    |
    +-- "Trust client handles rate limiting"
    |
    +-- AI.client() <-- Interface doesn't expose rate limiting
           |
           +-- LLM module <-- May or may not rate limit
                  |
                  +-- gemini_ex <-- Rate limits non-streaming only
```

## Proposed Solution

### Make Rate Limiting Explicit in Client Interface

```elixir
# lib/lumainus/llm/client.ex

@callback generate_object(model_spec, prompt, schema, opts) ::
  {:ok, response} | {:error, term()} | {:rate_limited, retry_after, details}

@callback stream_generate(model_spec, prompt, schema, subscriber, opts) ::
  {:ok, stream_id} | {:error, term()} | {:rate_limited, retry_after, details}

@callback check_rate_limit(model_spec, estimated_tokens) ::
  :ok | {:would_exceed, details}
```

### SectionRunner Handles Rate Limiting Explicitly

```elixir
# lib/lumainus/ai/section_runner.ex

defp invoke_llm(model_spec, prompt_text, schema, options) do
  client = AI.client()

  # Check before calling
  case client.check_rate_limit(model_spec, estimate_tokens(prompt_text)) do
    :ok ->
      do_invoke(client, model_spec, prompt_text, schema, options)

    {:would_exceed, details} ->
      Logger.warning("Rate limit would be exceeded", details)
      handle_rate_limit_preemptive(details)
  end
end

defp do_invoke(client, model_spec, prompt_text, schema, options) do
  case client.generate_object(model_spec, prompt_text, schema, options) do
    {:ok, response} ->
      {:ok, response}

    {:rate_limited, retry_after, details} ->
      # Explicit handling - can retry, backoff, or fail
      handle_rate_limited(retry_after, details)

    {:error, error} ->
      {:error, error}
  end
end
```

### Update LLM Module to Return Rate Limit Info

```elixir
# lib/lumainus/llm.ex

def generate_object(model_spec, prompt_text, schema, opts \\ []) do
  case do_generate(provider, model, prompt_text, schema, opts) do
    {:ok, response} ->
      {:ok, response}

    {:error, %Gemini.Error{type: :rate_limited} = error} ->
      {:rate_limited, error.retry_after, %{
        model: model,
        quota_metric: error.quota_metric
      }}

    {:error, error} ->
      {:error, error}
  end
end

def check_rate_limit(model_spec, estimated_tokens) do
  {_provider, model} = parse_model_spec(model_spec)

  case Gemini.RateLimiter.check_status(model, estimated_input_tokens: estimated_tokens) do
    :ok -> :ok
    {:rate_limited, _, details} -> {:would_exceed, details}
    {:over_budget, details} -> {:would_exceed, details}
    {:no_permits, _} -> {:would_exceed, %{reason: :concurrency_full}}
  end
end
```

## Benefits

1. **Explicit dependency** - Rate limiting is visible in interfaces
2. **Application-level control** - Can decide how to handle rate limits
3. **Better error handling** - Distinguish rate limits from other errors
4. **Pre-flight checks** - Can check before attempting
5. **Clearer testing** - Mock rate limit responses explicitly

## Migration

### Phase 1: Extend Client Interface

1. Add `check_rate_limit/2` to client behavior
2. Update return types to include `:rate_limited` tuple
3. Implement in `LLM` module

### Phase 2: Update SectionRunner

1. Add rate limit handling in `invoke_llm/4`
2. Add rate limit handling in `invoke_llm_streaming/5`
3. Emit telemetry for rate limit events

### Phase 3: Update Mock Client

1. Add rate limit simulation to mock
2. Add tests for rate limit scenarios

## Files to Modify

- `lib/lumainus/llm/client.ex` - Extended interface
- `lib/lumainus/llm.ex` - Implement new methods
- `lib/lumainus/llm/mock_client.ex` - Mock implementation
- `lib/lumainus/ai/section_runner.ex` - Handle rate limits

## Testing

1. Mock client returns `:rate_limited` - verify handled
2. Pre-flight check fails - verify section not attempted
3. Rate limit during streaming - verify cleanup
