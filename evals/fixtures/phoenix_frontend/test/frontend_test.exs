defmodule HarnessFixture.FrontendTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest
  @endpoint HarnessFixtureWeb.Endpoint

  setup do
    :ok = HarnessFixture.Runtime.reset()
    :ok
  end

  test "the page renders current actor state and safely escapes objectives" do
    {:ok, _} = HarnessFixture.Runtime.start_goal("Inspect <script>alert(1)</script>")
    body = build_conn() |> get("/") |> html_response(200)
    assert body =~ "Harness"
    assert body =~ "name=\"objective\""
    assert body =~ "running"
    assert body =~ "&lt;script&gt;"
    refute body =~ "<script>alert(1)</script>"
  end

  test "submitting and cancelling a goal uses the runtime" do
    created = browser_post("/goals", %{"objective" => "Build the frontend"})
    assert created.status in [302, 303]
    assert get_resp_header(created, "location") == ["/"]
    assert [%{id: id, objective: "Build the frontend", status: :running}] = HarnessFixture.Runtime.goals()
    cancelled = browser_post("/goals/#{id}/cancel", %{})
    assert cancelled.status in [302, 303]
    assert [%{status: :cancelled}] = HarnessFixture.Runtime.goals()
    assert build_conn() |> get("/") |> html_response(200) =~ "cancelled"
  end

  test "blank goals are rejected without creating actor state" do
    body = browser_post("/goals", %{"objective" => "  "}) |> html_response(422)
    assert String.downcase(body) =~ "objective"
    assert HarnessFixture.Runtime.goals() == []
  end

  defp browser_post(path, params) do
    # ConnTest disables CSRF validation for this synthetic request, while the
    # actual browser pipeline should still use protect_from_forgery.
    build_conn() |> put_private(:plug_skip_csrf_protection, true) |> post(path, params)
  end
end
