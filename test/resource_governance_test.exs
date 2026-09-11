defmodule BeamAgent.ResourceGovernanceTest do
  use ExUnit.Case, async: false

  alias BeamAgent.Goal.{BudgetManager, CapabilityManager}
  alias BeamAgent.Project.ResourceScheduler

  defmodule ClosingEventLog do
    use GenServer

    def start_link(opts),
      do:
        GenServer.start_link(__MODULE__, opts,
          name: BeamAgent.Names.via(:event_log, opts[:session_id])
        )

    def init(opts), do: {:ok, opts}

    def handle_call({:append, type, _data, _metadata}, _from, opts) do
      send(opts[:test_pid], {:recorded, type})

      if type == :resource_reclaimed,
        do: {:stop, :normal, opts},
        else: {:reply, {:ok, %{}}, opts}
    end
  end

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

  test "worker reservations queue at capacity and reclaim abandoned waiters", context do
    {:ok, id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :echo,
        budget: %{concurrent_workers: 1}
      )

    {:ok, first} = BudgetManager.reserve(id, id, "first")

    abandoned =
      Task.async(fn ->
        BudgetManager.reserve(id, id, "abandoned", %{}, wait_for_capacity: true)
      end)

    wait_for_queue(id, 1)
    Task.shutdown(abandoned, :brutal_kill)
    wait_for_queue(id, 0)

    waiting =
      Task.async(fn ->
        result = BudgetManager.reserve(id, id, "next", %{}, wait_for_capacity: true)
        # Transfer the reservation to an actor before the requesting process exits.
        {:ok, allocation} = result
        BudgetManager.bind(id, allocation.allocation_id, Process.whereis(__MODULE__))
        result
      end)

    Process.register(self(), __MODULE__)
    wait_for_queue(id, 1)
    assert :ok = BudgetManager.release(id, first.allocation_id)
    assert {:ok, next} = Task.await(waiting)
    assert next.worker_id == "next"
    wait_for_queue(id, 0)
    {:ok, budget} = BeamAgent.budget(id)
    refute Enum.any?(budget.allocations, &(&1.worker_id == "abandoned"))
    assert :ok = BudgetManager.release(id, next.allocation_id)
  end

  test "provisional reservations are reclaimed if their caller dies before binding", context do
    {:ok, id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :echo,
        budget: %{concurrent_workers: 1}
      )

    task = Task.async(fn -> BudgetManager.reserve(id, id, "unbound") end)
    assert {:ok, _allocation} = Task.await(task)
    wait_for_released_budget(id, "unbound")
    assert {:ok, _allocation} = BudgetManager.reserve(id, id, "replacement")
  end

  test "finite provisional budgets can safely serve as allocation parents", context do
    {:ok, id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :echo,
        budget: %{concurrent_workers: 2, wall_time_ms: 10_000}
      )

    assert {:ok, _} = BudgetManager.reserve(id, id, "provisional-parent")
    assert {:ok, _} = BudgetManager.reserve(id, "provisional-parent", "provisional-child")
  end

  defp wait_for_queue(id, count, attempts \\ 100)
  defp wait_for_queue(_id, _count, 0), do: flunk("worker queue did not settle")

  defp wait_for_queue(id, count, attempts) do
    case BeamAgent.budget(id) do
      {:ok, %{queued: ^count}} ->
        :ok

      _ ->
        Process.sleep(10)
        wait_for_queue(id, count, attempts - 1)
    end
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

  test "a closing session log cannot crash the project scheduler or strand queued work" do
    id = "scheduler-shutdown-#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec({ClosingEventLog, session_id: id, test_pid: self()},
        restart: :temporary
      )
    )

    scheduler =
      start_supervised!({ResourceScheduler, project_id: id, resource_limits: %{test: 1}})

    owner = spawn(fn -> receive do: (:finish -> :ok) end)
    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    assert {:ok, _first} = ResourceScheduler.acquire(id, :test, owner, session_id: id)
    test_pid = self()

    waiter =
      spawn(fn ->
        result = ResourceScheduler.acquire(id, :test, self(), session_id: id)
        send(test_pid, {:queued_work_granted, result})
        receive do: (:finish -> :ok)
      end)

    on_exit(fn -> if Process.alive?(waiter), do: Process.exit(waiter, :kill) end)
    assert_receive {:recorded, :resource_queued}, 2_000
    send(owner, :finish)
    assert_receive {:recorded, :resource_reclaimed}, 2_000
    assert_receive {:queued_work_granted, {:ok, _lease}}, 2_000
    assert {:ok, ^scheduler} = BeamAgent.Names.pid(:project_resource_scheduler, id)
    assert {:ok, %{test: %{active: 1, queued: 0}}} = ResourceScheduler.snapshot(id)
    send(waiter, :finish)
  end

  test "delegated model work borrows bounded capacity from its waiting parent", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               resource_limits: %{expensive_model: 1}
             )

    {:ok, goal} = BeamAgent.goal(root_id)

    assert {:ok, parent} =
             ResourceScheduler.acquire(goal.project_id, :expensive_model, self(),
               session_id: root_id
             )

    test_pid = self()

    first_child =
      Task.async(fn ->
        result =
          ResourceScheduler.acquire(goal.project_id, :expensive_model, self(),
            session_id: "delegated-child-one",
            parent_session_id: root_id
          )

        send(test_pid, {:first_child_lease, result})

        receive do
          :release_child ->
            {:ok, lease} = result
            ResourceScheduler.release(goal.project_id, lease.id)
        end
      end)

    assert_receive {:first_child_lease, {:ok, first_lease}}
    assert first_lease.borrowed_from_session_id == root_id

    second_child =
      Task.async(fn ->
        result =
          ResourceScheduler.acquire(goal.project_id, :expensive_model, self(),
            session_id: "delegated-child-two",
            parent_session_id: root_id
          )

        send(test_pid, {:second_child_lease, result})

        receive do
          :release_child ->
            {:ok, lease} = result
            ResourceScheduler.release(goal.project_id, lease.id)
        end
      end)

    Process.sleep(20)

    assert {:ok, %{expensive_model: %{active: 2, queued: 1}}} =
             ResourceScheduler.snapshot(goal.project_id)

    send(first_child.pid, :release_child)
    assert :ok = Task.await(first_child)

    assert_receive {:second_child_lease, {:ok, second_lease}}
    assert second_lease.borrowed_from_session_id == root_id

    send(second_child.pid, :release_child)
    assert :ok = Task.await(second_child)
    assert :ok = ResourceScheduler.release(goal.project_id, parent.id)

    assert {:ok, %{expensive_model: %{active: 0, queued: 0}}} =
             ResourceScheduler.snapshot(goal.project_id)
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

  test "absolute in-workspace tool paths are canonicalized before capability checks", context do
    File.write!(Path.join(context.workspace, "README.md"), "canonical workspace\n")

    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               approval_policy: :auto,
               capabilities: %{tools: ["read_file"], paths: ["."]}
             )

    assert {:ok, tool_context} = BeamAgent.Agent.construction_context(root_id)

    assert {:ok, encoded} =
             BeamAgent.ToolRunner.execute(
               BeamAgent.Tools.ReadFile,
               %{"path" => Path.join(context.workspace, "README.md")},
               tool_context
             )

    assert JSON.decode!(encoded)["content"] == "canonical workspace\n"

    outside = Path.join(Path.dirname(context.workspace), "outside.txt")
    File.write!(outside, "outside\n")

    assert {:error, {:capability_denied, :paths, ^outside}} =
             BeamAgent.ToolRunner.execute(
               BeamAgent.Tools.ReadFile,
               %{"path" => outside},
               tool_context
             )

    assert {:ok, events} = BeamAgent.events(root_id)

    assert Enum.count(events, &(&1["type"] == "capability_denied")) == 1
  end

  test "omitted path defaults cannot bypass a scoped capability envelope", context do
    allowed = Path.join(context.workspace, "allowed")
    File.mkdir_p!(allowed)
    File.write!(Path.join(allowed, "inside.txt"), "inside\n")

    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               approval_policy: :auto,
               capabilities: %{
                 tools: ["list_files", "search_files", "run_command"],
                 paths: ["allowed"],
                 commands: ["pwd"]
               }
             )

    assert {:ok, tool_context} = BeamAgent.Agent.construction_context(root_id)

    assert {:error, {:capability_denied, :paths, "."}} =
             BeamAgent.ToolRunner.execute(BeamAgent.Tools.ListFiles, %{}, tool_context)

    assert {:error, {:capability_denied, :paths, "."}} =
             BeamAgent.ToolRunner.execute(
               BeamAgent.Tools.SearchFiles,
               %{"query" => "inside"},
               tool_context
             )

    assert {:error, {:capability_denied, :paths, "."}} =
             BeamAgent.ToolRunner.execute(
               BeamAgent.Tools.RunCommand,
               %{"command" => "pwd"},
               tool_context
             )

    assert {:ok, _listing} =
             BeamAgent.ToolRunner.execute(
               BeamAgent.Tools.ListFiles,
               %{"path" => "allowed"},
               tool_context
             )

    assert {:ok, _search} =
             BeamAgent.ToolRunner.execute(
               BeamAgent.Tools.SearchFiles,
               %{"query" => "inside", "path" => "allowed"},
               tool_context
             )

    assert {:ok, _command} =
             BeamAgent.ToolRunner.execute(
               BeamAgent.Tools.RunCommand,
               %{"command" => "pwd", "cwd" => "allowed"},
               tool_context
             )
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
