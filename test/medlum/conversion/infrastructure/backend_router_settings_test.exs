defmodule Medlum.Conversion.Infrastructure.BackendRouterSettingsTest do
  @moduledoc """
  Tests for BackendRouter integration with database settings.
  """
  use Medlum.DataCase, async: false

  alias Medlum.Conversion.Infrastructure.BackendRouter
  alias Medlum.Docling.Settings

  describe "backends_for_profile/1 with DB settings" do
    setup do
      # Ensure settings exist with known values
      {:ok, _} =
        Settings.update_settings(%{
          docker_cpu_url: "http://localhost:8042",
          docker_gpu_url: "http://localhost:8043",
          native_cpu_url: "http://localhost:8040",
          native_gpu_url: "http://localhost:8041",
          v2_profile_backends: %{
            "standard" => ["docker_cpu"],
            "enhanced" => ["docker_gpu", "cloud"]
          }
        })

      :ok
    end

    test "reads profile mapping from DB settings" do
      backends = BackendRouter.backends_for_profile(:standard)

      assert length(backends) == 1
      assert Enum.at(backends, 0).name == :docker_cpu
    end

    test "builds backend info with URLs from DB" do
      backends = BackendRouter.backends_for_profile(:standard)
      backend = Enum.at(backends, 0)

      assert backend.endpoint == "http://localhost:8042"
      assert backend.backend_type == :local
    end

    test "returns empty list for unknown profile" do
      backends = BackendRouter.backends_for_profile(:nonexistent)

      assert backends == []
    end

    test "skips backends with nil endpoints (except cloud)" do
      # Update settings to have nil native_cpu_url
      {:ok, _} =
        Settings.update_settings(%{
          native_cpu_url: nil,
          v2_profile_backends: %{
            "standard" => ["native_cpu", "docker_cpu"],
            "enhanced" => ["docker_gpu", "cloud"]
          }
        })

      backends = BackendRouter.backends_for_profile(:standard)

      # Should only have docker_cpu since native_cpu has nil URL
      assert length(backends) == 1
      assert Enum.at(backends, 0).name == :docker_cpu
    end

    test "cloud backend has nil endpoint (uses InstanceManager)" do
      backends = BackendRouter.backends_for_profile(:enhanced)

      cloud = Enum.find(backends, &(&1.name == :cloud))
      assert cloud != nil
      assert cloud.endpoint == nil
      assert cloud.backend_type == :cloud
    end
  end

  describe "all_backends/0 with DB settings" do
    setup do
      {:ok, _} =
        Settings.update_settings(%{
          docker_cpu_url: "http://localhost:8042",
          docker_gpu_url: "http://localhost:8043",
          native_cpu_url: "http://localhost:8040",
          native_gpu_url: "http://localhost:8041",
          cloud_url: nil
        })

      :ok
    end

    test "returns all configured backends with DB URLs" do
      backends = BackendRouter.all_backends()

      # Should have backends for all configured URLs
      assert length(backends) >= 4

      docker_cpu = Enum.find(backends, &(&1.name == :docker_cpu))
      assert docker_cpu.endpoint == "http://localhost:8042"

      docker_gpu = Enum.find(backends, &(&1.name == :docker_gpu))
      assert docker_gpu.endpoint == "http://localhost:8043"
    end
  end
end
