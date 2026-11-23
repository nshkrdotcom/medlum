defmodule Medlum.LLM.Client do
  @moduledoc """
  Behaviour for LLM adapters that generate structured responses for report sections.

  ## Return Values

  Functions may return:
  - `{:ok, result}` - Success
  - `{:error, term()}` - General error
  - `{:error, {:rate_limited, retry_after, details}}` - Rate limited (can retry)

  ## Rate Limiting

  Clients should expose rate limiting state via `check_rate_limit/2` to allow
  callers to make pre-flight decisions.
  """

  @type rate_limit_result ::
          :ok
          | {:would_exceed, map()}

  @doc """
  Generate a structured object from prompt text.

  Returns `{:ok, map}` on success, or `{:error, term}` on failure.
  Rate limit errors return `{:error, {:rate_limited, retry_after, details}}`.
  """
  @callback generate_object(String.t(), String.t(), map() | nil, keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Start streaming generation.

  Returns `{:ok, stream_id}` on success, or `{:error, term}` on failure.
  """
  @callback stream_generate(String.t(), String.t(), map() | nil, pid(), keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Check if a request would be rate limited.

  Returns `:ok` if request can proceed, or `{:would_exceed, details}` if it would
  exceed rate limits.
  """
  @callback check_rate_limit(String.t(), non_neg_integer()) :: rate_limit_result()

  @optional_callbacks [stream_generate: 5, check_rate_limit: 2]
end
