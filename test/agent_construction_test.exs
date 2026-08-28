defmodule BeamAgent.AgentConstructionTest do
  use ExUnit.Case, async: false

  alias BeamAgent.{AgentConstructor, CapabilityEnvelope}

  defmodule ToolCaptureProvider do
    @behaviour BeamAgent.LLMProvider

    def id, do: :agent_spec_tool_capture

    def complete(_messages, tools, options) do
      send(options[:test_pid], {:visible_tools, Enum.map(tools, & &1.name)})
      {:ok, %{content: "captured", tool_calls: []}}
    end
  end

  setup_all do
    case BeamAgent.CapabilityCatalog.register_provider(ToolCaptureProvider) do
      :ok -> :ok
      {:error, :duplicate_provider} -> :ok
    end

    :ok
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-construction-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace, data_dir: data_dir}
  end

  test "root sessions receive a validated runtime AgentSpec", context do
    assert {:ok, session_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               objective: "Coordinate a repository investigation"
             )

    assert {:ok, spec} = BeamAgent.agent_spec(session_id)
    assert spec.version == 1
    assert spec.goal == "Coordinate a repository investigation"
    assert spec.role == "Goal coordinator"
    assert spec.lifecycle.depth == 0
    assert spec.lifecycle.restart == :temporary
    refute spec.lifecycle.terminate_after_result
    assert spec.lifecycle.retention == :until_goal_shutdown
    assert spec.provenance.goal == "user"
    assert spec.provenance.effective_capabilities == "runtime_policy"

    assert {:ok, context_snapshot} = BeamAgent.context_snapshot(session_id)
    assert context_snapshot.system_prompt =~ "Role: Goal coordinator"
    assert context_snapshot.system_prompt =~ "Goal: Coordinate a repository investigation"

    {:ok, events} = BeamAgent.events(session_id)
    constructed = Enum.find(events, &(&1["type"] == "agent_constructed"))
    applied = Enum.find(events, &(&1["type"] == "agent_spec_applied"))
    assert constructed["data"]["spec_id"] == spec.spec_id
    assert constructed["data"]["goal_fingerprint"]
    assert applied["data"]["role"] == "Goal coordinator"
  end

  test "child construction dynamically populates soft fields and runtime-owned authority",
       context do
    parent_capabilities = %{
      tools: ["spawn_subagent", "read_file", "run_command"],
      paths: :all,
      commands: ["mix", "rg"],
      hosts: [],
      mcp_servers: [],
      model_classes: :all
    }

    assert {:ok, parent_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               capabilities: parent_capabilities
             )

    secret_goal =
      "Debug the private Elixir Ecto error marker-#{System.unique_integer([:positive])}"

    secret_instruction = "Focus only on transaction ordering"

    proposal = %{
      "goal" => secret_goal,
      "instructions" => [secret_instruction],
      "capabilities" => %{
        "tools" => ["read_file"],
        "paths" => ["lib"],
        "commands" => [],
        "hosts" => [],
        "mcp_servers" => [],
        "model_classes" => "all"
      },
      "model_requirements" => %{
        "reasoning" => "high",
        "locality" => "local",
        "privacy" => "local"
      },
      "verification_requirements" => %{"required" => true}
    }

    assert {:ok, child_id} =
             BeamAgent.spawn_subagent(parent_id,
               session_id: "dynamic-specialist",
               agent_proposal: proposal
             )

    assert {:ok, spec} = BeamAgent.agent_spec(child_id)
    assert spec.role == "Elixir debugging specialist"
    assert spec.template == "debugger"
    assert spec.template_version == 1
    assert spec.template_source == :builtin
    assert spec.execution_strategy.id == "investigate"
    assert secret_instruction in spec.instructions
    assert spec.lifecycle.depth == 1
    assert spec.lifecycle.maximum_delegation_depth == 4
    assert spec.restrictions.external_network == :denied
    assert spec.model_requirements.reasoning == :high
    assert spec.model_requirements.locality == :local
    assert spec.model_requirements.privacy == :local
    assert spec.provenance.role == "runtime_inference"
    assert spec.authority_decision.disposition == :attenuated

    assert spec.effective_capabilities.scopes.tools == ["read_file"]
    assert spec.effective_capabilities.scopes.paths == ["lib"]
    refute spec.effective_capabilities.scopes.tools == :all

    assert {:ok, child_context} = BeamAgent.context_snapshot(child_id)
    assert child_context.system_prompt =~ "Role: Elixir debugging specialist"
    assert child_context.system_prompt =~ secret_goal
    assert child_context.system_prompt =~ secret_instruction

    {:ok, parent_events} = BeamAgent.events(parent_id)
    requested = Enum.find(parent_events, &(&1["type"] == "agent_construction_requested"))

    constructed =
      Enum.find(
        parent_events,
        &(&1["type"] == "agent_constructed" and
            &1["data"]["target_session_id"] == child_id)
      )

    spawned = Enum.find(parent_events, &(&1["type"] == "subagent_spawned"))

    refute JSON.encode!(requested) =~ secret_goal
    refute JSON.encode!(constructed) =~ secret_goal
    refute JSON.encode!(constructed) =~ secret_instruction
    assert constructed["data"]["authority"] == "attenuated"
    assert constructed["data"]["role"] == "Elixir debugging specialist"
    assert spawned["data"]["spec_id"] == spec.spec_id
    assert spawned["data"]["role"] == spec.role

    assert {:ok, public_events} = BeamAgent.goal_events(parent_id)

    public_constructed =
      Enum.find(
        public_events,
        &(to_string(&1.payload.type) == "agent_constructed" and
            &1.payload.data["target_session_id"] == child_id)
      )

    assert public_constructed.payload.data["provenance"]["role"] == "runtime_inference"
    refute JSON.encode!(public_events) =~ secret_goal
    refute JSON.encode!(public_events) =~ secret_instruction

    assert {:ok, tree} = BeamAgent.goal_tree(parent_id)
    rendered = BeamAgent.RuntimeGoalTree.render(tree)
    assert Enum.any?(rendered, &(&1 =~ "Elixir debugging specialist dynamic-"))
  end

  test "a proposal cannot expand parent authority", context do
    assert {:ok, parent_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               capabilities: %{
                 tools: ["read_file"],
                 paths: ["lib"],
                 commands: [],
                 hosts: [],
                 mcp_servers: [],
                 model_classes: :all
               }
             )

    assert {:error, {:capability_escalation, :tools, ["run_command"]}} =
             AgentConstructor.child(parent_id, %{
               goal: "Run a command outside my authority",
               capabilities: %{tools: ["run_command"]}
             })

    assert {:error, {:capability_escalation, :tools, ["run_command"]}} =
             BeamAgent.spawn_subagent(parent_id,
               agent_proposal: %{
                 goal: "Run a command outside my authority",
                 capabilities: %{tools: ["run_command"]}
               }
             )

    {:ok, events} = BeamAgent.events(parent_id)
    failed = Enum.find(events, &(&1["type"] == "agent_construction_failed"))
    assert failed["data"]["failure_code"] == "capability_escalation"
  end

  test "hard authority fields in an intelligence proposal are rejected", context do
    assert {:ok, parent_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    assert {:error, {:hard_authority_fields_rejected, fields}} =
             BeamAgent.spawn_subagent(parent_id,
               agent_proposal: %{
                 goal: "Attempt to grant myself authority through a prompt",
                 resources: %{budget: :unlimited},
                 lifecycle: %{depth: 99},
                 credentials: "secret"
               }
             )

    assert fields == ["credentials", "lifecycle", "resources"]

    {:ok, events} = BeamAgent.events(parent_id)
    failed = List.last(Enum.filter(events, &(&1["type"] == "agent_construction_failed")))
    assert failed["data"]["failure_code"] == "hard_authority_fields_rejected"
  end

  test "capability envelopes remain independently authorizable", _context do
    envelope = CapabilityEnvelope.root(%{tools: ["read_file"]})
    assert :ok = CapabilityEnvelope.authorize(envelope, %{tools: "read_file"})
  end

  test "constructed authority filters the tools shown to the model", context do
    assert {:ok, session_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :agent_spec_tool_capture,
               provider_options: [test_pid: self()],
               capabilities: %{
                 tools: ["read_file"],
                 paths: :all,
                 commands: [],
                 hosts: [],
                 mcp_servers: [],
                 model_classes: :all
               }
             )

    assert {:ok, "captured"} = BeamAgent.ask(session_id, "Inspect one file")
    assert_receive {:visible_tools, ["read_file"]}
  end
end
