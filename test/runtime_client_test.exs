defmodule BeamAgent.RuntimeClientTest do
  use ExUnit.Case, async: false

  alias BeamAgent.Runtime
  alias BeamAgent.Session.ToolPolicy

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )

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

  test "runtime submit resolves workspace file references into model context", context do
    File.write!(Path.join(context.workspace, "README.md"), "workspace hello\n")

    assert {:ok, runtime} = Runtime.connect(context.session_id, view: :internal)
    on_exit(fn -> Runtime.disconnect(runtime) end)

    assert :ok = Runtime.submit(runtime, "summarize @README.md")
    assert_receive {:beam_agent_runtime, ^runtime, {:turn_started, "summarize @README.md"}}

    messages = collect_until_finished(runtime, [])
    assert {:turn_finished, {:ok, answer}} = List.last(messages)
    assert answer =~ "<workspace_file_references untrusted=\"true\">"
    assert answer =~ ~s(path="README.md")
    assert answer =~ "workspace hello"

    assert {:ok, events} = BeamAgent.events(context.session_id)

    user_event =
      events
      |> Enum.reverse()
      |> Enum.find(&(&1["type"] == "user_message"))

    assert user_event["data"]["content"] == "summarize @README.md"
    assert get_in(user_event, ["data", "file_references", Access.at(0), "path"]) == "README.md"
    refute Map.has_key?(get_in(user_event, ["data", "file_references", Access.at(0)]), "content")

    assert {:ok, public_events} = BeamAgent.goal_events(context.session_id)

    public_command =
      Enum.find(public_events, &(to_string(&1.payload.type) == "command_received"))

    public_reference = get_in(public_command.payload.data, ["file_references", Access.at(0)])
    assert public_reference["path"] == "README.md"
    refute Map.has_key?(public_reference, "content")
    refute Map.has_key?(public_reference, "snapshot_path")
    refute Map.has_key?(public_reference, "source_path")
  end

  test "clients import, submit, replay, and remove attachments through the runtime contract",
       context do
    :ok = BeamAgent.stop_session(context.session_id)

    assert {:ok, resumed_id} =
             BeamAgent.resume_session(context.session_id,
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               provider_profile: "vision",
               model_strategy: :manual,
               model_endpoints: [
                 %{
                   id: "vision",
                   provider: :echo,
                   provider_module: BeamAgent.Providers.Echo,
                   claims: %{modalities: [:text, :image]}
                 }
               ]
             )

    assert resumed_id == context.session_id

    assert {:ok, runtime} = Runtime.connect(context.session_id, view: :internal)
    on_exit(fn -> Runtime.disconnect(runtime) end)

    assert {:ok, attachment} =
             Runtime.import_attachment(runtime, %{
               content: @png,
               name: "pasted-image.png",
               provenance: "clipboard"
             })

    assert {:ok, [listed]} = Runtime.attachments(runtime)
    assert listed.id == attachment.id
    assert {:ok, [draft]} = Runtime.draft_attachments(runtime)
    assert draft.id == attachment.id
    assert {:ok, %{attachments: [snapshot_draft]}} = Runtime.snapshot(runtime)
    assert snapshot_draft.id == attachment.id

    assert :ok = Runtime.submit(runtime, "", [attachment.id])
    assert_receive {:beam_agent_runtime, ^runtime, {:turn_started, ""}}
    assert {:turn_finished, {:ok, _answer}} = List.last(collect_until_finished(runtime, []))

    assert {:ok, events} = BeamAgent.events(context.session_id)

    user_event =
      events
      |> Enum.reverse()
      |> Enum.find(&(&1["type"] == "user_message"))

    assert get_in(user_event, ["data", "attachments", Access.at(0), "id"]) == attachment.id
    refute Map.has_key?(get_in(user_event, ["data", "attachments", Access.at(0)]), "data")
    assert {:ok, []} = Runtime.draft_attachments(runtime)
    assert {:error, :attachment_in_use} = Runtime.delete_attachment(runtime, attachment.id)
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

  test "public goal tree survives event-hub replay and client reconnect", context do
    assert {:ok, "echo(1): tree replay"} = BeamAgent.ask(context.session_id, "tree replay")

    assert {:ok, first} = Runtime.connect(context.session_id)
    assert {:ok, live_tree} = Runtime.goal_tree(first)
    assert live_tree.root.state == :completed
    Runtime.disconnect(first)

    assert {:ok, old_hub} = BeamAgent.goal_event_hub_pid(context.session_id)
    Process.exit(old_hub, :kill)

    assert eventually(fn ->
             case BeamAgent.goal_event_hub_pid(context.session_id) do
               {:ok, new_hub} -> new_hub != old_hub
               _other -> false
             end
           end)

    assert eventually(fn ->
             match?({:ok, %{root: %{state: :completed}}}, BeamAgent.goal_tree(context.session_id))
           end)

    assert eventually(fn -> match?({:ok, _agent}, BeamAgent.agent_pid(context.session_id)) end)

    assert {:ok, reconnected} = Runtime.connect(context.session_id)
    on_exit(fn -> Runtime.disconnect(reconnected) end)
    assert {:ok, replayed_tree} = Runtime.goal_tree(reconnected)
    assert replayed_tree.root.restart_count == live_tree.root.restart_count + 1

    normalized_replay =
      replayed_tree
      |> put_in([:root, :restart_count], live_tree.root.restart_count)
      |> put_in(
        [:nodes, context.session_id, :restart_count],
        live_tree.nodes[context.session_id].restart_count
      )

    assert normalized_replay == live_tree
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

  test "versioned JSON protocol exposes the same runtime without owning state", context do
    assert {:ok, runtime} = Runtime.connect(context.session_id)
    on_exit(fn -> Runtime.disconnect(runtime) end)

    response =
      BeamAgent.Runtime.JSONProtocol.dispatch(runtime, %{
        "version" => 1,
        "request_id" => "request-1",
        "command" => "goal_tree",
        "arguments" => %{}
      })

    assert response.ok
    assert response.request_id == "request-1"
    assert response.result.root.session_id == context.session_id
    assert JSON.decode!(BeamAgent.Runtime.JSONProtocol.encode_response(response))["ok"] == true

    unsupported =
      BeamAgent.Runtime.JSONProtocol.dispatch(runtime, %{
        version: 99,
        request_id: "request-2",
        command: "status"
      })

    refute unsupported.ok
    assert unsupported.error == "unsupported_protocol_version"
    encoded = BeamAgent.Runtime.JSONProtocol.encode_response(unsupported) |> JSON.decode!()
    assert encoded["ok"] == false

    assert BeamAgent.Runtime.JSONProtocol.normalize(%{missing: nil, nested: [false, true]}) ==
             %{"missing" => nil, "nested" => [false, true]}
  end

  test "a temporary client restores the previously attached approval handler", context do
    owner = self()
    assert {:ok, ^owner} = BeamAgent.approval_handler(context.session_id)
    assert {:ok, runtime} = Runtime.connect(context.session_id, after: :latest)
    assert {:ok, ^runtime} = BeamAgent.approval_handler(context.session_id)

    Runtime.disconnect(runtime)
    assert {:ok, ^owner} = BeamAgent.approval_handler(context.session_id)
  end

  test "a client recovers and resolves an approval pending in a nested worker", context do
    owner = self()

    assert {:ok, child_id} =
             BeamAgent.spawn_subagent(context.session_id,
               agent_proposal: %{goal: "Investigate a nested approval"}
             )

    approval_task =
      Task.async(fn ->
        ToolPolicy.authorize(
          child_id,
          "create_file",
          %{"path" => "nested.txt"},
          :write,
          %{tools: "create_file"}
        )
      end)

    assert_receive {:beam_agent_approval, %{session_id: ^child_id} = initial_request}

    assert {:ok, runtime} = Runtime.connect(context.session_id, after: :latest)
    on_exit(fn -> Runtime.disconnect(runtime) end)

    assert {:ok, bootstrap} = Runtime.bootstrap(runtime)

    assert [%{approval_id: approval_id, session_id: ^child_id}] =
             Enum.filter(
               bootstrap.pending_approvals,
               &(&1.approval_id == initial_request.approval_id)
             )

    assert :ok = Runtime.respond_approval(runtime, approval_id, :allow_once)
    assert :ok = Task.await(approval_task, 1_000)

    Runtime.disconnect(runtime)
    assert {:ok, ^owner} = BeamAgent.approval_handler(context.session_id)
    assert {:ok, ^owner} = BeamAgent.approval_handler(child_id)
  end

  test "a capability escalation followed by a distinct child write approval is delivered",
       context do
    assert {:ok, child_id} =
             BeamAgent.spawn_subagent(context.session_id,
               agent_proposal: %{goal: "Request narrow write authority, then create one file"}
             )

    assert {:ok, runtime} = Runtime.connect(context.session_id, after: :latest)
    on_exit(fn -> Runtime.disconnect(runtime) end)
    assert {:ok, _bootstrap} = Runtime.bootstrap(runtime)

    escalation_task =
      Task.async(fn ->
        BeamAgent.request_capability(child_id, %{
          purpose: "Create one generated file",
          capabilities: %{tools: ["create_file"], paths: ["lib"]},
          duration_ms: 60_000,
          operations: 1,
          fallback: "report blocked"
        })
      end)

    assert_receive {:beam_agent_runtime, ^runtime,
                    {:approval_requested,
                     %{
                       approval_id: escalation_id,
                       session_id: root_id,
                       tool: "capability_escalation"
                     }}},
                   1_000

    assert root_id == context.session_id
    assert :ok = Runtime.respond_approval(runtime, escalation_id, :allow_once)
    assert {:ok, _lease} = Task.await(escalation_task, 1_000)

    assert {:ok, tool_context} = BeamAgent.Agent.construction_context(child_id)

    write_task =
      Task.async(fn ->
        BeamAgent.ToolRunner.execute(
          BeamAgent.Tools.CreateFile,
          %{"path" => "lib/generated.ex", "content" => "defmodule Generated do\nend\n"},
          tool_context
        )
      end)

    assert_receive {:beam_agent_runtime, ^runtime,
                    {:approval_requested,
                     %{
                       approval_id: write_id,
                       session_id: ^child_id,
                       tool: "create_file"
                     }}},
                   1_000

    refute write_id == escalation_id
    assert {:ok, snapshot} = Runtime.snapshot(runtime)
    assert Enum.any?(snapshot.pending_approvals, &(&1.approval_id == write_id))

    assert :ok = Runtime.respond_approval(runtime, write_id, :allow_once)
    assert {:ok, _result} = Task.await(write_task, 1_000)

    assert File.read!(Path.join(context.workspace, "lib/generated.ex")) ==
             "defmodule Generated do\nend\n"

    assert_receive {:beam_agent_runtime, ^runtime, {:approval_resolved, ^write_id, :allow_once}}

    assert_receive {:beam_agent_runtime, ^runtime, {:approvals_reconciled, []}}
    assert {:ok, %{pending_approvals: []}} = Runtime.snapshot(runtime)
  end

  test "a pending nested decision survives client disconnect and is denied after reconnect",
       context do
    assert {:ok, child_id} =
             BeamAgent.spawn_subagent(context.session_id,
               agent_proposal: %{goal: "Wait for a reconnecting approval client"}
             )

    assert {:ok, first} = Runtime.connect(context.session_id, after: :latest)

    authorization =
      Task.async(fn ->
        ToolPolicy.authorize(
          child_id,
          "create_file",
          %{"path" => "lib/reconnected.ex"},
          :write,
          %{tools: "create_file", paths: "lib/reconnected.ex"}
        )
      end)

    assert_receive {:beam_agent_runtime, ^first,
                    {:approval_requested, %{approval_id: approval_id}}}

    Runtime.disconnect(first)
    assert Task.yield(authorization, 50) == nil

    assert {:ok, replacement} = Runtime.connect(context.session_id, after: :latest)
    on_exit(fn -> Runtime.disconnect(replacement) end)
    assert {:ok, bootstrap} = Runtime.bootstrap(replacement)

    assert Enum.any?(
             bootstrap.pending_approvals,
             &(&1.approval_id == approval_id and &1.session_id == child_id)
           )

    assert :ok = Runtime.respond_approval(replacement, approval_id, :deny)
    assert {:error, {:tool_denied, "create_file"}} = Task.await(authorization, 1_000)
    assert {:ok, %{pending_approvals: []}} = Runtime.snapshot(replacement)
  end

  test "an unknown approval id is rejected and reconciles the authoritative queue", context do
    assert {:ok, runtime} = Runtime.connect(context.session_id, after: :latest)
    on_exit(fn -> Runtime.disconnect(runtime) end)

    assert {:error, :unknown_approval} =
             Runtime.respond_approval(runtime, "approval-stale", :allow_once)

    assert_receive {:beam_agent_runtime, ^runtime, {:approvals_reconciled, []}}
    assert {:ok, %{pending_approvals: []}} = Runtime.snapshot(runtime)
  end

  test "auto approval applies to the whole goal and future nested workers", context do
    assert {:ok, child_id} =
             BeamAgent.spawn_subagent(context.session_id,
               agent_proposal: %{goal: "Investigate goal-wide approval policy"}
             )

    approval_task =
      Task.async(fn ->
        ToolPolicy.authorize(
          child_id,
          "create_file",
          %{"path" => "nested.txt"},
          :write,
          %{tools: "create_file"}
        )
      end)

    assert_receive {:beam_agent_approval, %{session_id: ^child_id}}
    assert {:ok, runtime} = Runtime.connect(context.session_id, after: :latest)
    on_exit(fn -> Runtime.disconnect(runtime) end)
    assert {:ok, %{pending_approvals: [_ | _]}} = Runtime.bootstrap(runtime)

    assert :ok = Runtime.set_approval_policy(runtime, :auto)
    assert :ok = Task.await(approval_task, 1_000)
    assert {:ok, :auto} = BeamAgent.approval_policy(context.session_id)
    assert {:ok, :auto} = BeamAgent.approval_policy(child_id)
    assert {:ok, %{pending_approvals: []}} = Runtime.snapshot(runtime)

    assert {:ok, future_child_id} =
             BeamAgent.spawn_subagent(context.session_id,
               agent_proposal: %{goal: "Inspect future inherited approval policy"}
             )

    assert {:ok, :auto} = BeamAgent.approval_policy(future_child_id)

    Runtime.disconnect(runtime)
    assert {:ok, owner} = BeamAgent.approval_handler(context.session_id)
    assert owner == self()
    assert {:ok, ^owner} = BeamAgent.approval_handler(future_child_id)
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

  test "a client exposes workspace diffs and the session index it is bound to", context do
    workspace = context.workspace

    File.write!(Path.join(workspace, "tracked.txt"), "one\ntwo\n")

    {_out, 0} =
      System.cmd("git", ["init", "--initial-branch=main"], cd: workspace, stderr_to_stdout: true)

    {_out, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    {_out, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: workspace)
    {_out, 0} = System.cmd("git", ["add", "."], cd: workspace)
    {_out, 0} = System.cmd("git", ["commit", "-m", "init"], cd: workspace, stderr_to_stdout: true)
    File.write!(Path.join(workspace, "tracked.txt"), "one\nTWO\n")

    assert {:ok, runtime} = Runtime.connect(context.session_id)
    on_exit(fn -> Runtime.disconnect(runtime) end)

    assert {:ok, summary} = Runtime.diff_summary(runtime)
    assert summary.branch == "main"
    assert summary.changed_file_count == 1
    assert summary.insertions == 1
    assert summary.deletions == 1

    assert {:ok, diff} = Runtime.diff(runtime)
    assert [%{path: "tracked.txt", status: "modified"}] = diff.changed_files
    assert [%{lines: [_context, _remove, _add]}] = diff.files["tracked.txt"].hunks

    assert {:ok, listed} = Runtime.diff(runtime, hunks?: false)
    assert listed.files == %{}

    assert {:ok, [%{session_id: session_id}]} = Runtime.sessions(runtime)
    assert session_id == context.session_id

    assert {:ok, detail} = Runtime.session_detail(runtime, context.session_id)
    assert detail.session_id == context.session_id
    assert detail.provider == "echo"
  end

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
