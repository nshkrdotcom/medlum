defmodule Lumainus.DoclingTest do
  use ExUnit.Case, async: false

  alias Lumainus.Docling

  @moduledoc """
  Tests for the main Lumainus.Docling facade module.
  """

  describe "backend/0" do
    test "returns Local backend by default" do
      original_config = Application.get_env(:lumainus, :docling, [])
      Application.put_env(:lumainus, :docling, Keyword.delete(original_config, :backend))

      on_exit(fn ->
        Application.put_env(:lumainus, :docling, original_config)
      end)

      assert Docling.backend() == Lumainus.Docling.Backends.Local
    end

    test "returns configured backend" do
      original_config = Application.get_env(:lumainus, :docling, [])
      Application.put_env(:lumainus, :docling, Keyword.put(original_config, :backend, :remote))

      on_exit(fn ->
        Application.put_env(:lumainus, :docling, original_config)
      end)

      assert Docling.backend() == Lumainus.Docling.Backends.Remote
    end

    test "raises on unknown backend" do
      original_config = Application.get_env(:lumainus, :docling, [])
      Application.put_env(:lumainus, :docling, Keyword.put(original_config, :backend, :unknown))

      on_exit(fn ->
        Application.put_env(:lumainus, :docling, original_config)
      end)

      assert_raise ArgumentError, ~r/Unknown backend/, fn ->
        Docling.backend()
      end
    end
  end

  describe "capabilities/0" do
    test "returns capabilities from backend" do
      caps = Docling.capabilities()

      assert is_list(caps)
      assert :sync in caps
      assert :async in caps
    end
  end

  describe "timeout/0" do
    test "returns configured timeout" do
      original_config = Application.get_env(:lumainus, :docling, [])

      Application.put_env(
        :lumainus,
        :docling,
        Keyword.put(original_config, :request_timeout, 60_000)
      )

      on_exit(fn ->
        Application.put_env(:lumainus, :docling, original_config)
      end)

      assert Docling.timeout() == 60_000
    end

    test "returns default timeout when not configured" do
      original_config = Application.get_env(:lumainus, :docling, [])
      Application.put_env(:lumainus, :docling, Keyword.delete(original_config, :request_timeout))

      on_exit(fn ->
        Application.put_env(:lumainus, :docling, original_config)
      end)

      assert Docling.timeout() == 1_200_000
    end
  end

  describe "config/0" do
    test "returns docling config" do
      config = Docling.config()

      assert is_list(config)
    end
  end

  describe "cancel/1" do
    setup do
      bypass = Bypass.open()
      base_url = "http://localhost:#{bypass.port}"

      original_config = Application.get_env(:lumainus, :docling, [])

      new_config =
        original_config
        |> Keyword.put(:backend, :local)
        |> Keyword.put(:local_url, base_url)

      Application.put_env(:lumainus, :docling, new_config)

      on_exit(fn ->
        Application.put_env(:lumainus, :docling, original_config)
      end)

      {:ok, bypass: bypass}
    end

    test "delegates to backend", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/jobs/test-job", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"status" => "cancelled"}))
      end)

      assert :ok = Docling.cancel("test-job")
    end
  end
end
