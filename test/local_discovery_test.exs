defmodule BeamAgent.LocalDiscoveryTest do
  use ExUnit.Case, async: false
  alias BeamAgent.LocalDiscovery

  setup do
    root = Path.join(System.tmp_dir!(), "beam-live-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, directory: Path.join(root, "live")}
  end

  @tag timeout: 90_000
  test "two separate runtimes are discovered and web/TUI attach without starting a local owner",
       ctx do
    {one, first} = owner(ctx.root, "one")
    {two, second} = owner(ctx.root, "two")
    on_exit(fn -> for port <- [one, two], Port.info(port), do: Port.close(port) end)
    assert {:ok, %{sessions: sessions}} = LocalDiscovery.list(ctx.directory)
    assert Enum.sort(Enum.map(sessions, & &1["session_id"])) == Enum.sort([first, second])
    refute Enum.any?(sessions, &Map.has_key?(&1, "token"))
    assert {:error, _} = BeamAgent.agent_pid(first)
    assert {:ok, record} = LocalDiscovery.lookup(first, ctx.directory)

    assert {:ok, socket} =
             :gen_tcp.connect(
               {127, 0, 0, 1},
               record["tui_port"],
               [:binary, packet: 4, active: false],
               1000
             )

    :ok = :gen_tcp.send(socket, JSON.encode!(%{token: record["token"]}))
    assert {:ok, initial} = :gen_tcp.recv(socket, 0, 5000)
    assert %{"type" => "init", "session_id" => ^first} = JSON.decode!(initial)

    assert {:ok, _} =
             LocalDiscovery.request(record, :post, "/api/v1/command", %{
               version: 1,
               command: "submit",
               arguments: %{prompt: "web to existing TUI"}
             })

    assert receive_until(socket, "web to existing TUI")
    wait_answer(record, "web to existing TUI")
    :ok = :gen_tcp.send(socket, JSON.encode!(%{type: "submit", prompt: "attached TUI to web"}))
    assert receive_until(socket, "attached TUI to web")
    wait_answer(record, "attached TUI to web")
    :gen_tcp.close(socket)
    assert {:ok, _} = LocalDiscovery.lookup(first, ctx.directory)
    assert {:error, _} = BeamAgent.agent_pid(first)
    assert {:error, _} = LocalDiscovery.lookup("../config", ctx.directory)

    {:ok, unauth} =
      :gen_tcp.connect(
        {127, 0, 0, 1},
        record["tui_port"],
        [:binary, packet: 4, active: false],
        1000
      )

    :gen_tcp.send(unauth, JSON.encode!(%{token: "wrong"}))
    assert {:ok, rejected} = :gen_tcp.recv(unauth, 0, 1000)
    assert JSON.decode!(rejected) == %{"type" => "error", "error" => "unauthorized"}
    :gen_tcp.close(unauth)
    Port.command(one, "stop\n")
    assert_receive {^one, {:exit_status, 0}}, 5000
    assert {:ok, %{sessions: [%{"session_id" => ^second}]}} = LocalDiscovery.list(ctx.directory)
    Port.command(two, "stop\n")
    assert_receive {^two, {:exit_status, 0}}, 5000
  end

  defp owner(root, name) do
    port =
      Port.open({:spawn_executable, System.find_executable("mix")}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:line, 4096},
        {:args, ["run", "--no-start", "test/support/discovery_owner_helper.exs", root, name]},
        {:env, [{~c"MIX_ENV", ~c"test"}]}
      ])

    {port, ready(port)}
  end

  defp ready(port) do
    receive do
      {^port, {:data, {:eol, "OWNER_READY " <> id}}} -> String.trim(id)
      {^port, {:data, _}} -> ready(port)
      {^port, {:exit_status, status}} -> flunk("owner failed: #{status}")
    after
      20_000 -> flunk("owner did not start")
    end
  end

  defp receive_until(socket, text, attempts \\ 150)
  defp receive_until(_, _, 0), do: false

  defp receive_until(socket, text, attempts) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, bytes} -> String.contains?(bytes, text) or receive_until(socket, text, attempts - 1)
      _ -> false
    end
  end

  defp wait_answer(record, text, remaining \\ 100)

  defp wait_answer(record, _, 0),
    do:
      flunk(
        "answer not visible: #{inspect(LocalDiscovery.request(record, :get, "/api/v1/conversation"))}"
      )

  defp wait_answer(record, text, remaining) do
    {:ok, conversation} = LocalDiscovery.request(record, :get, "/api/v1/conversation")

    if Enum.any?(
         conversation["messages"],
         &(&1["role"] == "assistant" and String.contains?(&1["content"], text))
       ) and conversation["status"] == "completed" do
      :ok
    else
      Process.sleep(20)
      wait_answer(record, text, remaining - 1)
    end
  end
end
