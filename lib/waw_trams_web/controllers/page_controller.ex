defmodule WawTramsWeb.PageController do
  use WawTramsWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
