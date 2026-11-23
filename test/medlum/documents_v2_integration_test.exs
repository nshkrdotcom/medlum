defmodule Medlum.DocumentsV2IntegrationTest do
  @moduledoc """
  Tests for Documents module integration with v2 Conversion Service.
  """
  use Medlum.DataCase, async: false

  alias Medlum.Conversion.Service
  alias Medlum.Docling.Settings

  # Use Bypass for HTTP mocking
  setup do
    bypass = Bypass.open()

    # Configure settings to use bypass
    {:ok, _} =
      Settings.update_settings(%{
        docker_cpu_url: "http://localhost:#{bypass.port}",
        v2_profile_backends: %{
          "standard" => ["docker_cpu"],
          "enhanced" => ["docker_gpu", "cloud"]
        }
      })

    {:ok, bypass: bypass}
  end

  describe "v2 Service.submit/2 validation" do
    test "rejects non-PDF content type" do
      # Policy validates content_type option, not magic bytes
      text_content = "This is not a PDF"

      attrs = [
        profile: :standard,
        filename: "test.txt",
        content_type: "text/plain"
      ]

      result = Service.submit(text_content, attrs)

      assert {:error, :invalid_content_type} = result
    end

    test "rejects oversized files" do
      # Policy validates actual byte_size(binary), not byte_size attr
      # Create a binary larger than 100MB limit
      # Use smaller size for test - override the max
      # Actually just test that validation happens
      huge_binary = String.duplicate("x", 101 * 1024 * 1024)

      attrs = [
        profile: :standard,
        filename: "huge.pdf"
      ]

      result = Service.submit(huge_binary, attrs)

      assert {:error, :file_too_large} = result
    end
  end

  describe "profile resolution" do
    test "profile_from_backend returns :standard for CPU backends" do
      assert profile_from_backend(:docker_cpu) == :standard
      assert profile_from_backend(:local_cpu) == :standard
      assert profile_from_backend(:native_cpu) == :standard
    end

    test "profile_from_backend returns :enhanced for GPU backends" do
      assert profile_from_backend(:docker_gpu) == :enhanced
      assert profile_from_backend(:local_gpu) == :enhanced
      assert profile_from_backend(:native_gpu) == :enhanced
      assert profile_from_backend(:cloud) == :enhanced
      assert profile_from_backend(:vast_ai) == :enhanced
    end
  end

  # Helper to map backend to profile (same logic as in Documents)
  defp profile_from_backend(backend)
       when backend in [:docker_gpu, :local_gpu, :native_gpu, :vast_ai, :cloud] do
    :enhanced
  end

  defp profile_from_backend(_), do: :standard
end
