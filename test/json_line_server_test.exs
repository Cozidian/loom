defmodule BeamAgent.Runtime.JSONLineServerTest do
  use ExUnit.Case, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "beam-agent-api-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace, data_dir: data_dir}
  end

  test "authenticated loopback clients share runtime commands and live events", context do
    assert {:ok, session_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    token = "test-token-with-enough-entropy"
    assert {:ok, server} = BeamAgent.start_json_api(session_id, token: token)
    assert {:ok, {{127, 0, 0, 1}, port}} = BeamAgent.Runtime.JSONLineServer.address(server)

    assert {:ok, socket} =
             :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :line, active: false])

    unauthorized = %{
      version: 1,
      request_id: "bad",
      command: "status",
      token: "wrong-token-long-enough"
    }

    :ok = :gen_tcp.send(socket, [JSON.encode!(unauthorized), "\n"])
    assert {:ok, unauthorized_line} = :gen_tcp.recv(socket, 0, 2_000)
    assert JSON.decode!(unauthorized_line)["error"] == "unauthorized"

    request = %{version: 1, request_id: "status-1", command: "status", token: token}
    :ok = :gen_tcp.send(socket, [JSON.encode!(request), "\n"])
    assert {:ok, response_line} = :gen_tcp.recv(socket, 0, 2_000)
    response = JSON.decode!(response_line)
    assert response["ok"]
    assert response["request_id"] == "status-1"
    assert response["result"]["session_id"] == session_id

    assert {:ok, _event} =
             BeamAgent.Session.EventLog.append(session_id, :budget_warning, %{
               "resource" => "model_tokens"
             })

    assert {:ok, event_line} = receive_type(socket, "event", 2_000)
    event = JSON.decode!(event_line)
    assert event["event"]["payload"]["type"] == "budget_warning"

    Process.unlink(server)
    GenServer.stop(server)
    assert {:ok, :idle} = BeamAgent.Agent.status(session_id)
  end

  defp receive_type(socket, type, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, line} ->
        if JSON.decode!(line)["type"] == type,
          do: {:ok, line},
          else: receive_type(socket, type, timeout)

      error ->
        error
    end
  end
end
