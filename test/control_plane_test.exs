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

  test "an oversized request body is rejected instead of read without bound", context do
    assert {:ok, session_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    token = "control-plane-oversized-test-token"
    assert {:ok, server} = BeamAgent.start_web_control_plane(session_id, token: token)
    assert {:ok, url} = BeamAgent.ControlPlane.HTTPServer.url(server)
    port = URI.parse(url).port

    oversized = String.duplicate("x", 1_048_577)

    request =
      "POST /api/v1/command HTTP/1.1\r\nhost: localhost\r\n" <>
        "authorization: Bearer #{token}\r\ncontent-length: #{byte_size(oversized)}\r\n\r\n" <>
        oversized

    assert {:ok, response} = http_request(port, request)
    assert response =~ "413"

    Process.unlink(server)
    GenServer.stop(server)
  end

  test "owner conversation is opt-in, bearer-only, replayable and separate from public metadata",
       context do
    {:ok, id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :echo
      )

    {:ok, answer} = BeamAgent.ask(id, "private-output-sentinel")
    token = "private-conversation-test-token"
    {:ok, server} = BeamAgent.start_web_control_plane(id, token: token, conversation: true)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    {:ok, url} = BeamAgent.ControlPlane.HTTPServer.url(server)
    port = URI.parse(url).port

    {:ok, public} =
      http_request(
        port,
        "GET /api/v1/snapshot HTTP/1.1\r\nhost: localhost\r\nauthorization: Bearer #{token}\r\n\r\n"
      )

    refute public =~ "private-output-sentinel"

    {:ok, private} =
      http_request(
        port,
        "GET /api/v1/conversation HTTP/1.1\r\nhost: localhost\r\nauthorization: Bearer #{token}\r\n\r\n"
      )

    assert private =~ answer
    assert private =~ "no-store"

    {:ok, denied} =
      http_request(
        port,
        "GET /api/v1/conversation?token=#{token} HTTP/1.1\r\nhost: localhost\r\n\r\n"
      )

    assert denied =~ "401 Unauthorized"
    refute denied =~ answer
    {:ok, disabled} = BeamAgent.ControlPlane.start_link(session_id: id)
    assert {:error, :conversation_not_enabled} = BeamAgent.ControlPlane.conversation(disabled)
    GenServer.stop(disabled)
  end

  test "conversation projection excludes child, reasoning and tool payloads and bounds text" do
    alias BeamAgent.ControlPlane.Conversation
    root = "root"

    event = fn session, seq, type, data ->
      BeamAgent.RuntimeEvent.durable("project", root, session, %{
        "seq" => seq,
        "type" => type,
        "data" => data
      })
    end

    state = Conversation.new()

    for {session, type} <- [
          {"child", "assistant_message"},
          {root, "tool_result"},
          {root, "model_response_checkpoint"}
        ] do
      assert Conversation.consume(event.(session, 1, type, %{"content" => "secret"}), state).messages ==
               []
    end

    long = String.duplicate("æ", 20_000)

    result =
      Enum.reduce(1..30, state, fn seq, acc ->
        Conversation.consume(event.(root, seq, "assistant_message", %{"content" => long}), acc)
      end)

    assert length(result.messages) <= 24
    assert Enum.sum(Enum.map(result.messages, &byte_size(&1.content))) <= 128_000
    assert Enum.all?(result.messages, &(&1.truncated and String.valid?(&1.content)))
  end

  # Reads by Content-Length rather than until the peer closes the socket:
  # the server may keep connections alive (HTTP/1.1 default), so relying on
  # EOF would just time out.
  defp http_request(port, request) do
    with {:ok, socket} <-
           :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000),
         :ok <- :gen_tcp.send(socket, request),
         {:ok, response} <- receive_response(socket, "") do
      :gen_tcp.close(socket)
      {:ok, response}
    end
  end

  defp receive_response(socket, buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {index, 4} ->
        header_block = binary_part(buffer, 0, index + 4)
        body_so_far = binary_part(buffer, index + 4, byte_size(buffer) - index - 4)
        read_body(socket, header_block, body_so_far, content_length(header_block))

      :nomatch ->
        case :gen_tcp.recv(socket, 0, 2_000) do
          {:ok, bytes} -> receive_response(socket, buffer <> bytes)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp content_length(header_block) do
    case Regex.run(~r/content-length:\s*(\d+)/i, header_block) do
      [_, value] -> String.to_integer(value)
      nil -> 0
    end
  end

  defp read_body(_socket, header_block, body, length) when byte_size(body) >= length,
    do: {:ok, header_block <> body}

  defp read_body(socket, header_block, body, length) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, bytes} -> read_body(socket, header_block, body <> bytes, length)
      {:error, reason} -> {:error, reason}
    end
  end
end
