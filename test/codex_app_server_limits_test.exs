defmodule BeamAgent.CodexAppServerLimitsTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias BeamAgent.CodexAppServer
  alias BeamAgent.CodexAppServer.{Client, Conversation, TurnBudget}

  defmodule ScriptedClient do
    def start_link(options) do
      {:ok, client} = Agent.start_link(fn -> Map.new(options) end)
      send(options[:test_pid], {:client_started, client})
      {:ok, client}
    end

    def request(_client, "initialize", _params), do: {:ok, %{}}

    def request(_client, "account/read", _params),
      do: {:ok, %{"account" => %{"type" => "chatgpt"}}}

    def request(_client, "model/list", _params), do: {:ok, %{"data" => [%{"model" => "test"}]}}
    def request(_client, "thread/start", _params), do: {:ok, %{"thread" => %{"id" => "thread"}}}

    def request(client, "turn/start", _params) do
      state = Agent.get(client, & &1)
      Enum.each(state.events, &send(state.owner, {:codex_app_server, client, &1}))
      {:ok, %{"turn" => %{"id" => "turn"}}}
    end

    def notify(_client, _method, _params), do: :ok
    def stop(client), do: Agent.stop(client)
  end

  test "a silent turn expires and closes its client" do
    assert {:error, {:codex_turn_limit, :duration_ms, 20}} = invoke([], codex_turn_timeout_ms: 20)
    assert_receive {:client_started, client}
    refute Process.alive?(client)
  end

  test "the absolute deadline expires even with messages already queued" do
    events = List.duplicate(delta("hello"), 100) ++ [completed()]
    test_pid = self()

    emit = fn event ->
      send(test_pid, {:emitted, event})
      Process.sleep(30)
    end

    assert {:error, {:codex_turn_limit, :duration_ms, 20}} =
             invoke(events, [codex_turn_timeout_ms: 20], emit)

    assert_receive {:emitted, {:text_delta, "hello"}}
    refute_receive {:emitted, _}
  end

  test "all event channels consume the message budget, including empty and ignored deltas" do
    for method <- ["item/agentMessage/delta", "item/reasoning/summaryTextDelta", "unknown"] do
      events = List.duplicate(notification(method, %{"delta" => ""}), 4) ++ [completed()]

      assert {:error, {:codex_turn_limit, :messages, 3}} =
               invoke(events, codex_max_turn_messages: 3)

      assert_receive {:client_started, client}
      refute Process.alive?(client)
    end
  end

  test "bytes are limited before retaining or emitting text, summaries, items or tool arguments" do
    large = String.duplicate("x", 2_048)

    events = [
      delta(large),
      notification("item/reasoning/summaryTextDelta", %{"delta" => large}),
      notification("item/completed", %{"item" => %{"type" => "agentMessage", "text" => large}}),
      {:request,
       %{"id" => 1, "method" => "item/tool/call", "params" => %{"arguments" => %{"x" => large}}}}
    ]

    for event <- events do
      assert {:error, {:codex_turn_limit, :bytes, 1_024}} =
               invoke([event, completed()], [codex_max_turn_bytes: 1_024], fn event ->
                 flunk("oversized event was emitted: #{inspect(event)}")
               end)
    end
  end

  test "pending whitespace is preserved when text starts streaming" do
    chunks = List.duplicate(" \n", 2_000) ++ ["ASSI", "STANT", " ", "says hello"]
    text = Enum.join(chunks)
    test_pid = self()

    assert {:ok, %{content: ^text}} =
             invoke(Enum.map(chunks, &delta/1) ++ [completed()], [], fn event ->
               send(test_pid, {:emitted, event})
             end)

    assert_receive {:emitted, {:text_delta, ^text}}
    refute_receive {:emitted, _}
  end

  test "a fragmented serialized envelope preserves whitespace and stays hidden" do
    envelope =
      JSON.encode!(%{
        "content" => nil,
        "tool_calls" => [%{"id" => "c", "name" => "add", "arguments" => %{}}]
      })

    chunks =
      List.duplicate(" ", 2_000) ++
        ["ASSI", "STANT ", "\n"] ++
        List.duplicate(" ", 2_000) ++ String.graphemes(envelope)

    test_pid = self()

    assert {:ok, %{content: nil, tool_calls: [%{name: "add"}]}} =
             CodexAppServer.invoke(
               [%{role: :user, content: "test"}],
               [%{name: "add", description: "add", input_schema: %{type: "object"}}],
               options(Enum.map(chunks, &delta/1) ++ [completed()]),
               fn event -> send(test_pid, {:emitted, event}) end
             )

    refute_receive {:emitted, {:text_delta, _}}
  end

  test "a limited persistent conversation resets and the next invocation opens a fresh client" do
    opts = options([]) ++ [codex_turn_timeout_ms: 20]

    conversation =
      start_supervised!({Conversation, session_id: unique_id(), provider_options: opts})

    # Inherited provider limits apply even when not repeated on the invocation.
    assert {:error, {:codex_turn_limit, :duration_ms, 20}} =
             Conversation.invoke(conversation, [], [], [], fn _ -> :ok end)

    assert_receive {:client_started, first}
    refute Process.alive?(first)
    assert Process.alive?(conversation)

    assert {:ok, %{content: "healthy"}} =
             Conversation.invoke(
               conversation,
               [],
               [],
               options([delta("healthy"), completed()]),
               fn _ -> :ok end
             )

    assert_receive {:client_started, second}
    assert first != second
    assert Process.alive?(second)
  end

  test "invalid or infinite settings cannot disable the finite defaults" do
    budget =
      TurnBudget.new(
        codex_turn_timeout_ms: :infinity,
        codex_max_turn_bytes: 0,
        codex_max_turn_messages: -1
      )

    assert budget.timeout_ms == 1_800_000
    assert budget.max_bytes == 16_777_216
    assert budget.max_messages == 100_000
  end

  test "an idle subprocess exit also releases the retained client process" do
    opts = options([delta("healthy"), completed()])

    conversation =
      start_supervised!({Conversation, session_id: unique_id(), provider_options: opts})

    assert {:ok, _} = Conversation.invoke(conversation, [], [], [], fn _ -> :ok end)
    assert_receive {:client_started, client}

    send(conversation, {:codex_app_server, client, {:exit, {:codex_app_server_exit, 1}}})
    assert %{conversation: nil} = :sys.get_state(conversation)
    refute Process.alive?(client)

    assert {:ok, %{content: "healthy"}} =
             Conversation.invoke(conversation, [], [], [], fn _ -> :ok end)
  end

  test "transport watchdog kills the child while its owner is not consuming notifications" do
    {client, os_pid} = transport("while :; do :; done")
    assert :ok = Client.begin_turn(client, codex_turn_timeout_ms: 20)

    assert_receive {:codex_app_server, ^client, {:exit, {:codex_turn_limit, :duration_ms, 20}}},
                   1_000

    assert_dead(os_pid)
    assert {:error, {:codex_turn_limit, :duration_ms, 20}} = Client.respond(client, 1, %{})
    assert %{port: nil, buffer: [], waiters: %{}} = :sys.get_state(client)
  end

  test "the watchdog releases a pending RPC with its structured error" do
    {client, os_pid} = transport("while :; do :; done")
    assert :ok = Client.begin_turn(client, codex_turn_timeout_ms: 20)

    assert {:error, {:codex_turn_limit, :duration_ms, 20}} =
             Client.request(client, "turn/start", %{}, 1_000)

    assert_dead(os_pid)
  end

  test "continuous stdout cannot starve the transport deadline" do
    {client, os_pid} =
      transport(
        "IFS= read -r trigger; while :; do printf '%s\\n' '{\"method\":\"ignored\"}'; done"
      )

    assert :ok =
             Client.begin_turn(client,
               codex_turn_timeout_ms: 20,
               codex_max_turn_messages: 10_000_000,
               codex_max_turn_bytes: 1_000_000_000
             )

    assert :ok = Client.notify(client, "go")

    assert_receive {:codex_app_server, ^client, {:exit, {:codex_turn_limit, :duration_ms, 20}}},
                   1_000

    assert_dead(os_pid)
  end

  test "transport bounds a notification flood before forwarding it to an unresponsive owner" do
    {client, os_pid} =
      transport(
        "IFS= read -r trigger; while :; do printf '%s\\n' '{\"method\":\"ignored\"}'; done"
      )

    assert :ok = Client.begin_turn(client, codex_max_turn_messages: 10)
    assert :ok = Client.notify(client, "go")

    assert_receive {:codex_app_server, ^client, {:exit, {:codex_turn_limit, :messages, 10}}},
                   1_000

    assert_dead(os_pid)
    assert length(drain_notifications(client)) == 10
  end

  test "transport byte budget covers raw stdout even without a complete line" do
    {client, os_pid} = transport("IFS= read -r trigger; while :; do printf 'xxxxxxxx'; done")
    assert :ok = Client.begin_turn(client, codex_max_turn_bytes: 128)
    assert :ok = Client.notify(client, "go")
    assert_receive {:codex_app_server, ^client, {:exit, {:codex_turn_limit, :bytes, 128}}}, 1_000
    assert_dead(os_pid)
    assert [] == drain_notifications(client)
  end

  test "transport bounds unterminated lines even before a turn starts" do
    {client, os_pid} =
      transport("IFS= read -r trigger; while :; do printf 'xxxxxxxx'; done", max_line_bytes: 128)

    assert :ok = Client.notify(client, "go")

    assert_receive {:codex_app_server, ^client,
                    {:exit, {:codex_transport_limit, :line_bytes, 128}}},
                   1_000

    assert_dead(os_pid)
    assert [] == drain_notifications(client)
  end

  test "transport completes an ordinary turn, cancels its timer and accepts another turn" do
    script =
      "while IFS= read -r trigger; do printf '%s\\n' '{\"method\":\"turn/completed\",\"params\":{\"turn\":{\"status\":\"completed\"}}}'; done"

    {client, _os_pid} = transport(script)

    for _ <- 1..2 do
      assert :ok = Client.begin_turn(client, codex_turn_timeout_ms: 40)
      assert :ok = Client.notify(client, "go")

      assert_receive {:codex_app_server, ^client,
                      {:notification, %{"method" => "turn/completed"}}},
                     1_000

      refute_receive {:codex_app_server, ^client, {:exit, _}}, 60
    end
  end

  test "owner cancellation kills a child that ignores stdin closing" do
    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, client} =
          Client.start_link(
            owner: self(),
            executable: "/bin/sh",
            arguments: ["-c", "while :; do :; done"]
          )

        %{port: port} = :sys.get_state(client)
        {:os_pid, os_pid} = Port.info(port, :os_pid)
        send(test_pid, {:owned_client, client, os_pid})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:owned_client, client, os_pid}, 1_000
    kill_on_exit(os_pid)
    monitor = Process.monitor(client)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^client, _}, 1_000
    assert_dead(os_pid)
  end

  defp invoke(events, overrides, emit \\ fn _ -> :ok end) do
    CodexAppServer.invoke(
      [%{role: :user, content: "test"}],
      [],
      Keyword.merge(options(events), overrides),
      emit
    )
  end

  defp options(events) do
    [
      model: "test",
      codex_client: ScriptedClient,
      codex_client_options: [test_pid: self(), events: events]
    ]
  end

  defp delta(text), do: notification("item/agentMessage/delta", %{"delta" => text})

  defp notification(method, params),
    do: {:notification, %{"method" => method, "params" => params}}

  defp completed, do: notification("turn/completed", %{"turn" => %{"status" => "completed"}})
  defp unique_id, do: "codex-limits-#{System.unique_integer([:positive])}"

  defp transport(script, options \\ []) do
    client =
      start_supervised!(
        {Client, [owner: self(), executable: "/bin/sh", arguments: ["-c", script]] ++ options}
      )

    %{port: port} = :sys.get_state(client)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    kill_on_exit(os_pid)
    {client, os_pid}
  end

  # These scripts are deliberately runaway processes; the assertions in this
  # module verify that the production watchdog kills them, but a failed
  # assertion or an interrupted run must not leave one orphaned and spinning
  # a CPU core forever. `kill -9` on an already-dead pid is a harmless no-op.
  defp kill_on_exit(os_pid) do
    on_exit(fn ->
      System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)
  end

  defp assert_dead(os_pid, attempts \\ 100) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, status} when status != 0 ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(10)
        assert_dead(os_pid, attempts - 1)

      _ ->
        flunk("owned subprocess #{os_pid} is still alive")
    end
  end

  defp drain_notifications(client) do
    receive do
      {:codex_app_server, ^client, {:notification, notification}} ->
        [notification | drain_notifications(client)]
    after
      0 -> []
    end
  end
end
