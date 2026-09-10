defmodule BeamAgentWeb.DeskTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest
  @endpoint BeamAgentWeb.Endpoint

  defmodule BlockingProvider do
    @behaviour BeamAgent.LLMProvider
    def id, do: :desk_blocking_test

    def complete(_messages, _tools, options) do
      send(options[:test_pid], :provider_running)
      Process.sleep(:infinity)
    end
  end

  setup_all do
    BeamAgent.CapabilityCatalog.register_provider(BlockingProvider)
  end

  setup tags do
    root = Path.join(System.tmp_dir!(), "beam-desk-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "workspace"))

    {:ok, id} =
      BeamAgent.start_session(
        workspace_root: Path.join(root, "workspace"),
        data_dir: Path.join(root, "runtime"),
        provider: if(tags[:blocking], do: :desk_blocking_test, else: :echo),
        provider_options: [test_pid: self()],
        strategy: BeamAgent.Strategies.ToolLoop
      )

    token = "desk-test-token-0123456789"
    {:ok, server} = BeamAgent.start_web_control_plane(id, token: token, conversation: true)
    {:ok, url} = BeamAgent.ControlPlane.HTTPServer.url(server)
    port = URI.parse(url).port
    Application.put_env(:beam_agent_web, :runtime_url, "http://127.0.0.1:#{port}")
    Application.put_env(:beam_agent_web, :runtime_token, token)

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)
      BeamAgent.stop_session(id)
      File.rm_rf(root)
      Application.delete_env(:beam_agent_web, :runtime_url)
      Application.delete_env(:beam_agent_web, :runtime_token)
    end)

    %{id: id, token: token, server: server}
  end

  test "login gates the real runtime, token is not exposed in the page", ctx do
    conn = get(local_conn(), "/")
    assert html_response(conn, 200) =~ "Runtime access token"
    refute conn.resp_body =~ ctx.token
    assert get_resp_header(conn, "content-security-policy") != []
    assert get(local_conn(), "/panels").status == 401
    conn = login(conn, ctx.token)
    assert redirected_to(conn) == "/"
    conn = get(recycle(conn), "/")
    assert html_response(conn, 200) =~ ctx.id
    refute conn.resp_body =~ ctx.token
    assert {:ok, snapshot} = BeamAgentWeb.RuntimeClient.snapshot()
    assert snapshot["session_id"] == ctx.id
  end

  test "launch ticket establishes a browser session exactly once without sharing the runtime token",
       ctx do
    ticket = String.duplicate("launch-once-", 4)
    :ok = BeamAgentWeb.LaunchTicket.issue(ticket)
    conn = get(local_conn(), "/")
    refute conn.resp_body =~ ticket
    conn = post(recycle(conn), "/launch", %{"ticket" => ticket, "_csrf_token" => csrf(conn)})
    assert conn.status == 204
    assert get(recycle(conn), "/").resp_body =~ ctx.id
    fresh = get(local_conn(), "/")

    assert post(recycle(fresh), "/launch", %{"ticket" => ticket, "_csrf_token" => csrf(fresh)}).status ==
             401
  end

  test "expired tickets and runtime bearer tokens cannot bootstrap a session", ctx do
    ticket = String.duplicate("expired-", 5)
    :ok = BeamAgentWeb.LaunchTicket.issue(ticket, -1)
    refute BeamAgentWeb.LaunchTicket.consume(ticket)
    :ok = BeamAgentWeb.LaunchTicket.issue(String.duplicate("fresh-", 8))
    refute BeamAgentWeb.LaunchTicket.consume(ctx.token)
    refute BeamAgentWeb.LaunchTicket.consume(nil)
  end

  test "launch requires CSRF and a rejected request does not consume the ticket" do
    ticket = String.duplicate("csrf-launch-", 4)
    :ok = BeamAgentWeb.LaunchTicket.issue(ticket)

    assert_error_sent(403, fn ->
      local_conn()
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/launch", %{"ticket" => ticket})
    end)

    assert BeamAgentWeb.LaunchTicket.consume(ticket)
  end

  test "submit reaches the actual supervised runtime; logout does not stop its goal", ctx do
    conn = login(get(local_conn(), "/"), ctx.token) |> recycle() |> get("/")

    conn =
      post(recycle(conn), "/commands/submit", %{
        "prompt" => "Desk connection works",
        "_csrf_token" => csrf(conn)
      })

    assert redirected_to(conn) == "/"
    assert_event(ctx.id, "turn_finished")
    conn = get(recycle(conn), "/")
    assert conn.resp_body =~ "turn finished"
    assert conn.resp_body =~ "Conversation &amp; output"
    assert conn.resp_body =~ "echo(1): Desk connection works"
    assert conn.resp_body =~ "Work completed"
    conn = post(recycle(conn), "/logout", %{"_csrf_token" => csrf(conn)})
    assert redirected_to(conn) == "/"
    assert {:ok, _} = BeamAgent.agent_pid(ctx.id)
    assert get(recycle(conn), "/panels").status == 401
  end

  test "model output is readable text, never executable HTML", ctx do
    {:ok, _} = BeamAgent.ask(ctx.id, "<script>alert('output')</script> & result")
    conn = login(get(local_conn(), "/"), ctx.token) |> recycle() |> get("/")
    assert conn.resp_body =~ "&lt;script&gt;"
    refute conn.resp_body =~ "<script>alert('output')</script>"
    assert conn.resp_body =~ "Assistant output"
  end

  test "CSRF and foreign host requests are rejected", ctx do
    conn = login(get(local_conn(), "/"), ctx.token)

    assert_error_sent(403, fn ->
      conn
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/commands/cancel", %{})
    end)

    assert get(%{build_conn() | host: "attacker.example"}, "/").status == 403
  end

  @tag blocking: true
  test "cancellation stops active inference through the web API", ctx do
    conn = login(get(local_conn(), "/"), ctx.token) |> recycle() |> get("/")

    submitted =
      post(recycle(conn), "/commands/submit", %{
        "prompt" => "Wait for my cancellation",
        "_csrf_token" => csrf(conn)
      })

    assert redirected_to(submitted) == "/"
    assert_receive :provider_running, 2_000
    cancelled = post(recycle(conn), "/commands/cancel", %{"_csrf_token" => csrf(conn)})
    assert redirected_to(cancelled) == "/"
    assert_event(ctx.id, "turn_cancelled")
    assert {:ok, _} = BeamAgent.agent_pid(ctx.id)
  end

  test "web approvals resolve the runtime-owned request exactly once", ctx do
    conn = login(get(local_conn(), "/"), ctx.token) |> recycle() |> get("/")

    task =
      Task.async(fn ->
        BeamAgent.Session.ToolPolicy.authorize(
          ctx.id,
          "create_file",
          %{"path" => "example.txt"},
          :write,
          %{tools: "create_file"}
        )
      end)

    assert_event(ctx.id, "tool_approval_requested")
    {:ok, [request]} = BeamAgent.Session.ToolPolicy.pending(ctx.id)
    page = get(recycle(conn), "/")
    assert page.resp_body =~ "Your decision is needed"

    args = %{
      "approval_id" => request.approval_id,
      "decision" => "allow_once",
      "_csrf_token" => csrf(page)
    }

    assert post(recycle(page), "/commands/approval", args).status == 302
    assert Task.await(task, 2_000) == :ok
    assert post(recycle(page), "/commands/approval", args).status == 422
  end

  test "unavailable runtime and invalid commands are honest failures", ctx do
    conn = login(get(local_conn(), "/"), ctx.token) |> recycle() |> get("/")
    rejected = post(recycle(conn), "/commands/publish", %{"_csrf_token" => csrf(conn)})
    assert html_response(rejected, 422) =~ "Command not confirmed"
    Process.unlink(ctx.server)
    GenServer.stop(ctx.server)
    assert get(recycle(conn), "/panels").status == 503
    assert {:ok, _} = BeamAgent.agent_pid(ctx.id)
  end

  test "rendering escapes untrusted activity and session text" do
    html =
      BeamAgentWeb.Page.panels(
        %{
          "session_id" => "<script>alert(1)</script>",
          "recent_events" => [%{"payload" => %{"type" => "<img src=x>", "data" => %{}}}]
        },
        "csrf"
      )

    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"
    assert html =~ "&lt;img"
  end

  test "runtime transport cannot be redirected to non-loopback hosts or token URLs" do
    for url <- [
          "http://example.com",
          "http://localhost:4000",
          "http://127.0.0.1:4000/?token=secret",
          "http://user@127.0.0.1:4000",
          "https://127.0.0.1:4000"
        ] do
      Application.put_env(:beam_agent_web, :runtime_url, url)
      assert {:error, :invalid_runtime_url} = BeamAgentWeb.RuntimeClient.base_url()
    end
  end

  defp local_conn, do: %{build_conn() | host: "localhost"}

  defp login(conn, token),
    do: post(recycle(conn), "/login", %{"token" => token, "_csrf_token" => csrf(conn)})

  defp csrf(conn),
    do: Regex.run(~r/name=_csrf_token value="([^"]+)"/, conn.resp_body) |> Enum.at(1)

  defp assert_event(id, type, attempts \\ 100)
  defp assert_event(_id, _type, 0), do: flunk("runtime event did not arrive")

  defp assert_event(id, type, attempts) do
    {:ok, events} = BeamAgent.goal_events(id)

    unless Enum.any?(events, &(&1.payload.type == type)) do
      Process.sleep(20)
      assert_event(id, type, attempts - 1)
    end
  end
end
