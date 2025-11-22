defmodule Lumainus.Documents.IngestionHealthChecker do
  @moduledoc """
  GenServer for monitoring ingestion system health and performing self-healing.

  Periodically:
  - Checks Docling service health
  - Identifies stuck jobs
  - Reconciles job states with Oban
  - Reports health metrics
  """

  use GenServer

  alias Lumainus.Docling
  alias Lumainus.Documents.{IngestionConfig, IngestionJob}
  alias Lumainus.Repo

  import Ecto.Query

  require Logger

  # 1 minute
  @default_check_interval_ms 60_000

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Manually trigger a health check.
  """
  def check_health(server \\ __MODULE__) do
    GenServer.call(server, :check_health)
  end

  @doc """
  Get current health status.
  """
  def get_status(server \\ __MODULE__) do
    GenServer.call(server, :get_status)
  end

  # Server callbacks

  @impl GenServer
  def init(opts) do
    check_interval = Keyword.get(opts, :check_interval_ms, @default_check_interval_ms)
    docling_health_fun = Keyword.get(opts, :docling_health_fun, &Docling.health/0)

    state = %{
      check_interval: check_interval,
      last_check: nil,
      docling_healthy: nil,
      stuck_jobs_count: 0,
      last_error: nil,
      docling_health_fun: docling_health_fun
    }

    # Schedule first check
    schedule_check(check_interval)

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:check_health, _from, state) do
    new_state = perform_health_check(state)
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call(:get_status, _from, state) do
    {:reply, state, state}
  end

  @impl GenServer
  def handle_info(:check_health, state) do
    new_state = perform_health_check(state)
    schedule_check(state.check_interval)
    {:noreply, new_state}
  end

  # Private functions

  defp schedule_check(interval) do
    Process.send_after(self(), :check_health, interval)
  end

  defp perform_health_check(%{docling_health_fun: health_fun} = state) do
    Logger.debug("Running ingestion health check")

    docling_healthy = check_docling_health(health_fun)
    stuck_jobs = heal_stuck_jobs()

    if not docling_healthy do
      Logger.warning("Docling service is unhealthy")
    end

    %{
      state
      | last_check: DateTime.utc_now(),
        docling_healthy: docling_healthy,
        stuck_jobs_count: length(stuck_jobs),
        last_error: nil
    }
  rescue
    error ->
      Logger.error("Health check failed: #{inspect(error)}")
      %{state | last_error: inspect(error), last_check: DateTime.utc_now()}
  end

  defp check_docling_health(health_fun) do
    case health_fun.() do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.warning("Docling health check failed: #{inspect(reason)}")
        false
    end
  end

  defp heal_stuck_jobs do
    # Find jobs that are in "running" state but haven't updated recently
    # and their Oban job is no longer running
    threshold_minutes = div(IngestionConfig.stale_job_threshold_minutes(), 2)
    cutoff = DateTime.add(DateTime.utc_now(), -threshold_minutes, :minute)

    potentially_stuck =
      IngestionJob
      |> where([j], j.state == "running")
      |> where([j], j.updated_at < ^cutoff)
      |> where([j], is_nil(j.archived_at))
      |> Repo.all()

    healed_jobs =
      Enum.filter(potentially_stuck, fn job ->
        case check_oban_job_status(job) do
          :not_running ->
            # Oban job is gone but our job thinks it's running
            Logger.warning("Healing stuck job #{job.id} - Oban job not running")
            requeue_job(job)
            true

          :completed ->
            # Oban completed but our state didn't update
            Logger.warning("State mismatch for job #{job.id} - Oban completed but job running")
            # This is a bug - investigate
            false

          :running ->
            # Still running in Oban, give it more time
            false

          :unknown ->
            # Can't determine, leave alone
            false
        end
      end)

    healed_jobs
  end

  defp check_oban_job_status(%{oban_job_id: nil}), do: :not_running

  defp check_oban_job_status(%{oban_job_id: oban_id}) do
    case Repo.get(Oban.Job, oban_id) do
      nil ->
        :not_running

      %{state: "completed"} ->
        :completed

      %{state: "discarded"} ->
        :not_running

      %{state: "cancelled"} ->
        :not_running

      %{state: state} when state in ["available", "scheduled", "executing", "retryable"] ->
        :running

      _ ->
        :unknown
    end
  end

  defp requeue_job(job) do
    # Mark the job for retry by updating state
    job
    |> Ecto.Changeset.change(%{
      state: "queued",
      status: "queued",
      stage: "queued",
      last_error: "Requeued by health checker"
    })
    |> Repo.update!()

    # Queue a new Oban job
    %{"ingestion_job_id" => job.id}
    |> Lumainus.Documents.DoclingIngestionWorker.new()
    |> Oban.insert()
  end
end
