defmodule Medlum.Conversion.JobTest do
  use Medlum.Conversion.TestCase

  alias Medlum.Conversion.Job
  alias Medlum.Conversion.ProcessingProfile

  describe "new/1" do
    test "creates valid changeset with required fields" do
      attrs = %{
        profile: :standard,
        filename: "test.pdf",
        byte_size: 1024
      }

      changeset = Job.new(attrs)

      assert changeset.valid?
      assert get_change(changeset, :profile) == :standard
      assert get_change(changeset, :filename) == "test.pdf"
      assert get_change(changeset, :byte_size) == 1024
    end

    test "sets submitted_at to current time" do
      before = DateTime.utc_now()

      changeset =
        Job.new(%{
          profile: :standard,
          filename: "test.pdf",
          byte_size: 1024
        })

      after_time = DateTime.utc_now()
      submitted_at = get_change(changeset, :submitted_at)

      assert submitted_at != nil
      assert DateTime.compare(submitted_at, before) in [:eq, :gt]
      assert DateTime.compare(submitted_at, after_time) in [:eq, :lt]
    end

    test "sets timeout_at based on profile default" do
      changeset =
        Job.new(%{
          profile: :standard,
          filename: "test.pdf",
          byte_size: 1024
        })

      submitted_at = get_change(changeset, :submitted_at)
      timeout_at = get_change(changeset, :timeout_at)

      diff_ms = DateTime.diff(timeout_at, submitted_at, :millisecond)
      expected_timeout = ProcessingProfile.default_timeout_ms(:standard)

      # Allow small variance for execution time
      assert abs(diff_ms - expected_timeout) < 100
    end

    test "sets timeout_at based on enhanced profile default" do
      changeset =
        Job.new(%{
          profile: :enhanced,
          filename: "test.pdf",
          byte_size: 1024
        })

      submitted_at = get_change(changeset, :submitted_at)
      timeout_at = get_change(changeset, :timeout_at)

      diff_ms = DateTime.diff(timeout_at, submitted_at, :millisecond)
      expected_timeout = ProcessingProfile.default_timeout_ms(:enhanced)

      assert abs(diff_ms - expected_timeout) < 100
    end

    test "sets code_version to :v2" do
      changeset =
        Job.new(%{
          profile: :standard,
          filename: "test.pdf",
          byte_size: 1024
        })

      # Use get_field because :v2 is the schema default
      assert get_field(changeset, :code_version) == :v2
    end

    test "sets state to :queued" do
      changeset =
        Job.new(%{
          profile: :standard,
          filename: "test.pdf",
          byte_size: 1024
        })

      # Use get_field because :queued is the schema default
      assert get_field(changeset, :state) == :queued
    end

    test "respects custom timeout_ms if within max" do
      custom_timeout = 300_000

      changeset =
        Job.new(%{
          profile: :standard,
          filename: "test.pdf",
          byte_size: 1024,
          timeout_ms: custom_timeout
        })

      submitted_at = get_change(changeset, :submitted_at)
      timeout_at = get_change(changeset, :timeout_at)

      diff_ms = DateTime.diff(timeout_at, submitted_at, :millisecond)
      assert abs(diff_ms - custom_timeout) < 100
    end

    test "caps timeout_ms at max_timeout_ms" do
      # Try to set timeout beyond max
      huge_timeout = 10_000_000

      changeset =
        Job.new(%{
          profile: :standard,
          filename: "test.pdf",
          byte_size: 1024,
          timeout_ms: huge_timeout
        })

      submitted_at = get_change(changeset, :submitted_at)
      timeout_at = get_change(changeset, :timeout_at)

      diff_ms = DateTime.diff(timeout_at, submitted_at, :millisecond)
      max_timeout = ProcessingProfile.max_timeout_ms()

      assert abs(diff_ms - max_timeout) < 100
    end

    test "accepts optional tenant_id and user_id" do
      tenant_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      changeset =
        Job.new(%{
          profile: :standard,
          filename: "test.pdf",
          byte_size: 1024,
          tenant_id: tenant_id,
          user_id: user_id
        })

      assert get_change(changeset, :tenant_id) == tenant_id
      assert get_change(changeset, :user_id) == user_id
    end

    test "accepts metadata map" do
      metadata = %{"source" => "upload", "content_type" => "application/pdf"}

      changeset =
        Job.new(%{
          profile: :standard,
          filename: "test.pdf",
          byte_size: 1024,
          metadata: metadata
        })

      assert get_change(changeset, :metadata) == metadata
    end

    test "validates required fields" do
      changeset = Job.new(%{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset, :profile)
      assert "can't be blank" in errors_on(changeset, :filename)
      assert "can't be blank" in errors_on(changeset, :byte_size)
    end
  end

  describe "changeset/2" do
    test "updates state" do
      job = %Job{
        id: Ecto.UUID.generate(),
        profile: :standard,
        filename: "test.pdf",
        byte_size: 1024,
        state: :queued
      }

      changeset = Job.changeset(job, %{state: :processing})
      assert get_change(changeset, :state) == :processing
    end

    test "updates progress" do
      job = %Job{
        id: Ecto.UUID.generate(),
        profile: :standard,
        filename: "test.pdf",
        byte_size: 1024,
        progress: 0
      }

      changeset = Job.changeset(job, %{progress: 50})
      assert get_change(changeset, :progress) == 50
    end

    test "updates backend tracking fields" do
      job = %Job{
        id: Ecto.UUID.generate(),
        profile: :standard,
        filename: "test.pdf",
        byte_size: 1024
      }

      changeset =
        Job.changeset(job, %{
          backend_used: :docker_cpu,
          backend_endpoint: "http://localhost:8042",
          instance_id: 12345
        })

      assert get_change(changeset, :backend_used) == :docker_cpu
      assert get_change(changeset, :backend_endpoint) == "http://localhost:8042"
      assert get_change(changeset, :instance_id) == 12345
    end

    test "updates result on completion" do
      job = %Job{
        id: Ecto.UUID.generate(),
        profile: :standard,
        filename: "test.pdf",
        byte_size: 1024,
        state: :processing
      }

      result = %{"markdown" => "# Test", "metadata" => %{}}

      changeset =
        Job.changeset(job, %{
          state: :completed,
          result: result
        })

      assert get_change(changeset, :state) == :completed
      assert get_change(changeset, :result) == result
    end

    test "updates last_error on failure" do
      job = %Job{
        id: Ecto.UUID.generate(),
        profile: :standard,
        filename: "test.pdf",
        byte_size: 1024,
        state: :processing
      }

      changeset =
        Job.changeset(job, %{
          state: :failed,
          last_error: "Connection timeout"
        })

      assert get_change(changeset, :state) == :failed
      assert get_change(changeset, :last_error) == "Connection timeout"
    end
  end

  # Helper functions

  defp get_change(changeset, field) do
    Ecto.Changeset.get_change(changeset, field)
  end

  defp get_field(changeset, field) do
    Ecto.Changeset.get_field(changeset, field)
  end

  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {msg, _opts} -> msg end)
  end
end
