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

    assert_receive {:live_event, %{type: :text_delta, delta: "live "}}
    assert_receive {:live_event, %{type: :text_delta, delta: "answer"}}
    assert_receive {:live_event, %{type: :usage, usage: %{"output_tokens" => 2}}}
    assert_receive {:live_event, %{type: :response_finished}}

    {:ok, events} = BeamAgent.events(session_id)
    types = Enum.map(events, & &1["type"])
    assert "model_response_started" in types
    assert "model_response_checkpoint" in types
    assert "model_response_finished" in types
    assert "assistant_message" in types

    checkpoint = Enum.find(events, &(&1["type"] == "model_response_checkpoint"))

    assert Enum.map(checkpoint["data"]["events"], & &1["type"]) == [
             "text_delta",
             "text_delta",
             "usage"
           ]
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

    assert_receive {:beam_agent_stream, %{type: :text_delta, delta: "started"}}
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
