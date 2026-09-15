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

  test "fresh launch tickets reconnect after logout without invalidating another pending launch",
       ctx do
    first = String.duplicate("first-", 8)
    second = String.duplicate("second-", 8)
    :ok = BeamAgentWeb.LaunchTicket.issue(first)
    :ok = BeamAgentWeb.LaunchTicket.issue(second)
    assert BeamAgentWeb.LaunchTicket.consume(first)
    refute BeamAgentWeb.LaunchTicket.consume(first)
    conn = login(get(local_conn(), "/"), ctx.token) |> recycle() |> post("/logout")
    conn = get(recycle(conn), "/")
    assert conn.resp_body =~ "./loom desk"
    conn = post(recycle(conn), "/launch", %{ticket: second, _csrf_token: csrf(conn)})
    assert conn.status == 204
    assert get(recycle(conn), "/panels").status == 200
    assert {:ok, _} = BeamAgent.agent_pid(ctx.id)
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

  test "the directory shows each session's live activity and escapes untrusted fields" do
    five_minutes_ago = DateTime.add(DateTime.utc_now(), -300, :second) |> DateTime.to_iso8601()

    html =
      BeamAgentWeb.Page.directory(%{
        "sessions" => [
          %{
            "session_id" => "session-idle",
            "workspace" => "/work/idle",
            "owner_pid" => "1",
            "started_at" => five_minutes_ago,
            "agent_status" => "idle"
          },
          %{
            "session_id" => "session-running",
            "workspace" => "/work/running",
            "owner_pid" => "1",
            "started_at" => five_minutes_ago,
            "agent_status" => "running",
            "running_for_ms" => 65_000
          },
          %{
            "session_id" => "<script>alert(1)</script>",
            "workspace" => "/work/unknown",
            "owner_pid" => "1",
            "started_at" => nil
          }
        ]
      })

    assert html =~ "status-idle"
    assert html =~ "Idle"
    assert html =~ "status-running"
    assert html =~ "Running · 1m"
    assert html =~ "status-unknown"
    assert html =~ "Started 5m ago"
    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"
  end

  test "each conversation message gets a copy button next to a plain-text pre block" do
    html =
      BeamAgentWeb.Page.panels(
        %{
          "conversation" => %{
            "status" => "idle",
            "messages" => [
              %{"role" => "user", "content" => "tell me a joke", "at" => "2026-01-01T00:00:00Z"},
              %{
                "role" => "assistant",
                "content" => "Why don't scientists trust atoms?",
                "at" => "2026-01-01T00:00:01Z"
              }
            ]
          }
        },
        "csrf"
      )

    assert Enum.count(String.split(html, "copy-button")) - 1 == 2
    assert html =~ ~s(aria-label="Copy message")
    assert html =~ "tell me a joke"
    assert html =~ "Why don&#39;t scientists trust atoms?"
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

  test "findings are escaped and follow-up confirmation uses server-owned evidence", ctx do
    {:ok, pid} = BeamAgent.Names.pid(:documentation_mission, ctx.id)

    report = %{
      "status" => "advisory",
      "worker_id" => "fixture",
      "fingerprint" => "fixture",
      "content" =>
        "REVIEW_WARN\n1. **README <img src=x>**\n- **Evidence:** <script>attack()</script>\n- **Uncertainty:** Partial excerpt\n- **Next action:** Re-read the source"
    }

    :sys.replace_state(pid, fn state -> %{state | data: Map.put(state.data, "report", report)} end)

    shown = BeamAgent.Missions.Report.present(report)
    finding = hd(shown["findings"])
    params = %{report_id: shown["id"], finding_id: finding["id"]}
    assert get(local_conn(), "/observer/followup", params).status == 401
    conn = login(get(local_conn(), "/"), ctx.token) |> recycle() |> get("/")
    assert conn.resp_body =~ "finding-card"
    assert conn.resp_body =~ "&lt;script&gt;"
    refute conn.resp_body =~ "<script>attack()"
    conn = get(recycle(conn), "/observer/followup", params)
    assert conn.resp_body =~ "Start isolated fix agent"
    assert conn.resp_body =~ "No automatic merge"
    assert {:ok, []} = BeamAgent.worker_delegations(ctx.id)

    assert_error_sent(403, fn ->
      recycle(conn)
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/commands/documentation_mission", Map.put(params, :action, "prepare_fix"))
    end)

    rejected =
      post(recycle(conn), "/commands/documentation_mission", %{
        action: "prepare_fix",
        report_id: "old",
        finding_id: finding["id"],
        _csrf_token: csrf(conn)
      })

    assert rejected.status == 422
    assert {:ok, []} = BeamAgent.worker_delegations(ctx.id)
  end

  test "computer browsing and startup status are authenticated; creation errors return to the themed desk",
       ctx do
    for path <- [
          "/workspaces",
          "/workspaces/paths",
          "/session-starts/unknown",
          "/session-starts/unknown/status"
        ] do
      assert get(local_conn(), path).status == 401
    end

    conn = login(get(local_conn(), "/"), ctx.token) |> recycle() |> get("/")
    # This fixture deliberately has only a single-session API, not a catalog.
    result =
      post(recycle(conn), "/sessions", %{
        _csrf_token: csrf(conn),
        request_id: "explicit-start-request"
      })

    assert redirected_to(result) == "/"
    assert get_session(result, :notice) =~ "Session startup not confirmed"
    assert get(recycle(conn), "/workspaces").resp_body =~ "Workspace browser unavailable"
    assert get(recycle(conn), "/session-starts/unknown").resp_body =~ "Startup status unavailable"

    assert_error_sent(403, fn ->
      recycle(conn)
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/sessions", %{workspace: "/", request_id: "explicit-start-request"})
    end)
  end

  test "documentation controls use the existing runtime and expose failures without claiming success",
       ctx do
    {:ok, context} = BeamAgent.Agent.construction_context(ctx.id)
    System.cmd("git", ["init", "-q"], cd: context.workspace_root)
    File.write!(Path.join(context.workspace_root, "README.md"), "Documentation fixture")
    System.cmd("git", ["add", "README.md"], cd: context.workspace_root)
    assert post(local_conn(), "/commands/documentation_mission", %{action: "start"}).status == 401
    conn = login(get(local_conn(), "/"), ctx.token) |> recycle() |> get("/")
    assert conn.resp_body =~ "Start documentation observer"
    assert conn.resp_body =~ "provider allowance"

    conn =
      post(recycle(conn), "/commands/documentation_mission", %{
        "action" => "start",
        "_csrf_token" => csrf(conn)
      })

    assert redirected_to(conn) == "/"

    assert {:ok, %{"status" => "observing", "attempts" => 0}} =
             BeamAgent.Missions.Documentation.command(ctx.id, "status")

    conn = get(recycle(conn), "/")
    assert conn.resp_body =~ "Pause observer"

    conn =
      post(recycle(conn), "/commands/documentation_mission", %{
        "action" => "start",
        "_csrf_token" => csrf(conn)
      })

    assert conn.status == 422
    assert conn.resp_body =~ "mission_already_configured"

    conn =
      post(recycle(conn), "/commands/documentation_mission", %{
        "action" => "pause",
        "_csrf_token" => csrf(conn)
      })

    assert redirected_to(conn) == "/"
    conn = get(recycle(conn), "/panels")
    assert conn.resp_body =~ "Resume observer"

    assert {:ok, %{"status" => "paused"}} =
             BeamAgent.Missions.Documentation.command(ctx.id, "status")

    assert conn.resp_body =~ "Stop observer & fixes"

    conn =
      post(recycle(conn), "/commands/documentation_mission", %{
        action: "stop",
        _csrf_token: csrf(conn)
      })

    assert redirected_to(conn) == "/"
    conn = get(recycle(conn), "/panels")
    assert conn.resp_body =~ "Delete observer"
    assert conn.resp_body =~ "Session history and retained worktrees are always kept"

    conn =
      post(recycle(conn), "/commands/documentation_mission", %{
        action: "delete",
        _csrf_token: csrf(conn)
      })

    assert redirected_to(conn) == "/"

    assert {:ok, %{"status" => "disabled"}} =
             BeamAgent.Missions.Documentation.command(ctx.id, "status")

    assert File.read!(Path.join(context.workspace_root, "README.md")) == "Documentation fixture"
  end

  test "mission reports are escaped and unavailable runtime status cannot offer start" do
    html =
      BeamAgentWeb.Page.panels(
        %{
          "documentation_mission" => %{
            "status" => "paused",
            "available_actions" => ["dismiss"],
            "report" => %{
              "status" => "advisory",
              "content" => "<script>attack()</script>",
              "worker_id" => "test"
            }
          }
        },
        "csrf"
      )

    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>attack()</script>"
    assert html =~ "Dismiss report"
    unavailable = BeamAgentWeb.Page.panels(%{}, "csrf")
    assert unavailable =~ "Mission status unavailable"
    refute unavailable =~ "Start documentation observer"
  end

  test "observer scope editor browses the runtime and forwards selected paths safely", ctx do
    {:ok, context} = BeamAgent.Agent.construction_context(ctx.id)
    File.mkdir_p!(Path.join(context.workspace_root, "docs with spaces"))
    File.write!(Path.join(context.workspace_root, "docs with spaces/guide.md"), "guide")
    System.cmd("git", ["init", "-q"], cd: context.workspace_root)
    System.cmd("git", ["add", "docs with spaces"], cd: context.workspace_root)
    assert get(local_conn(), "/observer").status == 401
    assert get(local_conn(), "/observer/paths").status == 401
    conn = login(get(local_conn(), "/"), ctx.token) |> recycle() |> get("/observer")
    assert html_response(conn, 200) =~ "Choose what"
    assert conn.resp_body =~ context.workspace_root
    assert conn.resp_body =~ "docs with spaces"
    listing = get(recycle(conn), "/observer/paths", %{path: "docs with spaces"})
    assert [%{"name" => "guide.md"}] = json_response(listing, 200)["entries"]
    assert get(recycle(conn), "/observer/paths", %{path: "../"}).status == 422

    for paths <- ["", "../outside", ["docs with spaces"]] do
      rejected =
        post(recycle(conn), "/commands/documentation_mission", %{
          action: "start",
          paths: paths,
          _csrf_token: csrf(conn)
        })

      assert rejected.status == 422

      assert {:ok, %{"status" => "disabled"}} =
               BeamAgent.Missions.Documentation.command(ctx.id, "status")
    end

    assert_error_sent(403, fn ->
      recycle(conn)
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/commands/documentation_mission", %{action: "start", paths: "docs with spaces"})
    end)

    started =
      post(recycle(conn), "/commands/documentation_mission", %{
        action: "start",
        paths: "docs with spaces",
        _csrf_token: csrf(conn)
      })

    assert redirected_to(started) == "/"

    assert {:ok, %{"paths" => ["docs with spaces"], "status" => "observing"}} =
             BeamAgent.Missions.Documentation.command(ctx.id, "status")

    stale =
      post(recycle(conn), "/commands/documentation_mission", %{
        action: "configure",
        paths: ".",
        _csrf_token: csrf(conn)
      })

    assert stale.status == 422
    assert stale.resp_body =~ "pause_mission_before_changing_scope"
    assert :ok = BeamAgent.Missions.Documentation.command(ctx.id, "pause")

    saved =
      post(recycle(conn), "/commands/documentation_mission", %{
        action: "configure",
        paths: ".",
        _csrf_token: csrf(conn)
      })

    assert redirected_to(saved) == "/"

    assert {:ok, %{"paths" => ["."], "status" => "paused", "attempts" => 0}} =
             BeamAgent.Missions.Documentation.command(ctx.id, "status")
  end

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
