defmodule BeamAgent.ControlPlaneTest do
  use ExUnit.Case, async: false

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-control-plane-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace, data_dir: data_dir}
  end

  test "the web control-plane state is an observer and survives independently", context do
    assert {:ok, session_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    assert {:ok, control_plane} = BeamAgent.ControlPlane.start_link(session_id: session_id)
    assert {:ok, snapshot} = BeamAgent.ControlPlane.snapshot(control_plane)
    assert snapshot.session_id == session_id
    assert snapshot.tree.root.session_id == session_id
    assert snapshot.repository.file_count == 0

    assert {:ok, html} = BeamAgent.ControlPlane.render_html(control_plane)
    assert html =~ "BEAM AGENT"
    assert html =~ session_id

    GenServer.stop(control_plane)
    assert {:ok, _agent} = BeamAgent.agent_pid(session_id)
    assert {:ok, answer} = BeamAgent.ask(session_id, "still alive")
    assert answer =~ "still alive"
  end

  test "the authenticated loopback web shell exposes live runtime state", context do
    assert {:ok, session_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    token = "control-plane-test-token"

    assert {:ok, server} =
             BeamAgent.start_web_control_plane(session_id, token: token)

    assert {:ok, url} = BeamAgent.ControlPlane.HTTPServer.url(server)
    uri = URI.parse(url)

    assert {:ok, page} =
             http_request(uri.port, "GET /?token=#{token} HTTP/1.1\r\nhost: localhost\r\n\r\n")

    assert page =~ "200 OK"
    assert page =~ "BeamAgent Control Plane"

    assert {:ok, snapshot_response} =
             http_request(
               uri.port,
               "GET /api/v1/snapshot?token=#{token} HTTP/1.1\r\nhost: localhost\r\n\r\n"
             )

    [_headers, body] = String.split(snapshot_response, "\r\n\r\n", parts: 2)
    snapshot = JSON.decode!(body)
    assert snapshot["ok"]
    assert snapshot["result"]["session_id"] == session_id

    Process.unlink(server)
    GenServer.stop(server)
    assert {:ok, _agent} = BeamAgent.agent_pid(session_id)
  end

  defp http_request(port, request) do
    with {:ok, socket} <-
           :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000),
         :ok <- :gen_tcp.send(socket, request),
         {:ok, response} <- receive_all(socket, "") do
      {:ok, response}
    end
  end

  defp receive_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, bytes} -> receive_all(socket, acc <> bytes)
      {:error, :closed} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end
end
