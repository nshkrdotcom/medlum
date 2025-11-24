defmodule Lumainus.Docling.VastAI.InstanceManagerTest do
  use ExUnit.Case, async: false

  alias Lumainus.Docling.VastAI.InstanceManager

  @moduledoc """
  Tests for Lumainus.Docling.VastAI.InstanceManager GenServer.

  These tests use mocked Vast.ai API responses.
  """

  setup do
    # Start the InstanceManager for each test with default name
    start_supervised!(InstanceManager)
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
      original_config = Application.get_env(:lumainus, :docling, [])

      # Set up mock provisioner
      new_config =
        Keyword.put(original_config, :vast_ai,
          provisioner: mock_provision,
          api_key: "test-key"
        )

      Application.put_env(:lumainus, :docling, new_config)

      on_exit(fn ->
        Application.put_env(:lumainus, :docling, original_config)
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

      original_config = Application.get_env(:lumainus, :docling, [])

      new_config =
        Keyword.put(original_config, :vast_ai,
          provisioner: mock_provision,
          api_key: "test-key"
        )

      Application.put_env(:lumainus, :docling, new_config)

      on_exit(fn ->
        Application.put_env(:lumainus, :docling, original_config)
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

      original_config = Application.get_env(:lumainus, :docling, [])

      new_config =
        Keyword.put(original_config, :vast_ai,
          provisioner: mock_provision,
          api_key: "test-key"
        )

      Application.put_env(:lumainus, :docling, new_config)

      on_exit(fn ->
        Application.put_env(:lumainus, :docling, original_config)
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

      original_config = Application.get_env(:lumainus, :docling, [])

      new_config =
        Keyword.put(original_config, :vast_ai,
          provisioner: mock_provision,
          destroyer: mock_destroy,
          api_key: "test-key"
        )

      Application.put_env(:lumainus, :docling, new_config)

      on_exit(fn ->
        Application.put_env(:lumainus, :docling, original_config)
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

      original_config = Application.get_env(:lumainus, :docling, [])

      new_config =
        Keyword.put(original_config, :vast_ai,
          provisioner: mock_provision,
          api_key: "test-key"
        )

      Application.put_env(:lumainus, :docling, new_config)

      on_exit(fn ->
        Application.put_env(:lumainus, :docling, original_config)
      end)

      {:ok, _} = InstanceManager.ensure_instance()

      # Update activity
      :ok = InstanceManager.update_activity()
    end
  end
end
