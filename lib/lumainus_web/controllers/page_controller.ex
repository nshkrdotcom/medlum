defmodule LumainusWeb.PageController do
  use LumainusWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
