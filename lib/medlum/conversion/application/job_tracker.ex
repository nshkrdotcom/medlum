defmodule Medlum.Conversion.Application.JobTracker do
  @moduledoc """
  ETS-backed cache for active job lookups.

  ## Design

  - Database is source of truth
  - ETS provides fast lookups for in-flight jobs
  - Cache rebuilds from DB on startup
  - Updates are write-through (DB first, then ETS)

  ## Usage

      # Register a new job
      {:ok, job} = JobTracker.register(job_changeset)

      # Get a job (ETS first, DB fallback)
      {:ok, job} = JobTracker.get(job_id)

      # Update job state
      {:ok, job} = JobTracker.update(job_id, %{state: :processing, progress: 50})

      # Remove from cache (keeps in DB)
      :ok = JobTracker.remove_from_cache(job_id)
  """

  use GenServer
  require Logger

  alias Medlum.Conversion.Job
  alias Medlum.Repo

  @default_table_name :conversion_job_tracker

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start the JobTracker.

  ## Options

  - `:name` — Process name (default: __MODULE__)
  - `:table_name` — ETS table name (default: :conversion_job_tracker)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register a new job (write-through to DB and ETS).

  Takes a changeset from `Job.new/1`.
  """
  @spec register(atom() | pid(), Ecto.Changeset.t()) ::
          {:ok, Job.t()} | {:error, Ecto.Changeset.t()}
  def register(server \\ __MODULE__, changeset) do
    GenServer.call(server, {:register, changeset})
  end

  @doc """
  Get job by ID (ETS first, fallback to DB).
  """
  @spec get(atom() | pid(), String.t()) :: {:ok, Job.t()} | {:error, :not_found}
  def get(server \\ __MODULE__, job_id) do
    GenServer.call(server, {:get, job_id})
  end

  @doc """
  Update job (write-through to DB and ETS).
  """
  @spec update(atom() | pid(), String.t(), map()) :: {:ok, Job.t()} | {:error, term()}
  def update(server \\ __MODULE__, job_id, updates) do
    GenServer.call(server, {:update, job_id, updates})
  end

  @doc """
  Remove job from ETS cache (keeps in DB).

  Used for completed/failed jobs to free memory.
  """
  @spec remove_from_cache(atom() | pid(), String.t()) :: :ok
  def remove_from_cache(server \\ __MODULE__, job_id) do
    GenServer.cast(server, {:remove_from_cache, job_id})
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, @default_table_name)

    # Create ETS table
    table = :ets.new(table_name, [:named_table, :set, :public, read_concurrency: true])

    # Rebuild cache from DB on startup
    rebuild_cache(table)

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, changeset}, _from, %{table: table} = state) do
    case Repo.insert(changeset) do
      {:ok, job} ->
        :ets.insert(table, {job.id, job})
        {:reply, {:ok, job}, state}

      {:error, changeset} ->
        {:reply, {:error, changeset}, state}
    end
  end

  @impl true
  def handle_call({:get, job_id}, _from, %{table: table} = state) do
    result =
      case :ets.lookup(table, job_id) do
        [{^job_id, job}] ->
          {:ok, job}

        [] ->
          get_from_db(table, job_id)
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:update, job_id, updates}, _from, %{table: table} = state) do
    result =
      case get_job(table, job_id) do
        {:ok, job} ->
          changeset = Job.changeset(job, updates)

          case Repo.update(changeset) do
            {:ok, updated_job} ->
              :ets.insert(table, {job_id, updated_job})
              {:ok, updated_job}

            {:error, changeset} ->
              {:error, changeset}
          end

        {:error, :not_found} ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:remove_from_cache, job_id}, %{table: table} = state) do
    :ets.delete(table, job_id)
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_job(table, job_id) do
    case :ets.lookup(table, job_id) do
      [{^job_id, job}] -> {:ok, job}
      [] -> get_from_db(table, job_id)
    end
  end

  defp get_from_db(table, job_id) do
    case Repo.get(Job, job_id) do
      nil ->
        {:error, :not_found}

      job ->
        # Cache for future lookups
        :ets.insert(table, {job_id, job})
        {:ok, job}
    end
  end

  defp rebuild_cache(table) do
    import Ecto.Query

    # Load only active jobs (not completed/failed/cancelled/timeout)
    active_states = [:queued, :provisioning, :starting, :processing]

    jobs =
      Job
      |> where([j], j.state in ^active_states)
      |> Repo.all()

    Enum.each(jobs, fn job ->
      :ets.insert(table, {job.id, job})
    end)

    Logger.info("[JobTracker] Rebuilt cache with #{length(jobs)} active jobs")
  end
end
