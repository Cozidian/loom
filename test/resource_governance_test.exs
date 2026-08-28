defmodule BeamAgent.ResourceGovernanceTest do
  use ExUnit.Case, async: false

  alias BeamAgent.Goal.{BudgetManager, CapabilityManager}
  alias BeamAgent.Project.ResourceScheduler

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-resource-governance-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace, data_dir: data_dir}
  end

  test "goal budgets allocate, enforce, and release child resources", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               budget: %{
                 concurrent_workers: 1,
                 shell_commands: 1,
                 test_runs: 1,
                 model_tokens: 100
               }
             )

    assert {:ok, "budget-child-one"} =
             BeamAgent.spawn_subagent(root_id,
               session_id: "budget-child-one",
               provider: :echo,
               capabilities: %{tools: ["read_file"]}
             )

    assert {:error, :worker_concurrency_exhausted} =
             BeamAgent.spawn_subagent(root_id,
               session_id: "budget-child-two",
               provider: :echo
             )

    assert :ok = BudgetManager.consume(root_id, "budget-child-one", %{shell_commands: 1})

    assert {:error, :budget_exhausted} =
             BudgetManager.consume(root_id, "budget-child-one", %{shell_commands: 1})

    assert {:ok, budget} = BeamAgent.budget(root_id)
    root_allocation = Enum.find(budget.allocations, &is_nil(&1.parent_allocation_id))
    assert root_allocation.usage.shell_commands == 1

    assert :ok = BeamAgent.stop_session("budget-child-one")
    wait_for_released_budget(root_id, "budget-child-one")

    assert {:ok, "budget-child-two"} =
             BeamAgent.spawn_subagent(root_id,
               session_id: "budget-child-two",
               provider: :echo
             )

    {:ok, events} = BeamAgent.events(root_id)
    assert Enum.any?(events, &(&1["type"] == "budget_allocated"))
    assert Enum.any?(events, &(&1["type"] == "budget_warning"))
    assert Enum.any?(events, &(&1["type"] == "budget_exhausted"))
    assert Enum.any?(events, &(&1["type"] == "budget_released"))
  end

  test "temporary capability leases are scoped, consumable, and revocable", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    assert {:ok, child_id} =
             BeamAgent.spawn_subagent(root_id,
               provider: :echo,
               capabilities: %{tools: ["read_file"]}
             )

    assert {:ok, lease} =
             CapabilityManager.issue(
               root_id,
               root_id,
               child_id,
               %{tools: ["run_command"], commands: ["mix"]},
               operations: 1,
               duration_ms: 60_000
             )

    assert CapabilityManager.permits?(root_id, child_id, %{tools: "run_command"})

    lease_id = lease.id

    assert {:ok, ^lease_id} =
             CapabilityManager.authorize(root_id, child_id, %{
               tools: "run_command",
               commands: "mix"
             })

    assert {:error, :capability_lease_denied} =
             CapabilityManager.authorize(root_id, child_id, %{
               tools: "run_command",
               commands: "mix"
             })

    assert :ok = BeamAgent.revoke_capability_lease(root_id, lease.id)
    refute CapabilityManager.permits?(root_id, child_id, %{tools: "run_command"})
  end

  test "escalation is approved by the parent policy rather than the delegate", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               approval_policy: :auto
             )

    assert {:ok, child_id} =
             BeamAgent.spawn_subagent(root_id,
               provider: :echo,
               capabilities: %{tools: ["request_capability"]}
             )

    assert {:ok, lease} =
             BeamAgent.request_capability(child_id, %{
               purpose: "Run one deterministic Mix check",
               capabilities: %{tools: ["run_command"], commands: ["mix"]},
               duration_ms: 60_000,
               operations: 1,
               fallback: "report blocked"
             })

    assert lease.source == :approved_escalation
    assert lease.worker_id == child_id

    {:ok, events} = BeamAgent.goal_events(root_id, view: :public)
    types = Enum.map(events, &to_string(&1.payload.type))
    assert "capability_requested" in types
    assert "capability_request_approved" in types
    assert "capability_lease_issued" in types
  end

  test "secret handles never place secret material in events and are owner bound", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    assert {:ok, child_id} = BeamAgent.spawn_subagent(root_id, provider: :echo)
    secret = "secret-marker-#{System.unique_integer([:positive])}"

    assert {:ok, handle} =
             BeamAgent.issue_secret_handle(root_id, child_id, :api_key, secret,
               scopes: %{hosts: ["example.test"]}
             )

    assert {:ok, byte_size(secret)} ==
             BeamAgent.invoke_secret_handle(
               root_id,
               child_id,
               handle.id,
               %{hosts: "example.test"},
               fn material -> {:ok, byte_size(material)} end
             )

    assert {:error, :secret_handle_wrong_owner} =
             BeamAgent.invoke_secret_handle(
               root_id,
               root_id,
               handle.id,
               %{hosts: "example.test"},
               fn _material -> :ok end
             )

    {:ok, events} = BeamAgent.events(root_id)
    refute JSON.encode!(events) =~ secret
    assert Enum.any?(events, &(&1["type"] == "secret_handle_issued"))
    assert Enum.any?(events, &(&1["type"] == "secret_handle_used"))
  end

  test "project resource pools apply backpressure and reclaim slots", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               resource_limits: %{test: 1}
             )

    {:ok, goal} = BeamAgent.goal(root_id)
    assert {:ok, first} = ResourceScheduler.acquire(goal.project_id, :test, self())

    test_pid = self()

    waiting =
      Task.async(fn ->
        result = ResourceScheduler.acquire(goal.project_id, :test, self(), session_id: root_id)
        send(test_pid, {:second_lease, result})

        receive do
          :release_second ->
            {:ok, lease} = result
            ResourceScheduler.release(goal.project_id, lease.id)
        end
      end)

    Process.sleep(20)
    assert {:ok, %{test: %{active: 1, queued: 1}}} = ResourceScheduler.snapshot(goal.project_id)
    assert :ok = ResourceScheduler.release(goal.project_id, first.id)
    assert_receive {:second_lease, {:ok, second}}
    assert second.wait_ms >= 10
    send(waiting.pid, :release_second)
    assert :ok = Task.await(waiting)

    assert {:ok, events} = BeamAgent.events(root_id)
    assert Enum.any?(events, &(&1["type"] == "resource_queued"))
    assert Enum.any?(events, &(&1["type"] == "resource_granted"))
    assert Enum.any?(events, &(&1["type"] == "resource_released"))
  end

  test "shell output is streamed as bounded runtime deltas", context do
    if :os.type() == {:unix, :darwin} do
      assert {:ok, root_id} =
               BeamAgent.start_session(
                 data_dir: context.data_dir,
                 workspace_root: context.workspace,
                 provider: :echo,
                 approval_policy: :auto
               )

      assert :ok = BeamAgent.subscribe_goal(root_id, self(), view: :internal)
      assert {:ok, tool_context} = BeamAgent.Agent.construction_context(root_id)

      assert {:ok, _result} =
               BeamAgent.ToolRunner.execute(
                 BeamAgent.Tools.RunCommand,
                 %{"command" => "printf streamed-output"},
                 tool_context
               )

      assert_receive {:beam_agent_runtime_event,
                      %{
                        payload: %{
                          type: :command_output_delta,
                          data: %{delta: "streamed-output"}
                        }
                      }},
                     2_000
    end
  end

  test "resource hierarchies deny confused-deputy authority expansion", context do
    capabilities = %{
      tools: ["spawn_subagent", "request_capability", "git_inspect"],
      paths: :all,
      commands: [],
      hosts: [],
      git_operations: ["status"],
      browser_scopes: [],
      mcp_servers: [],
      model_classes: :all,
      secret_kinds: ["github_token"],
      approval_scopes: []
    }

    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               capabilities: capabilities,
               approval_policy: :auto
             )

    assert {:ok, child_id} = BeamAgent.spawn_subagent(root_id, provider: :echo)

    assert {:error, {:capability_denied, :secret_kinds, "database_password"}} =
             BeamAgent.issue_secret_handle(
               root_id,
               child_id,
               :database_password,
               "must-not-be-issued"
             )

    assert {:error, {:capability_escalation, :git_operations, ["diff"]}} =
             BeamAgent.request_capability(child_id, %{
               purpose: "Try to turn status authority into diff authority",
               capabilities: %{git_operations: ["diff"]},
               operations: 1
             })
  end

  defp wait_for_released_budget(goal_id, worker_id, attempts \\ 100)

  defp wait_for_released_budget(_goal_id, _worker_id, 0),
    do: flunk("budget allocation was not released")

  defp wait_for_released_budget(goal_id, worker_id, attempts) do
    {:ok, budget} = BeamAgent.budget(goal_id)

    case Enum.find(budget.allocations, &(&1.worker_id == worker_id)) do
      %{status: :released} ->
        :ok

      _other ->
        Process.sleep(10)
        wait_for_released_budget(goal_id, worker_id, attempts - 1)
    end
  end
end
