defmodule MedlumWeb.Admin.VastAILiveTest do
  use MedlumWeb.ConnCase

  import Phoenix.LiveViewTest
  import Medlum.AccountsFixtures

  alias Ecto.Changeset
  alias Medlum.Repo

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = Repo.update(Changeset.change(user, role: "admin"))

    {:ok, conn: log_in_user(conn, user)}
  end

  test "shows unavailable banner when Vast.ai is disabled", %{conn: conn} do
    Application.delete_env(:medlum, :vast_ai)

    {:ok, _view, html} = live(conn, ~p"/admin/vast_ai")

    assert html =~ "Vast.ai unavailable"
    assert html =~ "VAST_API_KEY"
  end

  test "renders when Vast.ai is enabled and processes are running", %{conn: conn} do
    original_config = Application.get_env(:medlum, :vast_ai)
    enabled_config = Keyword.put(original_config || [], :api_key, "test-key")

    Application.put_env(:medlum, :vast_ai, enabled_config)

    on_exit(fn ->
      if original_config do
        Application.put_env(:medlum, :vast_ai, original_config)
      else
        Application.delete_env(:medlum, :vast_ai)
      end
    end)

    ensure_started(Medlum.Docling.VastAI.StartTracker)
    ensure_started(Medlum.Docling.VastAI.ActivityTracker)
    ensure_started(Medlum.Docling.VastAI.InstanceManager)
    ensure_started(Medlum.Docling.VastAI.ProvisioningState)

    {:ok, view, html} = live(conn, ~p"/admin/vast_ai")

    assert html =~ "Vast.ai GPU Instances"
    assert has_element?(view, "[data-testid=\"vastai-status-pill\"]", "Vast.ai ready")
  end

  defp ensure_started(module) do
    case start_supervised(module) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end
end
