defmodule BeamAgent.OTPRoadmapItemsTest do
  use ExUnit.Case, async: false

  alias BeamAgent.{CapabilityEnvelope, MCP.Registry, OutcomeStore, Session.ToolPolicy}

  defmodule RemoteProvider do
    @behaviour BeamAgent.LLMProvider
    def id, do: :roadmap_remote

    def configuration,
      do: %{
        name: "roadmap_remote",
        label: "Roadmap remote",
        capabilities: [:text_generation, :tool_use, :reasoning],
        locality: :remote,
        privacy: :provider,
        cost_hint: :metered
      }

    def complete(messages, _tools, options) do
      cond do
        options[:parent_session_id] ->
          {:ok, %{content: "remote child", tool_calls: []}}

        Enum.any?(messages, &(&1.role == :tool and &1.name == "spawn_subagent")) ->
          {:ok, %{content: "parent received local child", tool_calls: []}}

        true ->
          {:ok,
           %{
             content: nil,
             tool_calls: [
               %{
                 id: "spawn-local-child",
                 name: "spawn_subagent",
                 arguments: %{"prompt" => "Please calculate two plus two for me"}
               }
             ]
           }}
      end
    end
  end

  defmodule LocalProvider do
    @behaviour BeamAgent.LLMProvider
    def id, do: :roadmap_local

    def configuration,
      do: %{
        name: "roadmap_local",
        label: "Roadmap local",
        capabilities: [:text_generation, :tool_use],
        locality: :local,
        privacy: :local,
        cost_hint: :free
      }

    def complete(_messages, _tools, _options), do: {:ok, %{content: "local", tool_calls: []}}
  end

  defmodule CustomRouter do
    def route(_input, candidates), do: Enum.find(candidates, &(&1.id == "remote"))
  end

  setup_all do
    :ok = BeamAgent.CapabilityCatalog.register_provider(RemoteProvider)
    :ok = BeamAgent.CapabilityCatalog.register_provider(LocalProvider)
    :ok
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "beam-agent-roadmap-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "data")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, workspace: workspace, data_dir: data_dir}
  end

  test "capability delegation can only preserve or reduce authority" do
    parent = CapabilityEnvelope.root(%{tools: ["read_file"], paths: ["lib"]})

    assert {:error, {:capability_escalation, :tools, _requested}} =
             CapabilityEnvelope.restrict(parent, %{tools: ["read_file", "run_command"]})

    assert {:ok, child} =
             CapabilityEnvelope.restrict(parent, %{tools: ["read_file"], paths: ["lib/sub"]})

    assert :ok =
             CapabilityEnvelope.authorize(child, %{
               tools: "read_file",
               paths: "lib/sub/a.ex"
             })

    assert {:error, {:capability_denied, :tools, "run_command"}} =
             CapabilityEnvelope.authorize(child, %{tools: "run_command"})

    assert {:error, {:capability_denied, :paths, "test/a.exs"}} =
             CapabilityEnvelope.authorize(child, %{paths: "test/a.exs"})
  end

  test "allow always is durable, inspectable, and revocable", context do
    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :echo,
        approval_policy: :ask,
        approval_handler: self()
      )

    resource = %{tools: "run_command", commands: "mix"}

    task =
      Task.async(fn ->
        ToolPolicy.authorize(
          session_id,
          "run_command",
          %{"command" => "mix test"},
          :execute,
          resource
        )
      end)

    assert_receive {:beam_agent_approval, request}
    assert :ok = BeamAgent.respond_approval(session_id, request.approval_id, :allow_always)
    assert :ok = Task.await(task)
    assert {:ok, [permission]} = BeamAgent.permissions(session_id)

    assert :ok = BeamAgent.stop_session(session_id)

    assert {:ok, ^session_id} =
             BeamAgent.resume_session(session_id,
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               approval_policy: :ask,
               approval_handler: self()
             )

    assert {:ok, [^permission]} = BeamAgent.permissions(session_id)

    assert :ok =
             ToolPolicy.authorize(
               session_id,
               "run_command",
               %{"command" => "mix test"},
               :execute,
               resource
             )

    assert :ok = BeamAgent.revoke_permission(session_id, permission["id"])

    task =
      Task.async(fn ->
        ToolPolicy.authorize(
          session_id,
          "run_command",
          %{"command" => "mix test"},
          :execute,
          resource
        )
      end)

    assert_receive {:beam_agent_approval, request}
    assert :ok = BeamAgent.respond_approval(session_id, request.approval_id, :deny)
    assert {:error, {:tool_denied, "run_command"}} = Task.await(task)
  end

  test "a goal supervises local MCP discovery and namespaced calls", context do
    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :echo,
        approval_policy: :auto
      )

    fixture = Path.expand("../priv/test_fixtures/mcp_server.ex", __DIR__)

    assert {:ok, %{name: "fixture", tool_count: 1}} =
             BeamAgent.start_mcp_server(session_id, %{
               name: "fixture",
               command: "elixir",
               args: [fixture],
               cwd: context.workspace
             })

    assert [%{name: "mcp__fixture__ping"}] = BeamAgent.mcp_tools(session_id)
    {:ok, goal} = BeamAgent.goal(session_id)

    tool_context = %{
      session_id: session_id,
      goal_id: session_id,
      capability_envelope: goal.capability_envelope
    }

    assert {:ok, result} = Registry.execute(session_id, "mcp__fixture__ping", %{}, tool_context)
    assert result =~ "pong"

    {_pid, monitor} =
      spawn_monitor(fn ->
        Registry.execute(session_id, "mcp__fixture__ping", %{"crash" => true}, tool_context)
      end)

    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 2_000

    assert eventually(fn ->
             BeamAgent.mcp_tools(session_id) == [
               %{
                 name: "mcp__fixture__ping",
                 description: "Return pong",
                 input_schema: %{"type" => "object"}
               }
             ]
           end)

    assert eventually(fn ->
             {:ok, events} = BeamAgent.events(session_id)
             Enum.any?(events, &(&1["type"] == "mcp_server_restarted"))
           end)

    slow =
      Task.async(fn ->
        Registry.execute(session_id, "mcp__fixture__ping", %{"slow" => true}, tool_context)
      end)

    Process.sleep(50)
    Task.shutdown(slow, :brutal_kill)

    assert eventually(fn ->
             {:ok, events} = BeamAgent.events(session_id)
             Enum.any?(events, &(&1["type"] == "mcp_call_cancelled"))
           end)

    assert :ok = BeamAgent.stop_mcp_server(session_id, "fixture")
    {:ok, events} = BeamAgent.events(session_id)
    assert Enum.any?(events, &(&1["type"] == "mcp_server_started"))
    assert Enum.any?(events, &(&1["type"] == "mcp_server_stopped"))
  end

  test "Auto routes simple prose to a local free endpoint and records the decision", context do
    endpoints = [
      %{id: "remote", provider: :roadmap_remote, provider_module: RemoteProvider},
      %{id: "local", provider: :roadmap_local, provider_module: LocalProvider}
    ]

    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :roadmap_remote,
        provider_profile: "remote",
        model_strategy: :auto,
        model_endpoints: endpoints
      )

    assert {:ok, "local"} = BeamAgent.ask(session_id, "Please calculate two plus two for me")
    {:ok, events} = BeamAgent.events(session_id)
    route = Enum.find(events, &(&1["type"] == "model_route_selected"))
    assert route["data"]["selected_endpoint_id"] == "local"
    assert route["data"]["candidate_endpoint_ids"] == ["local", "remote"]
    assert Enum.any?(route["data"]["candidates"], &(&1["locality"] == "local"))
    assert route["data"]["evidence"]["mode"] == "shadow"
    assert route["data"]["evidence"]["state"] == "insufficient_evidence"
    assert route["data"]["evidence"]["recommended_endpoint_id"] == nil
  end

  test "one goal can route its parent and child requests to different providers", context do
    endpoints = [
      %{id: "remote", provider: :roadmap_remote, provider_module: RemoteProvider},
      %{id: "local", provider: :roadmap_local, provider_module: LocalProvider}
    ]

    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :roadmap_remote,
        provider_profile: "remote",
        model_strategy: :auto,
        model_endpoints: endpoints
      )

    assert {:ok, "parent received local child"} =
             BeamAgent.ask(session_id, "Use a subagent to calculate two plus two")

    {:ok, parent_events} = BeamAgent.events(session_id)
    spawned = Enum.find(parent_events, &(&1["type"] == "subagent_spawned"))
    child_id = spawned["data"]["child_session_id"]
    {:ok, child_events} = BeamAgent.events(child_id)
    child_route = Enum.find(child_events, &(&1["type"] == "model_route_selected"))
    assert child_route["data"]["selected_endpoint_id"] == "local"
    assert {:error, :not_found} = BeamAgent.agent_pid(child_id)
  end

  test "local-only and custom routing overrides are explicit", context do
    endpoints = [
      %{id: "remote", provider: :roadmap_remote, provider_module: RemoteProvider},
      %{id: "local", provider: :roadmap_local, provider_module: LocalProvider}
    ]

    {:ok, project_id} =
      BeamAgent.start_project(
        workspace_root: context.workspace,
        data_dir: context.data_dir,
        model_endpoints: endpoints
      )

    input = %{
      prompt: "summarize this repository",
      workspace_root: context.workspace,
      preferred_endpoint_id: "remote",
      preferred_provider: :roadmap_remote,
      tools: [],
      capability_envelope: CapabilityEnvelope.root()
    }

    assert {:ok, %{selected_endpoint_id: "local"}} =
             BeamAgent.route_model(project_id, Map.put(input, :strategy, :local_only))

    assert {:ok, %{selected_endpoint_id: "remote"}} =
             BeamAgent.route_model(
               project_id,
               Map.put(input, :strategy, {:custom, CustomRouter})
             )
  end

  test "Auto can choose deterministic computation without a model", context do
    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :roadmap_remote,
        provider_profile: "remote",
        model_strategy: :auto,
        model_endpoints: [
          %{id: "remote", provider: :roadmap_remote, provider_module: RemoteProvider}
        ]
      )

    assert {:ok, "4"} = BeamAgent.ask(session_id, "2 + 2")
    {:ok, events} = BeamAgent.events(session_id)
    route = Enum.find(events, &(&1["type"] == "model_route_selected"))
    assert route["data"]["selected_endpoint_id"] == nil
  end

  test "verified outcome evidence produces a shadow recommendation without changing Auto",
       context do
    endpoints = [
      %{id: "remote", provider: :roadmap_remote, provider_module: RemoteProvider},
      %{id: "local", provider: :roadmap_local, provider_module: LocalProvider}
    ]

    {:ok, project_id} =
      BeamAgent.start_project(
        workspace_root: context.workspace,
        data_dir: context.data_dir,
        model_endpoints: endpoints
      )

    Enum.each(1..5, fn sample ->
      assert {:ok, _} =
               OutcomeStore.record(project_id, %{
                 kind: :model,
                 session_id: "session-remote-#{sample}",
                 turn: 1,
                 task_type: :simple,
                 language: :elixir,
                 endpoint_id: "remote",
                 provider: :roadmap_remote,
                 latency_ms: 500,
                 status: :succeeded,
                 verification: %{status: :passed}
               })

      assert {:ok, _} =
               OutcomeStore.record(project_id, %{
                 kind: :model,
                 session_id: "session-local-#{sample}",
                 turn: 1,
                 task_type: :simple,
                 language: :elixir,
                 endpoint_id: "local",
                 provider: :roadmap_local,
                 latency_ms: 50,
                 status: :succeeded,
                 verification: %{status: :failed}
               })
    end)

    input = %{
      prompt: "Give me a short Elixir greeting",
      workspace_root: context.workspace,
      preferred_endpoint_id: "remote",
      preferred_provider: :roadmap_remote,
      strategy: :auto,
      tools: [],
      capability_envelope: CapabilityEnvelope.root()
    }

    assert {:ok, route} = BeamAgent.route_model(project_id, input)
    assert route.selected_endpoint_id == "local"
    assert route.evidence.state == "ready"
    assert route.evidence.recommended_endpoint_id == "remote"
    assert route.evidence.mode == "shadow"
  end

  test "confidence-gated routing can use verified evidence with exploration disabled", context do
    endpoints = [
      %{id: "remote", provider: :roadmap_remote, provider_module: RemoteProvider},
      %{id: "local", provider: :roadmap_local, provider_module: LocalProvider}
    ]

    {:ok, project_id} =
      BeamAgent.start_project(
        workspace_root: context.workspace,
        data_dir: context.data_dir,
        model_endpoints: endpoints,
        routing_evidence_mode: :enabled,
        routing_exploration_percent: 0
      )

    Enum.each(1..5, fn sample ->
      for {endpoint, verification} <- [{"remote", :passed}, {"local", :failed}] do
        assert {:ok, _} =
                 OutcomeStore.record(project_id, %{
                   kind: :model,
                   session_id: "session-#{endpoint}-#{sample}",
                   turn: 1,
                   task_type: :simple,
                   language: :elixir,
                   endpoint_id: endpoint,
                   provider: :roadmap_remote,
                   latency_ms: 100,
                   status: :succeeded,
                   verification: %{status: verification}
                 })
      end
    end)

    input = %{
      prompt: "Give me a short Elixir greeting",
      workspace_root: context.workspace,
      preferred_endpoint_id: "local",
      preferred_provider: :roadmap_local,
      strategy: :auto,
      tools: [],
      capability_envelope: CapabilityEnvelope.root()
    }

    assert {:ok, route} = BeamAgent.route_model(project_id, input)
    assert route.selected_endpoint_id == "remote"
    assert route.reason == "confidence-gated recommendation from recent verified outcomes"
    assert route.evidence.mode == "enabled"
    assert route.evidence.selection == "verified_evidence"
  end

  test "outcomes are redacted, exportable, and accept later verification", context do
    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :echo
      )

    assert {:ok, _answer} =
             BeamAgent.ask(session_id, "private prompt that must not enter outcomes")

    {:ok, goal} = BeamAgent.goal(session_id)
    assert {:ok, outcomes} = BeamAgent.outcomes(goal.project_id)
    model = Enum.find(outcomes, &(&1.kind == "model"))
    task = Enum.find(outcomes, &(&1.kind == "task"))
    assert model.latency_ms >= 0
    assert model.version == 1
    assert model.redaction == "content_excluded_v1"
    assert model.verification == %{"status" => "unverified"}

    {:ok, events} = BeamAgent.events(session_id)
    task_event = Enum.find(events, &(&1["type"] == "task_outcome_recorded"))
    assert task_event["data"]["verification"] == %{"status" => "unverified"}

    assert :ok =
             BeamAgent.attach_verification(goal.project_id, task.id, %{
               status: :passed,
               source: "mix test"
             })

    {:ok, events} = BeamAgent.events(session_id)
    verification_event = Enum.find(events, &(&1["type"] == "verification_attached"))
    assert verification_event["data"]["outcome_id"] == task.id
    assert verification_event["data"]["verification"]["status"] == "passed"

    assert {:ok, export} = BeamAgent.export_outcomes(goal.project_id)
    refute export =~ "private prompt"
    assert export =~ "mix test"

    assert :ok = BeamAgent.stop_project(goal.project_id)
    project_id = goal.project_id

    assert {:ok, ^project_id} =
             BeamAgent.start_project(
               workspace_root: context.workspace,
               data_dir: context.data_dir
             )

    assert {:ok, persisted} = BeamAgent.outcomes(goal.project_id)

    assert Enum.any?(
             persisted,
             &(&1.id == task.id and &1.verification["status"] == "passed")
           )
  end

  test "outcome capture can be disabled", context do
    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :echo,
        outcome_telemetry: false
      )

    assert {:ok, _} = BeamAgent.ask(session_id, "hello")
    {:ok, goal} = BeamAgent.goal(session_id)
    assert {:ok, []} = BeamAgent.outcomes(goal.project_id)
  end

  defp eventually(fun, attempts \\ 30)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
