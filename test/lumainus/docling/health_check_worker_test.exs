defmodule Lumainus.Docling.HealthCheckWorkerTest do
  use Lumainus.DataCase

  alias Lumainus.Docling.HealthCheck
  alias Lumainus.Docling.HealthCheckWorker
  alias Oban.Job
  alias Plug.Conn

  setup do
    bypass = Bypass.open()
    original = Application.get_env(:lumainus, :docling, [])

    Application.put_env(
      :lumainus,
      :docling,
      Keyword.put(original, :base_url, "http://127.0.0.1:#{bypass.port}")
    )

    on_exit(fn -> Application.put_env(:lumainus, :docling, original) end)
    {:ok, bypass: bypass}
  end

  test "health worker records status", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/health", fn conn ->
      Conn.resp(conn, 200, ~s({"status":"ok"}))
    end)

    assert :ok = HealthCheckWorker.perform(%Job{args: %{}})

    [latest] = Repo.all(HealthCheck)
    assert latest.status == "healthy"
    assert latest.details["status"] == "ok"
  end
end
