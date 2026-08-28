defmodule BeamAgent.VerificationTest do
  use ExUnit.Case, async: false

  alias BeamAgent.VerificationPlan

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-verification-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, workspace: workspace, data_dir: data_dir}
  end

  test "plans validate project checks and discover supported repository checks", context do
    File.write!(Path.join(context.workspace, "mix.exs"), "defmodule Sample.MixProject do\nend\n")
    File.write!(Path.join(context.workspace, "go.mod"), "module example.test/sample\n")
    File.mkdir_p!(Path.join(context.workspace, ".git"))

    assert {:ok, plan} = VerificationPlan.load(context.workspace)
    assert plan.source == "workspace-discovery"

    assert Enum.map(plan.checks, & &1.id) == [
             "git-diff",
             "elixir-compile",
             "elixir-test",
             "go-test"
           ]

    assert {:error, {:invalid_verification_check, 1}} =
             VerificationPlan.new(%{
               source: "test",
               checks: [%{id: "unsafe", command: "true", cwd: "../outside"}]
             })

    assert {:ok, optional_plan} =
             VerificationPlan.new(%{
               "version" => 1,
               "source" => "test",
               "checks" => [%{"id" => "optional", "command" => "false", "required" => false}]
             })

    refute hd(optional_plan.checks).required

    assert {:error, :invalid_verification_plan} =
             VerificationPlan.new(%{version: 2, source: "test", checks: [%{command: "true"}]})
  end

  @tag :darwin
  test "a supervised verifier records passing evidence and promotes the task", context do
    if :os.type() != {:unix, :darwin} do
      :ok
    else
      {:ok, session_id} =
        BeamAgent.start_session(
          data_dir: context.data_dir,
          workspace_root: context.workspace,
          provider: :echo
        )

      assert {:ok, _answer} = BeamAgent.ask(session_id, "implement a small change")
      {:ok, goal} = BeamAgent.goal(session_id)

      {:ok, [task_before]} = BeamAgent.outcomes(goal.project_id, kind: :task)
      assert task_before.status == "completed"
      assert task_before.verification == %{"status" => "unverified"}

      plan = %{
        source: "test",
        checks: [
          %{id: "slow-pass", command: "sleep 0.2; printf verified", timeout_ms: 5_000}
        ]
      }

      verification = Task.async(fn -> BeamAgent.verify(goal.goal_id, plan) end)
      Process.sleep(50)

      assert {:ok, supervisor} =
               BeamAgent.Names.pid(:goal_verification_supervisor, goal.goal_id)

      assert [_worker] = Task.Supervisor.children(supervisor)
      assert {:ok, result} = Task.await(verification, 6_000)
      assert result.status == :passed
      assert result.summary == "1/1 checks passed"

      {:ok, [task_after]} = BeamAgent.outcomes(goal.project_id, kind: :task)
      assert task_after.status == "succeeded"
      assert task_after.verification["status"] == "passed"

      {:ok, events} = BeamAgent.events(session_id)

      assert Enum.map(
               Enum.filter(events, &String.starts_with?(&1["type"], "verification_")),
               & &1["type"]
             ) == [
               "verification_started",
               "verification_check_started",
               "verification_check_finished",
               "verification_finished",
               "verification_attached"
             ]
    end
  end

  @tag :darwin
  test "a required command failure records failed verification and task state", context do
    if :os.type() != {:unix, :darwin} do
      :ok
    else
      {:ok, session_id} =
        BeamAgent.start_session(
          data_dir: context.data_dir,
          workspace_root: context.workspace,
          provider: :echo
        )

      assert {:ok, _answer} = BeamAgent.ask(session_id, "implement a broken change")
      {:ok, goal} = BeamAgent.goal(session_id)

      assert {:ok, result} =
               BeamAgent.verify(goal.goal_id, %{
                 source: "test",
                 checks: [%{id: "required-failure", command: "false | cat", timeout_ms: 5_000}]
               })

      assert result.status == :failed
      assert [%{status: :failed, exit_status: exit_status}] = result.checks
      assert exit_status != 0

      {:ok, [task]} = BeamAgent.outcomes(goal.project_id, kind: :task)
      assert task.status == "failed"
      assert task.verification["status"] == "failed"
    end
  end

  @tag :darwin
  test "required worker completion runs verification automatically", context do
    if :os.type() != {:unix, :darwin} do
      :ok
    else
      config_dir = Path.join(context.workspace, ".beam_agent")
      File.mkdir_p!(config_dir)

      File.write!(
        Path.join(config_dir, "verification.json"),
        JSON.encode!(%{
          version: 1,
          checks: [%{id: "automatic-pass", command: "printf verified", timeout_ms: 5_000}]
        })
      )

      assert {:ok, root_id} =
               BeamAgent.start_session(
                 data_dir: context.data_dir,
                 workspace_root: context.workspace,
                 provider: :echo
               )

      assert {:ok, handle} =
               BeamAgent.spawn_worker(
                 root_id,
                 %{
                   goal: "Implement a bounded change",
                   verification_requirements: %{required: true}
                 },
                 provider: :echo,
                 data_dir: context.data_dir
               )

      assert {:ok, _answer} = BeamAgent.ask(handle.worker_id, "complete the delegated work")
      {:ok, goal} = BeamAgent.goal(root_id)

      {:ok, outcomes} = BeamAgent.outcomes(goal.project_id, kind: :task)
      task = Enum.find(outcomes, &(&1.session_id == handle.worker_id))
      assert task.status == "succeeded"
      assert task.verification["status"] == "passed"

      {:ok, events} = BeamAgent.events(handle.worker_id)
      assert Enum.any?(events, &(&1["type"] == "verification_started"))

      report = Enum.find(events, &(&1["type"] == "completion_report_generated"))
      assert report["data"]["status"] == "verified"
      assert report["data"]["evidence_count"] == 1
    end
  end
end
