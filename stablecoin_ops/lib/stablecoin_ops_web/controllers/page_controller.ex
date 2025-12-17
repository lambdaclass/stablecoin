defmodule StablecoinOpsWeb.PageController do
  use StablecoinOpsWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
