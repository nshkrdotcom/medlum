defmodule MedlumWeb.PageController do
  use MedlumWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
