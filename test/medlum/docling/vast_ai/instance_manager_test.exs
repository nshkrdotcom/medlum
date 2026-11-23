defmodule Medlum.Docling.VastAI.InstanceManagerTest do
  use Medlum.DataCase, async: false

  alias Medlum.Docling.VastAI.InstanceManager

  @moduledoc """
  Tests for Medlum.Docling.VastAI.InstanceManager GenServer.

  These tests use mocked Vast.ai API responses.
  """

  setup do
    # Start the InstanceManager for each test with default name
    restart_instance_manager()
    :ok
  end

  describe "get_endpoint/0" do
    test "returns error when no instance is running" do
      assert {:error, :no_instance} = InstanceManager.get_endpoint()
    end
  end

  describe "current_instance_id/0" do
    test "returns nil when no instance is running" do
      assert nil == InstanceManager.current_instance_id()
    end
  end

  describe "ensure_instance/0" do
    test "provisions new instance when none exists" do
      # Mock the provision function
      mock_provision = fn ->
        {:ok, "12345", "http://1.2.3.4:8042"}
      end

      # Store the original config
      original_config = Application.get_env(:medlum, :docling, [])

      # Set up mock provisioner
      new_config =
        Keyword.put(original_config, :vast_ai,
          provisioner: mock_provision,
          api_key: "test-key"
        )

      Application.put_env(:medlum, :docling, new_config)

      on_exit(fn ->
        Application.put_env(:medlum, :docling, original_config)
      end)

      assert {:ok, endpoint} = InstanceManager.ensure_instance()
      assert endpoint == "http://1.2.3.4:8042"

      # Second call should return cached endpoint
      assert {:ok, ^endpoint} = InstanceManager.ensure_instance()
    end

    test "returns cached endpoint when instance already exists" do
      call_count = :counters.new(1, [:atomics])

      mock_provision = fn ->
        :counters.add(call_count, 1, 1)
        {:ok, "12345", "http://1.2.3.4:8042"}
      end

      original_config = Application.get_env(:medlum, :docling, [])

      new_config =
        Keyword.put(original_config, :vast_ai,
          provisioner: mock_provision,
          api_key: "test-key"
        )

      Application.put_env(:medlum, :docling, new_config)

      on_exit(fn ->
        Application.put_env(:medlum, :docling, original_config)
      end)

      # First call provisions
      {:ok, _} = InstanceManager.ensure_instance()

      # Second call should use cache
      {:ok, _} = InstanceManager.ensure_instance()

      # Should only have provisioned once
      assert :counters.get(call_count, 1) == 1
    end

    test "returns error when provisioning fails" do
      mock_provision = fn ->
        {:error, :no_instances_available}
      end

      original_config = Application.get_env(:medlum, :docling, [])

      new_config =
        Keyword.put(original_config, :vast_ai,
          provisioner: mock_provision,
          api_key: "test-key"
        )

      Application.put_env(:medlum, :docling, new_config)

      on_exit(fn ->
        Application.put_env(:medlum, :docling, original_config)
      end)

      assert {:error, :no_instances_available} = InstanceManager.ensure_instance()
    end
  end

  describe "destroy_instance/0" do
    test "destroys current instance" do
      destroyed = :counters.new(1, [:atomics])

      mock_provision = fn ->
        {:ok, "12345", "http://1.2.3.4:8042"}
      end

      mock_destroy = fn _instance_id ->
        :counters.add(destroyed, 1, 1)
        :ok
      end

      original_config = Application.get_env(:medlum, :docling, [])

      new_config =
        Keyword.put(original_config, :vast_ai,
          provisioner: mock_provision,
          destroyer: mock_destroy,
          api_key: "test-key"
        )

      Application.put_env(:medlum, :docling, new_config)

      on_exit(fn ->
        Application.put_env(:medlum, :docling, original_config)
      end)

      # Provision first
      {:ok, _} = InstanceManager.ensure_instance()

      # Then destroy
      :ok = InstanceManager.destroy_instance()

      assert :counters.get(destroyed, 1) == 1

      # Should have no instance now
      assert {:error, :no_instance} = InstanceManager.get_endpoint()
    end

    test "does nothing when no instance exists" do
      assert :ok = InstanceManager.destroy_instance()
    end
  end

  describe "update_activity/0" do
    test "updates last activity timestamp" do
      mock_provision = fn ->
        {:ok, "12345", "http://1.2.3.4:8042"}
      end

      original_config = Application.get_env(:medlum, :docling, [])

      new_config =
        Keyword.put(original_config, :vast_ai,
          provisioner: mock_provision,
          api_key: "test-key"
        )

      Application.put_env(:medlum, :docling, new_config)

      on_exit(fn ->
        Application.put_env(:medlum, :docling, original_config)
      end)

      {:ok, _} = InstanceManager.ensure_instance()

      # Update activity
      :ok = InstanceManager.update_activity()
    end
  end

  defp restart_instance_manager do
    start_tracker =
      ensure_started(Medlum.Docling.VastAI.StartTracker, fn ->
        start_supervised!(Medlum.Docling.VastAI.StartTracker)
      end)

    activity_tracker =
      ensure_started(Medlum.Docling.VastAI.ActivityTracker, fn ->
        start_supervised!(Medlum.Docling.VastAI.ActivityTracker)
      end)

    instance_manager =
      case Process.whereis(InstanceManager) do
        nil ->
          start_supervised!(InstanceManager)

        pid ->
          InstanceManager.clear_state(pid)
          pid
      end

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), start_tracker)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), activity_tracker)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), instance_manager)
  end

  defp ensure_started(mod, starter) do
    case Process.whereis(mod) do
      nil -> starter.()
      pid -> pid
    end
  end
end
