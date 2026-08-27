defmodule BeamAgent.RuntimeClientTest do
  use ExUnit.Case, async: false

  alias BeamAgent.Runtime

  defmodule BlockingProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :runtime_client_blocking_test

    @impl true
    def complete(_messages, _tools, options) do
      send(options[:test_pid], :blocking_provider_started)
      Process.sleep(:infinity)
    end
  end

  setup_all do
    :ok = BeamAgent.CapabilityCatalog.register_provider(BlockingProvider)
    :ok
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-runtime-client-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)

    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: data_dir,
        workspace_root: workspace,
        provider: :echo,
        approval_handler: self()
      )

    on_exit(fn -> File.rm_rf(root) end)
    %{data_dir: data_dir, session_id: session_id, workspace: workspace}
  end

  test "a client bootstraps atomically and drives a turn through runtime messages", context do
    assert {:ok, runtime} = Runtime.connect(context.session_id, view: :internal)
    on_exit(fn -> Runtime.disconnect(runtime) end)

    assert {:ok, bootstrap} = Runtime.bootstrap(runtime)
    assert bootstrap.session_id == context.session_id
    assert bootstrap.goal_id == context.session_id
    assert bootstrap.cursor > 0
    assert bootstrap.events != []
    assert Enum.all?(bootstrap.events, &(&1.goal_seq <= bootstrap.cursor))

    assert :ok = Runtime.submit(runtime, "hello")
    assert_receive {:beam_agent_runtime, ^runtime, {:turn_started, "hello"}}

    messages = collect_until_finished(runtime, [])

    assert Enum.any?(messages, fn
             {:event,
              %{
                durability: :durable,
                payload: %{
                  type: "assistant_message",
                  data: %{"content" => "echo(1): hello"}
                }
              }} ->
               true

             _message ->
               false
           end)

    assert List.last(messages) == {:turn_finished, {:ok, "echo(1): hello"}}
    assert {:ok, snapshot} = Runtime.snapshot(runtime)
    assert snapshot.cursor > bootstrap.cursor
    refute snapshot.running?
  end

  test "a disconnected client resumes from its last durable cursor", context do
    assert {:ok, first} = Runtime.connect(context.session_id, view: :internal)
    assert {:ok, initial} = Runtime.bootstrap(first)
    Runtime.disconnect(first)

    assert {:ok, "echo(1): while disconnected"} =
             BeamAgent.ask(context.session_id, "while disconnected")

    assert {:ok, second} =
             Runtime.connect(context.session_id, view: :internal, after: initial.cursor)

    on_exit(fn -> Runtime.disconnect(second) end)
    assert {:ok, replay} = Runtime.bootstrap(second)

    assert replay.cursor > initial.cursor
    assert replay.events != []
    assert Enum.all?(replay.events, &(&1.goal_seq > initial.cursor))

    assert Enum.any?(replay.events, fn event ->
             event.payload.type == "user_message" and
               event.payload.data["content"] == "while disconnected"
           end)

    assert Enum.any?(replay.events, fn event ->
             event.payload.type == "assistant_message" and
               event.payload.data["content"] == "echo(1): while disconnected"
           end)
  end

  test "public clients receive fail-closed replay by default", context do
    assert {:ok, "echo(1): private prompt"} = BeamAgent.ask(context.session_id, "private prompt")
    assert {:ok, runtime} = Runtime.connect(context.session_id)
    on_exit(fn -> Runtime.disconnect(runtime) end)

    assert {:ok, bootstrap} = Runtime.bootstrap(runtime)
    user_message = Enum.find(bootstrap.events, &(&1.payload.type == "user_message"))

    refute user_message.payload.data["content"] == "private prompt"
    assert user_message.redacted?
    assert user_message.payload.data["content"]["kind"] == "text"
  end

  test "a connected client can rebind to a new goal", context do
    assert {:ok, runtime} = Runtime.connect(context.session_id, view: :internal, after: :latest)
    on_exit(fn -> Runtime.disconnect(runtime) end)

    assert {:ok, second_session} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    assert {:ok, rebound} = Runtime.reconnect(runtime, second_session, view: :internal)
    assert rebound.session_id == second_session
    assert rebound.goal_id == second_session
    assert rebound.events != []

    assert {:ok, "echo(1): rebound", _meta} =
             Runtime.run(runtime, "rebound", 5_000, fn _request -> :deny end)
  end

  test "a temporary client restores the previously attached approval handler", context do
    owner = self()
    assert {:ok, ^owner} = BeamAgent.approval_handler(context.session_id)
    assert {:ok, runtime} = Runtime.connect(context.session_id, after: :latest)
    assert {:ok, ^runtime} = BeamAgent.approval_handler(context.session_id)

    Runtime.disconnect(runtime)
    assert {:ok, ^owner} = BeamAgent.approval_handler(context.session_id)
  end

  test "a replacement client can observe and cancel detached runtime work", context do
    assert {:ok, session_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :runtime_client_blocking_test,
               provider_options: [test_pid: self()]
             )

    assert {:ok, first} = Runtime.connect(session_id, view: :internal, after: :latest)
    assert :ok = Runtime.submit(first, "wait")
    assert_receive :blocking_provider_started
    assert {:ok, %{running?: true, cursor: cursor}} = Runtime.snapshot(first)
    Runtime.disconnect(first)

    assert {:ok, replacement} =
             Runtime.connect(session_id, view: :internal, after: cursor)

    on_exit(fn -> Runtime.disconnect(replacement) end)
    assert {:ok, %{running?: true}} = Runtime.bootstrap(replacement)
    assert :ok = Runtime.cancel(replacement)
    assert_receive {:beam_agent_runtime, ^replacement, :turn_cancelling}
    assert eventually(fn -> match?({:ok, %{running?: false}}, Runtime.snapshot(replacement)) end)
  end

  defp collect_until_finished(runtime, messages) do
    receive do
      {:beam_agent_runtime, ^runtime, {:turn_finished, _result} = message} ->
        Enum.reverse([message | messages])

      {:beam_agent_runtime, ^runtime, message} ->
        collect_until_finished(runtime, [message | messages])
    after
      2_000 -> flunk("timed out waiting for the runtime turn")
    end
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
