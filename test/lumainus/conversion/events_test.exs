defmodule Lumainus.Conversion.EventsTest do
  use ExUnit.Case, async: false

  alias Lumainus.Conversion.Events

  @moduletag :capture_log

  describe "subscribe/1" do
    test "subscribes to job events" do
      job_id = Ecto.UUID.generate()

      assert :ok = Events.subscribe(job_id)

      # Verify subscription by broadcasting and receiving
      Events.broadcast_submitted(%{id: job_id, profile: :standard})

      assert_receive {:conversion_job, :submitted, %{id: ^job_id}}
    end
  end

  describe "broadcast_submitted/1" do
    test "broadcasts job submitted event to subscribers" do
      job_id = Ecto.UUID.generate()
      Events.subscribe(job_id)

      job = %{id: job_id, profile: :standard, filename: "test.pdf"}
      Events.broadcast_submitted(job)

      assert_receive {:conversion_job, :submitted, ^job}
    end

    test "does not send to non-subscribers" do
      job_id = Ecto.UUID.generate()
      other_job_id = Ecto.UUID.generate()

      # Subscribe to other_job_id
      Events.subscribe(other_job_id)

      job = %{id: job_id, profile: :standard}
      Events.broadcast_submitted(job)

      refute_receive {:conversion_job, :submitted, _}, 100
    end
  end

  describe "broadcast_progress/2" do
    test "broadcasts progress update" do
      job_id = Ecto.UUID.generate()
      Events.subscribe(job_id)

      job = %{id: job_id}
      Events.broadcast_progress(job, 50)

      assert_receive {:conversion_job, :progress, %{job_id: ^job_id, progress: 50}}
    end
  end

  describe "broadcast_completed/1" do
    test "broadcasts job completed event" do
      job_id = Ecto.UUID.generate()
      Events.subscribe(job_id)

      job = %{id: job_id, result: %{"markdown" => "# Test"}}
      Events.broadcast_completed(job)

      assert_receive {:conversion_job, :completed, ^job}
    end
  end

  describe "broadcast_failed/2" do
    test "broadcasts job failed event with reason" do
      job_id = Ecto.UUID.generate()
      Events.subscribe(job_id)

      job = %{id: job_id}
      Events.broadcast_failed(job, :timeout)

      assert_receive {:conversion_job, :failed, %{job_id: ^job_id, reason: :timeout}}
    end
  end

  describe "broadcast_cancelled/1" do
    test "broadcasts job cancelled event" do
      job_id = Ecto.UUID.generate()
      Events.subscribe(job_id)

      job = %{id: job_id}
      Events.broadcast_cancelled(job)

      assert_receive {:conversion_job, :cancelled, ^job}
    end
  end

  describe "topic/1" do
    test "generates consistent topic for job_id" do
      job_id = Ecto.UUID.generate()

      topic1 = Events.topic(job_id)
      topic2 = Events.topic(job_id)

      assert topic1 == topic2
      assert is_binary(topic1)
      assert String.contains?(topic1, job_id)
    end
  end
end
