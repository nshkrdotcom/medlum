defmodule LumainusWeb.PageControllerTest do
  use LumainusWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Welcome to Lumainus"
  end
end
