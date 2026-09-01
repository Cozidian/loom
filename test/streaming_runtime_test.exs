defmodule BeamAgent.StreamingRuntimeTest do
  use ExUnit.Case, async: false

  alias BeamAgent.CLI.TurnRunner
  alias BeamAgent.Session.StreamHub

  defmodule StreamingProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :streaming_runtime_test

    @impl true
    def complete(_messages, _tools, _options),
      do: {:ok, %{content: "non-stream fallback", tool_calls: []}}

    @impl true
    def stream(messages, _tools, _options, emit) do
      if List.last(messages).content == "wait" do
        emit.({:text_delta, "started"})
        Process.sleep(:infinity)
      else
        emit.({:text_delta, "live "})
        emit.({:text_delta, "answer"})
        emit.({:usage, %{"output_tokens" => 2}})
        {:ok, %{content: "live answer", tool_calls: []}}
      end
    end
  end

  setup_all do
    :ok = BeamAgent.CapabilityCatalog.register_provider(StreamingProvider)
    :ok
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "beam-agent-stream-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)
    %{data_dir: root}
  end

  test "a live turn emits normalized deltas and durably checkpoints the response", context do
    {:ok, session_id} =
      BeamAgent.start_session(data_dir: context.data_dir, provider: :streaming_runtime_test)

    owner = self()

    assert {:ok, "live answer", %{streamed_text?: true}} =
             TurnRunner.run_live(
               session_id,
               "hello",
               5_000,
               fn _request -> :deny end,
               fn event -> send(owner, {:live_event, event}) end
             )

    assert_receive {:live_event,
                    %{
                      type: :text_delta,
                      delta: "live ",
                      correlation_id: correlation_id,
                      causation_id: causation_id
                    }}

    assert is_binary(correlation_id)
    assert is_binary(causation_id)
    assert_receive {:live_event, %{type: :text_delta, delta: "answer"}}

    assert_receive {:live_event,
                    %{
                      type: :usage,
                      usage: %{
                        "output_tokens" => 2,
                        "total_tokens" => 2,
                        "provider_usage" => %{"output_tokens" => 2}
                      }
                    }}

    assert_receive {:live_event, %{type: :response_finished}}

    {:ok, events} = BeamAgent.events(session_id)
    types = Enum.map(events, & &1["type"])
    assert "model_response_started" in types
    assert "model_response_checkpoint" in types
    assert "model_response_finished" in types
    assert "assistant_message" in types

    checkpoint = Enum.find(events, &(&1["type"] == "model_response_checkpoint"))
    started = Enum.find(events, &(&1["type"] == "model_response_started"))

    assert started["correlation_id"] == correlation_id
    assert causation_id == "#{session_id}:#{started["seq"]}"

    assert Enum.map(checkpoint["data"]["events"], & &1["type"]) == [
             "text_delta",
             "text_delta",
             "usage"
           ]
  end

  test "non-streaming providers use the same durable invocation lifecycle", context do
    {:ok, session_id} = BeamAgent.start_session(data_dir: context.data_dir, provider: :echo)
    assert {:ok, "echo(1): hello"} = BeamAgent.ask(session_id, "hello")

    {:ok, events} = BeamAgent.events(session_id)
    started = Enum.find(events, &(&1["type"] == "model_response_started"))
    finished = Enum.find(events, &(&1["type"] == "model_response_finished"))
    outcome = Enum.find(events, &(&1["type"] == "model_outcome_recorded"))

    assert started["data"]["request_id"] =~ "model-request-"
    assert started["data"]["request_version"] == 1
    assert started["data"]["stream"] == false
    assert started["data"]["timeout"] == "infinity"
    assert finished["data"]["request_id"] == started["data"]["request_id"]
    assert finished["data"]["response_id"] == started["data"]["response_id"]
    assert finished["data"]["usage"]["provider_usage"] == %{}
    assert started["seq"] < finished["seq"]
    assert finished["seq"] < outcome["seq"]
  end

  test "dead stream subscribers are removed by process monitoring", context do
    {:ok, session_id} = BeamAgent.start_session(data_dir: context.data_dir, provider: :echo)
    {:ok, hub} = BeamAgent.stream_hub_pid(session_id)
    subscriber = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok = BeamAgent.subscribe(session_id, subscriber)
    assert Map.has_key?(:sys.get_state(hub).subscribers, subscriber)

    Process.exit(subscriber, :kill)

    assert eventually(fn ->
             not Map.has_key?(:sys.get_state(hub).subscribers, subscriber)
           end)
  end

  test "goal subscribers receive child activity in versioned runtime envelopes", context do
    {:ok, session_id} = BeamAgent.start_session(data_dir: context.data_dir, provider: :demo)
    assert :ok = BeamAgent.subscribe_goal(session_id)

    assert {:ok, answer} =
             BeamAgent.ask(session_id, "Calculate 2 + 3 and delegate verification.")

    assert answer =~ "subagent reported"

    assert_receive {:beam_agent_runtime_event,
                    %{
                      type: :runtime_event,
                      version: 1,
                      durability: :durable,
                      scope: %{
                        goal_id: ^session_id,
                        session_id: child_session_id,
                        root?: false
                      },
                      payload: %{type: "agent_started"}
                    }}

    assert child_session_id != session_id
  end

  test "commands provide causal lineage across parent and child sessions", context do
    {:ok, session_id} = BeamAgent.start_session(data_dir: context.data_dir, provider: :demo)

    assert {:ok, answer} =
             BeamAgent.ask(session_id, "Calculate 2 + 3 and delegate verification.")

    assert answer =~ "subagent reported"

    assert eventually(fn ->
             match?({:ok, events} when length(events) > 10, BeamAgent.goal_events(session_id))
           end)

    assert {:ok, events} = BeamAgent.goal_events(session_id)

    positive_sequences = Enum.map(events, & &1.goal_seq)
    assert positive_sequences == Enum.to_list(1..length(positive_sequences))

    command = Enum.find(events, &(&1.payload.type == "command_received" and &1.scope.root?))
    assert command.category == :command
    assert command.correlation_id == command.payload.data["command_id"]
    assert command.causation_id == nil

    turn_started = Enum.find(events, &(&1.payload.type == "turn_started" and &1.scope.root?))
    assert turn_started.correlation_id == command.correlation_id
    assert turn_started.causation_id == command.event_id

    parent_tool =
      Enum.find(events, fn event ->
        event.payload.type == "tool_called" and event.payload.data["name"] == "spawn_subagent"
      end)

    child_started =
      Enum.find(events, &(&1.payload.type == "session_started" and not &1.scope.root?))

    assert child_started.correlation_id == command.correlation_id
    assert child_started.causation_id == parent_tool.event_id
  end

  test "a cursor atomically replays missed events before continuing live", context do
    {:ok, session_id} = BeamAgent.start_session(data_dir: context.data_dir, provider: :echo)

    assert {:ok, %{events: startup, cursor: startup_cursor}} =
             BeamAgent.subscribe_goal_from(session_id, nil)

    assert startup != []
    assert startup_cursor == List.last(startup).goal_seq
    assert :ok = BeamAgent.unsubscribe_goal(session_id)

    assert {:ok, "echo(1): while disconnected"} = BeamAgent.ask(session_id, "while disconnected")

    assert eventually(fn ->
             case BeamAgent.goal_events(session_id, after: startup_cursor) do
               {:ok, events} -> Enum.any?(events, &(&1.payload.type == "turn_finished"))
               _other -> false
             end
           end)

    assert {:ok, %{events: replay, cursor: replay_cursor}} =
             BeamAgent.subscribe_goal_from(session_id, startup_cursor)

    assert Enum.all?(replay, &(&1.goal_seq > startup_cursor))
    assert Enum.any?(replay, &(&1.payload.type == "command_received"))
    assert Enum.any?(replay, &(&1.payload.type == "assistant_message"))
    assert replay_cursor == List.last(replay).goal_seq

    assert {:ok, "echo(2): live again"} = BeamAgent.ask(session_id, "live again")

    assert_receive {:beam_agent_runtime_event,
                    %{
                      goal_seq: live_sequence,
                      payload: %{type: "command_received"}
                    }}

    assert live_sequence > replay_cursor
  end

  test "a stream hub restart fails an interrupted durable response and rebuilds downstream",
       context do
    {:ok, session_id} = BeamAgent.start_session(data_dir: context.data_dir, provider: :echo)
    {:ok, old_hub} = BeamAgent.stream_hub_pid(session_id)
    {:ok, old_agent} = BeamAgent.agent_pid(session_id)
    assert {:ok, response_id} = StreamHub.begin_response(session_id, %{"turn" => 1, "step" => 1})

    Process.exit(old_hub, :kill)

    assert eventually(fn ->
             match?({:ok, pid} when pid != old_hub, BeamAgent.stream_hub_pid(session_id))
           end)

    assert eventually(fn ->
             match?({:ok, pid} when pid != old_agent, BeamAgent.agent_pid(session_id))
           end)

    assert eventually(fn ->
             {:ok, events} = BeamAgent.events(session_id)

             Enum.any?(events, fn event ->
               event["type"] == "model_response_failed" and
                 event["data"]["response_id"] == response_id and
                 event["data"]["error"] == "stream_hub_restarted"
             end)
           end)
  end

  test "cancelling a turn closes the response owned by its supervised worker", context do
    {:ok, session_id} =
      BeamAgent.start_session(data_dir: context.data_dir, provider: :streaming_runtime_test)

    :ok = BeamAgent.subscribe(session_id)
    caller = Task.async(fn -> BeamAgent.ask(session_id, "wait", 5_000) end)

    assert_receive {:beam_agent_stream, %{type: :text_delta, delta: "started"}}, 500
    assert :ok = BeamAgent.cancel(session_id)
    assert {:error, :cancelled} = Task.await(caller)

    assert eventually(fn ->
             {:ok, events} = BeamAgent.events(session_id)

             Enum.any?(events, fn event ->
               event["type"] == "model_response_failed" and
                 event["data"]["error"] == "response_owner_down"
             end)
           end)
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
