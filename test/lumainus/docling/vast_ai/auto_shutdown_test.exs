defmodule Lumainus.Docling.VastAI.AutoShutdownTest do
  use Lumainus.DataCase, async: false

  import ExUnit.CaptureLog

  alias Lumainus.Conversion.Job
  alias Lumainus.Docling.VastAI.AutoShutdown
  alias Lumainus.Docling.VastAI.ActivityTracker
  alias Lumainus.Docling.VastAI.StartTracker

  defmodule StubInstances do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{instances: []} end, name: __MODULE__)
    end

    def set_instances(instances) do
      Agent.update(__MODULE__, fn _ -> %{instances: instances} end)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> %{instances: []} end)
    end

    def list do
      {:ok, %{"instances" => Agent.get(__MODULE__, & &1.instances)}}
    end

    def get(instance_id) do
      case Agent.get(
             __MODULE__,
             &Enum.find(&1.instances, fn inst -> inst["id"] == instance_id end)
           ) do
        nil -> {:ok, %{}}
        instance -> {:ok, %{"instances" => instance}}
      end
    end
  end

  defmodule StubVastAI do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{stopped: [], destroyed: []} end, name: __MODULE__)
    end

    def stop(instance_id) do
      Agent.update(__MODULE__, fn state -> %{state | stopped: [instance_id | state.stopped]} end)
      {:ok, :stopped}
    end

    def destroy(instance_id) do
      Agent.update(__MODULE__, fn state ->
        %{state | destroyed: [instance_id | state.destroyed]}
      end)

      {:ok, :destroyed}
    end

    def stopped, do: Agent.get(__MODULE__, &Enum.reverse(&1.stopped))

    def reset do
      Agent.update(__MODULE__, fn _ -> %{stopped: [], destroyed: []} end)
    end
  end

  setup do
    ensure_started(StubInstances, fn -> start_supervised!(StubInstances) end)
    ensure_started(StubVastAI, fn -> start_supervised!(StubVastAI) end)
    ensure_started(ActivityTracker, fn -> start_supervised!(ActivityTracker) end)
    ensure_started(StartTracker, fn -> start_supervised!(StartTracker) end)

    original_config = Application.get_env(:lumainus, :vast_ai_auto_shutdown, [])

    test_config =
      original_config
      |> Keyword.put(:enabled, false)
      |> Keyword.put(:idle_timeout_minutes, 1)
      |> Keyword.put(:post_provisioning_grace_minutes, 0)
      |> Keyword.put(:pending_shutdown_seconds, 1)
      |> Keyword.put(:instances_module, StubInstances)
      |> Keyword.put(:vast_ai_module, StubVastAI)

    Application.put_env(:lumainus, :vast_ai_auto_shutdown, test_config)

    # Reset stub state for isolation
    StubInstances.reset()
    StubVastAI.reset()
    ActivityTracker.reset()

    on_exit(fn ->
      Application.put_env(:lumainus, :vast_ai_auto_shutdown, original_config)
    end)

    # Ensure AutoShutdown is running (not started in tests by default if VastAI disabled)
    ensure_started(AutoShutdown, fn -> start_supervised!(AutoShutdown) end)
    AutoShutdown.touch_activity()

    :ok
  end

  test "schedules pending shutdown then stops after window when still idle" do
    _ =
      capture_log(fn ->
        instance = %{
          "id" => 1,
          "actual_status" => "running",
          "start_date" => System.system_time(:second) - 3600
        }

        StubInstances.set_instances([instance])
        set_first_seen(instance["id"], 60)
        seed_idle_minutes(10)

        assert {:ok, :pending_shutdown, 1} = AutoShutdown.check_and_shutdown()
        assert_pending_set()
        assert [] == StubVastAI.stopped()

        # Pending timer should expire and stop instance
        Process.sleep(1_500)
        state_after = :sys.get_state(AutoShutdown)
        assert state_after.pending_shutdown == nil
        assert {:ok, :stopped, 1} = state_after.last_result
        assert [1] == StubVastAI.stopped()
      end)
  end

  test "pending shutdown is cancelled by activity and does not stop" do
    instance = %{
      "id" => 2,
      "actual_status" => "running",
      "start_date" => System.system_time(:second) - 3600
    }

    StubInstances.set_instances([instance])
    set_first_seen(instance["id"], 60)
    seed_idle_minutes(10)

    assert {:ok, :pending_shutdown, 2} = AutoShutdown.check_and_shutdown()

    ActivityTracker.record_activity()
    Process.sleep(50)

    refute :sys.get_state(AutoShutdown).pending_shutdown

    Process.sleep(1_200)
    assert [] == StubVastAI.stopped()
  end

  test "pending shutdown expires but is cancelled due to in-flight cloud job" do
    instance = %{
      "id" => 3,
      "actual_status" => "running",
      "start_date" => System.system_time(:second) - 3600
    }

    StubInstances.set_instances([instance])
    set_first_seen(instance["id"], 60)
    seed_idle_minutes(10)

    assert {:ok, :pending_shutdown, 3} = AutoShutdown.check_and_shutdown()
    assert_pending_set()

    job = Repo.insert!(Job.new(%{profile: :standard, filename: "f.pdf", byte_size: 1}))
    Repo.update!(Job.changeset(job, %{state: :processing, backend_used: :cloud}))

    Process.sleep(1_200)
    assert [] == StubVastAI.stopped()
    refute :sys.get_state(AutoShutdown).pending_shutdown
  end

  defp seed_idle_minutes(minutes) do
    now = System.monotonic_time(:millisecond)
    last = now - minutes * 60_000
    :ets.insert(:vast_ai_activity, {:last_activity, last})
  end

  defp set_first_seen(instance_id, minutes_ago) do
    StartTracker.record_first_seen(instance_id)

    :ets.insert(
      :vast_ai_start_tracker,
      {instance_id, System.monotonic_time(:millisecond) - minutes_ago * 60_000}
    )
  end

  defp assert_pending_set do
    assert %{instance_id: _} = :sys.get_state(AutoShutdown).pending_shutdown
  end

  defp ensure_started(module, starter_fun) do
    case Process.whereis(module) do
      nil ->
        starter_fun.()
        :ok

      _pid ->
        :ok
    end
  end
end
