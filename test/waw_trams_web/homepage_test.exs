defmodule WawTramsWeb.HomepageTest do
  use WawTramsWeb.ConnCase

  test "GET / renders audit page", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Infrastructure Report Card"
  end
end
