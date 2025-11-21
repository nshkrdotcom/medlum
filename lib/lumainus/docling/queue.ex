defmodule Lumainus.Docling.Queue do
  @moduledoc """
  Queue facade for Docling. Defaults to inline conversion but can poll the
  Docling service's `/jobs` endpoint when `:queue_mode` is set to `:http_queue`.
  """

  alias Lumainus.Docling
  require Logger

  @inline_mode :inline

  @type job :: %{
          job_id: binary(),
          timeout_ms: non_neg_integer(),
          timeout_at: DateTime.t(),
          mode: atom(),
          binary: binary() | nil,
          convert_opts: keyword()
        }

  @doc """
  Enqueue a Docling job and return a handle that can be awaited.
  """
  def enqueue(binary, opts \\ []) when is_binary(binary) do
    mode = queue_mode()
    timeout_ms = Keyword.get(opts, :timeout_ms, Docling.timeout())
    job_id = Keyword.get(opts, :job_id, Ecto.UUID.generate())
    timeout_at = DateTime.utc_now(:second) |> DateTime.add(div(timeout_ms, 1000), :second)

    Logger.info("Submitting Docling job #{job_id} (mode=#{mode}, timeout=#{timeout_ms}ms)")

    payload = %{
      job_id: job_id,
      timeout_ms: timeout_ms,
      timeout_at: timeout_at,
      mode: mode,
      binary: binary,
      convert_opts: Keyword.merge(opts, job_id: job_id)
    }

    case mode do
      :http_queue -> enqueue_remote(payload)
      _ -> {:ok, payload}
    end
  end

  @doc """
  Await a Docling job. Inline mode runs the conversion directly; HTTP queue mode
  polls until the remote worker completes or the timeout expires.
  """
  def await(job, opts \\ [])

  def await(%{mode: :http_queue} = job, opts) do
    poll_ms = Keyword.get(opts, :poll_interval_ms, poll_interval_ms())
    on_status = Keyword.get(opts, :on_status, fn _ -> :ok end)
    deadline = System.monotonic_time(:millisecond) + job.timeout_ms + 5_000
    poll_remote(job, deadline, poll_ms, on_status)
  end

  def await(%{mode: _} = job, _opts) do
    Docling.convert(job.binary, Keyword.put(job.convert_opts, :timeout_ms, job.timeout_ms))
  end

  def queue_mode do
    Application.get_env(:lumainus, :docling, []) |> Keyword.get(:queue_mode, @inline_mode)
  end

  defp poll_interval_ms do
    Application.get_env(:lumainus, :docling, [])
    |> Keyword.get(:poll_interval_ms, 1_000)
  end

  defp enqueue_remote(job) do
    case Docling.enqueue_job(
           job.binary,
           Keyword.put(job.convert_opts, :timeout_ms, job.timeout_ms)
         ) do
      {:ok, %{"job_id" => remote_id}} ->
        {:ok,
         %{
           job
           | job_id: remote_id,
             convert_opts: Keyword.put(job.convert_opts, :job_id, remote_id),
             binary: nil
         }}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp poll_remote(job, deadline, poll_ms, on_status) do
    cond do
      System.monotonic_time(:millisecond) > deadline ->
        {:error, :timeout}

      true ->
        case Docling.job_status(job.job_id) do
          {:ok, %{"state" => "completed"} = body} ->
            on_status.(body)
            {:ok, Map.get(body, "result") || Map.get(body, "payload") || %{}}

          {:ok, %{"state" => "failed"} = body} ->
            on_status.(body)
            {:error, {:docling_failed, body["last_error"]}}

          {:ok, pending} ->
            on_status.(pending)
            Process.sleep(poll_ms)
            poll_remote(job, deadline, poll_ms, on_status)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
