defmodule MedlumWeb.PageControllerTest do
  use MedlumWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "MEDLUM"
  end
end
