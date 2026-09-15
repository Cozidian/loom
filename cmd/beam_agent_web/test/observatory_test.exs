defmodule BeamAgentWeb.ObservatoryTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  @endpoint BeamAgentWeb.Endpoint

  setup do
    root =
      Path.join(System.tmp_dir!(), "beam-desk-observatory-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)

    git!(workspace, ["init", "-q"])
    git!(workspace, ["config", "user.email", "observatory@test.local"])
    git!(workspace, ["config", "user.name", "Observatory Test"])

    for n <- 1..4 do
      File.write!(Path.join(workspace, "route.ts"), "export const n = #{n};")
      File.mkdir_p!(Path.join(workspace, "messages"))
      File.write!(Path.join(workspace, "messages/en.json"), ~s({"n": #{n}}))
      git!(workspace, ["add", "route.ts", "messages/en.json"])
      git!(workspace, ["commit", "-m", "update route ##{n}"])
    end

    File.mkdir_p!(Path.join([workspace, ".github", "workflows"]))

    File.write!(Path.join([workspace, ".github", "workflows", "ci.yml"]), ~s"""
    name: Checks
    on: [push]
    jobs:
      build:
        runs-on: ubuntu-latest
    """)

    git!(workspace, ["add", ".github"])
    git!(workspace, ["commit", "-m", "add ci"])

    {:ok, id} =
      BeamAgent.start_session(
        workspace_root: workspace,
        data_dir: Path.join(root, "runtime"),
        provider: :echo,
        strategy: BeamAgent.Strategies.ToolLoop
      )

    token = "observatory-test-token-0123456789"
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

    %{id: id, token: token}
  end

  defp git!(workspace, args), do: {_, 0} = System.cmd("git", args, cd: workspace)

  test "the observatory page renders real churn, hotspot and CI data from the workspace", ctx do
    conn = get(local_conn(), "/")
    conn = login(conn, ctx.token)
    conn = get(recycle(conn), "/observatory")
    body = html_response(conn, 200)

    assert body =~ "REPOSITORY OBSERVATORY"
    assert body =~ "route.ts"
    assert body =~ "messages/en.json"
    assert body =~ "Checks"
    assert body =~ "Change constellation"
    assert body =~ "obs-data"
  end

  test "the observatory data endpoint returns the same report as JSON", ctx do
    conn = get(local_conn(), "/")
    conn = login(conn, ctx.token)
    conn = get(recycle(conn), "/observatory/data")
    body = json_response(conn, 200)

    assert body["commits_sampled"] == 5
    paths = Enum.map(body["constellation"]["nodes"], & &1["path"])
    assert "route.ts" in paths
    assert "messages/en.json" in paths
    assert [%{"name" => "Checks"}] = body["ci"]
  end

  test "the observatory page is gated behind login like every other route", ctx do
    assert get(local_conn(), "/observatory").status == 401
    assert get(local_conn(), "/observatory/data").status == 401

    conn = get(local_conn(), "/")
    conn = login(conn, ctx.token)
    refute conn.resp_body =~ ctx.token
  end

  test "the embedded report JSON cannot be used to break out of its script tag", ctx do
    conn = get(local_conn(), "/")
    conn = login(conn, ctx.token)
    conn = get(recycle(conn), "/observatory")
    body = html_response(conn, 200)

    refute body =~ "</script><script>"
    assert body =~ "<script type=\"application/json\" id=\"obs-data\">"
  end

  defp local_conn, do: %{build_conn() | host: "localhost"}

  defp login(conn, token),
    do: post(recycle(conn), "/login", %{"token" => token, "_csrf_token" => csrf(conn)})

  defp csrf(conn),
    do: Regex.run(~r/name=_csrf_token value="([^"]+)"/, conn.resp_body) |> Enum.at(1)
end
