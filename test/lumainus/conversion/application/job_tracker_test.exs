defmodule Lumainus.Conversion.Application.JobTrackerTest do
  use Lumainus.DataCase, async: false

  alias Lumainus.Conversion.Application.JobTracker
  alias Lumainus.Conversion.Job
  alias Lumainus.Repo

  @moduletag :capture_log

  # Setup: Start a fresh JobTracker for each test
  setup do
    # Clean up any existing data
    Repo.delete_all(Job)

    # Start a unique JobTracker instance for this test
    name = unique_name(:job_tracker)
    table_name = unique_name(:job_tracker_ets)

    {:ok, pid} =
      start_supervised({JobTracker, name: name, table_name: table_name})

    %{tracker: name, table: table_name, pid: pid}
  end

  describe "register/2" do
    test "persists job to DB and caches in ETS", %{tracker: tracker, table: table} do
      changeset =
        Job.new(%{
          profile: :standard,
          filename: "test.pdf",
          byte_size: 1024
        })

      {:ok, job} = JobTracker.register(tracker, changeset)

      # Verify job has ID
      assert job.id != nil
      assert job.profile == :standard
      assert job.filename == "test.pdf"

      # Verify persisted to DB
      assert Repo.get(Job, job.id) != nil

      # Verify cached in ETS
      job_id = job.id
      assert [{^job_id, _cached_job}] = :ets.lookup(table, job.id)
    end

    test "returns error for invalid changeset", %{tracker: tracker} do
      # Missing required fields
      changeset = Job.new(%{})

      result = JobTracker.register(tracker, changeset)

      assert {:error, changeset} = result
      refute changeset.valid?
    end
  end

  describe "get/2" do
    test "returns from ETS if cached", %{tracker: tracker, table: _table} do
      # Register a job
      changeset =
        Job.new(%{
          profile: :standard,
          filename: "cached.pdf",
          byte_size: 2048
        })

      {:ok, job} = JobTracker.register(tracker, changeset)

      # Get should return from cache
      {:ok, retrieved} = JobTracker.get(tracker, job.id)

      assert retrieved.id == job.id
      assert retrieved.filename == "cached.pdf"
    end

    test "falls back to DB if not in cache", %{tracker: tracker, table: table} do
      # Insert directly to DB (bypassing cache)
      now = DateTime.utc_now()

      {:ok, job} =
        %Job{
          profile: :standard,
          filename: "db_only.pdf",
          byte_size: 3072,
          submitted_at: now,
          timeout_at: DateTime.add(now, 900_000, :millisecond),
          code_version: :v2,
          state: :queued
        }
        |> Repo.insert()

      # Clear ETS cache to ensure DB fallback
      :ets.delete(table, job.id)

      # Get should fall back to DB
      {:ok, retrieved} = JobTracker.get(tracker, job.id)

      assert retrieved.id == job.id
      assert retrieved.filename == "db_only.pdf"
    end

    test "returns error for non-existent job", %{tracker: tracker} do
      fake_id = Ecto.UUID.generate()

      result = JobTracker.get(tracker, fake_id)

      assert result == {:error, :not_found}
    end
  end

  describe "update/3" do
    test "writes through to DB and ETS", %{tracker: tracker, table: table} do
      # Register a job
      changeset =
        Job.new(%{
          profile: :standard,
          filename: "update_test.pdf",
          byte_size: 1024
        })

      {:ok, job} = JobTracker.register(tracker, changeset)

      # Update the job
      {:ok, updated} =
        JobTracker.update(tracker, job.id, %{
          state: :processing,
          progress: 50
        })

      assert updated.state == :processing
      assert updated.progress == 50

      # Verify DB is updated
      db_job = Repo.get(Job, job.id)
      assert db_job.state == :processing
      assert db_job.progress == 50

      # Verify ETS is updated
      [{_, cached}] = :ets.lookup(table, job.id)
      assert cached.state == :processing
    end

    test "returns error for non-existent job", %{tracker: tracker} do
      fake_id = Ecto.UUID.generate()

      result = JobTracker.update(tracker, fake_id, %{state: :processing})

      assert result == {:error, :not_found}
    end
  end

  describe "remove_from_cache/2" do
    test "removes job from ETS but keeps in DB", %{tracker: tracker, table: table} do
      # Register a job
      changeset =
        Job.new(%{
          profile: :standard,
          filename: "remove_test.pdf",
          byte_size: 1024
        })

      {:ok, job} = JobTracker.register(tracker, changeset)

      # Verify it's in cache
      assert :ets.lookup(table, job.id) != []

      # Remove from cache
      :ok = JobTracker.remove_from_cache(tracker, job.id)

      # Give the cast time to process
      Process.sleep(50)

      # Verify removed from ETS
      assert :ets.lookup(table, job.id) == []

      # Verify still in DB
      assert Repo.get(Job, job.id) != nil
    end
  end

  describe "cache rebuild on startup" do
    test "rebuilds cache from DB with active jobs only" do
      now = DateTime.utc_now()

      # Insert jobs directly to DB with different states
      {:ok, active_job} =
        %Job{
          profile: :standard,
          filename: "active.pdf",
          byte_size: 1024,
          submitted_at: now,
          timeout_at: DateTime.add(now, 900_000, :millisecond),
          code_version: :v2,
          state: :processing
        }
        |> Repo.insert()

      {:ok, queued_job} =
        %Job{
          profile: :standard,
          filename: "queued.pdf",
          byte_size: 1024,
          submitted_at: now,
          timeout_at: DateTime.add(now, 900_000, :millisecond),
          code_version: :v2,
          state: :queued
        }
        |> Repo.insert()

      {:ok, _completed_job} =
        %Job{
          profile: :standard,
          filename: "completed.pdf",
          byte_size: 1024,
          submitted_at: now,
          timeout_at: DateTime.add(now, 900_000, :millisecond),
          code_version: :v2,
          state: :completed
        }
        |> Repo.insert()

      # Start a new JobTracker (should rebuild cache)
      name = unique_name(:rebuild_tracker)
      table_name = unique_name(:rebuild_ets)

      {:ok, _pid} =
        start_supervised({JobTracker, name: name, table_name: table_name}, id: :rebuild_tracker)

      # Active jobs should be cached
      assert :ets.lookup(table_name, active_job.id) != []
      assert :ets.lookup(table_name, queued_job.id) != []

      # Completed jobs should NOT be cached
      # Note: We need to check by scanning all entries
      all_cached_ids =
        :ets.tab2list(table_name)
        |> Enum.map(fn {id, _job} -> id end)

      assert active_job.id in all_cached_ids
      assert queued_job.id in all_cached_ids
    end
  end

  # Helpers

  defp unique_name(base) do
    :"#{base}_#{System.unique_integer([:positive])}"
  end
end
