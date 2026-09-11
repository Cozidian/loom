defmodule BeamAgent.TaskTeamTest do
  use ExUnit.Case, async: false

  alias BeamAgent.{CLI.Config, DecompositionPlan, WorkPlanningPolicy}

  defmodule Provider do
    @behaviour BeamAgent.LLMProvider
    def id, do: :task_team_test

    def complete(_messages, tools, opts) do
      observer = Process.whereis(:task_team_observer)

      if opts[:parent_session_id] do
        send(
          observer,
          {:worker, self(), opts[:session_id], opts[:model], Enum.map(tools, & &1.name)}
        )

        receive do
          :finish -> {:ok, %{content: "Independent findings", tool_calls: []}}
        after
          15_000 -> {:error, :test_timeout}
        end
      else
        {:ok, result} =
          opts[:dynamic_tool_executor].(%{
            id: "team",
            name: "delegate_tasks",
            arguments: %{"tasks" => tasks(6)}
          })

        send(observer, {:graph_result, JSON.decode!(result.content)})
        {:ok, %{content: "Collected the six results", tool_calls: []}}
      end
    end

    def tasks(count) do
      for i <- 1..count do
        %{
          "id" => "area-#{i}",
          "goal" => "Investigate area #{i}",
          "template" => "researcher",
          "model_requirements" => %{"preferred_endpoint_id" => "single"}
        }
      end
    end
  end

  setup_all do
    :ok = BeamAgent.CapabilityCatalog.register_provider(Provider)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "task-team-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Process.register(self(), :task_team_observer)
    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: root, data_dir: Path.join(root, "runtime")}
  end

  test "one endpoint supports six concurrent same-model workers through the native tool API",
       ctx do
    id = start_session(ctx, 6, 7)
    on_exit(fn -> BeamAgent.stop_session(id) end)
    task = Task.async(fn -> BeamAgent.ask(id, "Research six independent areas") end)

    workers =
      for _ <- 1..6 do
        assert_receive {:worker, pid, child_id, "capable", tools}, 5_000
        refute "create_file" in tools
        refute "spawn_subagent" in tools
        {pid, child_id}
      end

    assert Enum.uniq_by(workers, &elem(&1, 1)) == workers
    assert {:ok, budget} = BeamAgent.budget(id)
    assert Enum.count(budget.allocations, &(&1.status == :active and &1.worker_id != id)) == 6
    Enum.each(workers, fn {pid, _} -> send(pid, :finish) end)
    assert {:ok, "Collected the six results"} = Task.await(task, 10_000)
    assert_receive {:graph_result, result}
    assert result["status"] == "completed"
    assert map_size(result["tasks"]) == 6
    assert result["used_endpoint_ids"] == ["single"]
    assert Enum.all?(result["tasks"], fn {_, value} -> value["attempts"] == 1 end)
  end

  test "a six-task graph drains at two-worker capacity without failed attempts", ctx do
    id = start_session(ctx, 2, 3)
    on_exit(fn -> BeamAgent.stop_session(id) end)
    task = Task.async(fn -> BeamAgent.ask(id, "Research six independent areas") end)

    for _ <- 1..3 do
      assert_receive {:worker, first, _, "capable", _}, 5_000
      assert_receive {:worker, second, _, "capable", _}, 5_000
      refute_receive {:worker, _, _, _, _}, 50
      send(first, :finish)
      send(second, :finish)
    end

    assert {:ok, _} = Task.await(task, 10_000)
    assert_receive {:graph_result, result}
    assert result["status"] == "completed"
    assert Enum.all?(result["tasks"], fn {_, value} -> value["attempts"] == 1 end)
  end

  test "six workers drain through one model slot without deadlocking their native parent", ctx do
    id = start_session(ctx, 6, 1)
    on_exit(fn -> BeamAgent.stop_session(id) end)
    task = Task.async(fn -> BeamAgent.ask(id, "Research six independent areas") end)

    for _ <- 1..6 do
      assert_receive {:worker, pid, _, "capable", _}, 5_000
      refute_receive {:worker, _, _, _, _}, 30
      send(pid, :finish)
    end

    assert {:ok, _} = Task.await(task, 10_000)
    assert_receive {:graph_result, result}
    assert result["status"] == "completed"
  end

  test "automatic teams do not require cheap or distinct model endpoints", ctx do
    id = start_session(ctx, 6, 7)
    on_exit(fn -> BeamAgent.stop_session(id) end)
    {:ok, goal} = BeamAgent.goal(id)
    {:ok, endpoints} = BeamAgent.ModelRegistry.list(goal.project_id)
    assert length(endpoints) == 1

    assert WorkPlanningPolicy.decide("Implement a Phoenix frontend", endpoints,
             model_strategy: :manual,
             team_mode: :auto
           ).mode == :advisory

    assert WorkPlanningPolicy.decide("Implement a Phoenix frontend", endpoints,
             model_strategy: :auto,
             team_mode: :solo
           ).mode == :direct
  end

  test "cancelling the owner removes queued graph tasks and does not restart the graph", ctx do
    id = start_session(ctx, 1, 2)
    on_exit(fn -> BeamAgent.stop_session(id) end)

    {:ok, blocker} =
      BeamAgent.spawn_worker(id, %{goal: "Independent existing work", template: "researcher"})

    task = Task.async(fn -> BeamAgent.ask(id, "Research six independent areas") end)
    eventually(fn -> match?({:ok, %{queued: 1}}, BeamAgent.budget(id)) end)
    assert :ok = BeamAgent.Agent.cancel(id)
    assert {:error, :cancelled} = Task.await(task, 5_000)
    eventually(fn -> match?({:ok, %{queued: 0}}, BeamAgent.budget(id)) end)
    assert :ok = BeamAgent.cancel_worker(blocker)
    refute_receive {:worker, _, _, _, _}, 100
    assert {:ok, [run]} = BeamAgent.work_runs(id)
    assert run.status == :cancelled
    assert Enum.all?(run.tasks, fn {_, status} -> status == :cancelled end)

    {:ok, manager} = BeamAgent.Names.pid(:goal_work_run_manager, id)
    Process.exit(manager, :kill)

    eventually(fn ->
      case BeamAgent.work_runs(id) do
        {:ok, [restored]} ->
          restored.status == :cancelled and
            Enum.all?(restored.tasks, fn {_, s} -> s == :cancelled end)

        _ ->
          false
      end
    end)

    refute_receive {:worker, _, _, _, _}, 100
  end

  test "cancelling an active team reclaims every child allocation", ctx do
    id = start_session(ctx, 6, 7)
    on_exit(fn -> BeamAgent.stop_session(id) end)
    task = Task.async(fn -> BeamAgent.ask(id, "Research six independent areas") end)
    for _ <- 1..6, do: assert_receive({:worker, _, _, _, _}, 5_000)
    assert :ok = BeamAgent.Agent.cancel(id)
    assert {:error, :cancelled} = Task.await(task, 5_000)

    eventually(fn ->
      {:ok, budget} = BeamAgent.budget(id)
      Enum.all?(budget.allocations, &(&1.worker_id == id or &1.status == :released))
    end)

    {:ok, delegations} = BeamAgent.worker_delegations(id)
    assert Enum.all?(delegations, &(&1.status == :cancelled))

    refute_receive {:worker, _, _, _, _}, 100
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(_fun, 0), do: flunk("state did not settle")

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  test "task schema has no fixed task-count ceiling and rejects malformed input" do
    schema = BeamAgent.Tools.DelegateTasks.input_schema()
    refute Map.has_key?(schema.properties.tasks, :maxItems)

    assert {:error, :expected_nonempty_tasks} =
             BeamAgent.Tools.DelegateTasks.execute(%{"tasks" => []}, %{})

    assert {:ok, plan} = DecompositionPlan.new(%{tasks: Provider.tasks(25)})
    assert map_size(plan.tasks) == 25
  end

  test "larger teams still reject overlapping implementation ownership" do
    tasks =
      for i <- 1..6 do
        %{
          id: "part-#{i}",
          goal: "Implement part #{i}",
          template: "implementer",
          capabilities: %{paths: ["lib/part_#{i}"]}
        }
      end

    assert {:ok, _} = DecompositionPlan.new(%{tasks: tasks})
    overlap = put_in(List.last(tasks), [:capabilities, :paths], ["lib"])

    assert {:error, {:multiple_implementation_owners, _}} =
             DecompositionPlan.new(%{tasks: Enum.drop(tasks, -1) ++ [overlap]})

    aliased = put_in(List.last(tasks), [:capabilities, :paths], ["lib/part_2/../part_1"])

    assert {:error, {:multiple_implementation_owners, _}} =
             DecompositionPlan.new(%{tasks: Enum.drop(tasks, -1) ++ [aliased]})
  end

  test "capacity config accepts positive values without a fixed upper ceiling" do
    defaults = Config.defaults()
    runtime = Config.merge_overrides(defaults, max_workers: 12, model_concurrency: 6)

    assert Config.capacity_options(runtime) == [
             budget: %{concurrent_workers: 12},
             resource_limits: %{model: 6, expensive_model: 6}
           ]

    assert Config.capacity_options(Map.drop(defaults, ["max_workers", "model_concurrency"])) ==
             Config.capacity_options(defaults)

    assert {:error, {:invalid_config_value, "max_workers"}} =
             Config.validate_runtime(
               Map.put(runtime, "max_workers", 0)
               |> Map.merge(%{"provider" => "echo", "profile" => "demo"})
             )
  end

  defp start_session(ctx, workers, model_slots) do
    {:ok, id} =
      BeamAgent.start_session(
        workspace_root: ctx.workspace,
        data_dir: ctx.data_dir,
        provider: :task_team_test,
        provider_profile: "single",
        provider_options: [model: "capable"],
        model_strategy: :manual,
        team_mode: :auto,
        approval_policy: :auto,
        budget: %{concurrent_workers: workers},
        resource_limits: %{model: model_slots, expensive_model: model_slots},
        model_endpoints: [
          %{
            id: "single",
            provider: :task_team_test,
            model: "capable",
            claims: %{
              capabilities: [:text_generation, :tool_use, :reasoning],
              locality: :remote,
              privacy: :provider,
              cost_hint: :metered
            }
          }
        ]
      )

    id
  end
end
