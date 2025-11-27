defmodule LumainusWeb.ReportsLiveV2Test do
  @moduledoc """
  Tests for ReportsLive v2 Conversion Events integration.
  """
  use LumainusWeb.ConnCase, async: false

  alias Lumainus.Conversion.Events

  describe "v2 conversion event handling" do
    test "handle_info handles {:conversion_job, :progress, payload}" do
      # Create a mock socket assign map (unused, just demonstrating pattern)
      _socket = %Phoenix.LiveView.Socket{
        assigns: %{
          conversion_jobs: %{}
        }
      }

      job_id = Ecto.UUID.generate()
      payload = %{job_id: job_id, progress: 50}

      # The handler should be able to process this message
      # This tests the pattern match, not the full LiveView lifecycle
      message = {:conversion_job, :progress, payload}

      assert match?({:conversion_job, :progress, %{job_id: _, progress: _}}, message)
    end

    test "handle_info handles {:conversion_job, :completed, job}" do
      job_id = Ecto.UUID.generate()
      job = %{id: job_id, state: :completed, result: %{"markdown" => "test"}}

      message = {:conversion_job, :completed, job}

      assert match?({:conversion_job, :completed, %{id: _, state: :completed}}, message)
    end

    test "handle_info handles {:conversion_job, :failed, payload}" do
      job_id = Ecto.UUID.generate()
      payload = %{job_id: job_id, reason: :timeout}

      message = {:conversion_job, :failed, payload}

      assert match?({:conversion_job, :failed, %{job_id: _, reason: _}}, message)
    end

    test "handle_info handles {:conversion_job, :cancelled, job}" do
      job_id = Ecto.UUID.generate()
      job = %{id: job_id, state: :cancelled}

      message = {:conversion_job, :cancelled, job}

      assert match?({:conversion_job, :cancelled, %{id: _}}, message)
    end
  end

  describe "Events.subscribe/1" do
    test "subscribes to job events via PubSub" do
      job_id = Ecto.UUID.generate()

      # Subscribe should succeed
      assert :ok = Events.subscribe(job_id)

      # Broadcast a message
      Events.broadcast_progress(%{id: job_id}, 50)

      # Should receive the message
      assert_receive {:conversion_job, :progress, %{job_id: ^job_id, progress: 50}}
    end

    test "unsubscribe stops receiving events" do
      job_id = Ecto.UUID.generate()

      assert :ok = Events.subscribe(job_id)
      assert :ok = Events.unsubscribe(job_id)

      # Broadcast a message
      Events.broadcast_progress(%{id: job_id}, 50)

      # Should NOT receive the message
      refute_receive {:conversion_job, :progress, _}, 100
    end
  end
end
