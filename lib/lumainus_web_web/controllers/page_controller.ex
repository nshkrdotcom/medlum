defmodule LumainusWebWeb.PageController do
  use LumainusWebWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
