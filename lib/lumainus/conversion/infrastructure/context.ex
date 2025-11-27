defmodule Lumainus.Conversion.Infrastructure.Context do
  @moduledoc """
  Request context for correlation and tracing.

  Stores trace_id, span_id, and correlation_id in process dictionary
  for easy access throughout a request lifecycle.

  ## Usage

      # Initialize at request start
      Context.init(job_id: job.id, tenant_id: tenant_id)

      # Access anywhere in the request
      ctx = Context.get()
      Logger.info("Processing job", Context.to_logger_metadata())

      # Pass to HTTP requests
      headers = Context.to_headers()
      Req.get(url, headers: headers)

  ## Fields

  - `trace_id` — Unique trace identifier for the entire request chain
  - `span_id` — Identifier for this specific operation
  - `correlation_id` — Alternative correlation ID
  - `job_id` — Conversion job ID
  - `tenant_id` — Organization/workspace ID
  - `user_id` — User making the request
  """

  @context_key :lumainus_conversion_context

  @type t :: %__MODULE__{
          trace_id: String.t() | nil,
          span_id: String.t() | nil,
          correlation_id: String.t() | nil,
          job_id: String.t() | nil,
          tenant_id: String.t() | nil,
          user_id: String.t() | nil
        }

  defstruct [:trace_id, :span_id, :correlation_id, :job_id, :tenant_id, :user_id]

  @doc """
  Initialize context for a new request.

  Generates trace_id, span_id, and correlation_id if not provided.
  """
  @spec init(keyword()) :: t()
  def init(opts \\ []) do
    ctx = %__MODULE__{
      trace_id: Keyword.get(opts, :trace_id, generate_id()),
      span_id: Keyword.get(opts, :span_id, generate_id()),
      correlation_id: Keyword.get(opts, :correlation_id, generate_id()),
      job_id: Keyword.get(opts, :job_id),
      tenant_id: Keyword.get(opts, :tenant_id),
      user_id: Keyword.get(opts, :user_id)
    }

    Process.put(@context_key, ctx)
    ctx
  end

  @doc """
  Get current context from process dictionary.

  Returns empty context struct if not initialized.
  """
  @spec get() :: t()
  def get do
    Process.get(@context_key) || %__MODULE__{}
  end

  @doc """
  Update context fields.

  Merges provided updates with existing context.
  """
  @spec put(map()) :: t()
  def put(updates) when is_map(updates) do
    current = get()

    ctx = %__MODULE__{
      trace_id: Map.get(updates, :trace_id, current.trace_id),
      span_id: Map.get(updates, :span_id, current.span_id),
      correlation_id: Map.get(updates, :correlation_id, current.correlation_id),
      job_id: Map.get(updates, :job_id, current.job_id),
      tenant_id: Map.get(updates, :tenant_id, current.tenant_id),
      user_id: Map.get(updates, :user_id, current.user_id)
    }

    Process.put(@context_key, ctx)
    ctx
  end

  @doc """
  Build HTTP headers for trace propagation to Python backend.
  """
  @spec to_headers() :: [{String.t(), String.t()}]
  def to_headers do
    ctx = get()

    [
      {"x-trace-id", ctx.trace_id || ""},
      {"x-span-id", ctx.span_id || ""},
      {"x-correlation-id", ctx.correlation_id || ""},
      {"x-job-id", ctx.job_id || ""}
    ]
    |> Enum.reject(fn {_, v} -> v == "" end)
  end

  @doc """
  Build Logger metadata.
  """
  @spec to_logger_metadata() :: keyword()
  def to_logger_metadata do
    ctx = get()

    [
      trace_id: ctx.trace_id,
      span_id: ctx.span_id,
      correlation_id: ctx.correlation_id,
      job_id: ctx.job_id,
      tenant_id: ctx.tenant_id,
      user_id: ctx.user_id
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  # Private

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
