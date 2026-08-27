defmodule BeamAgent.ProjectGoalRuntimeTest do
  use ExUnit.Case, async: false

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-project-goal-test-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    {:ok, workspace} = BeamAgent.Workspace.canonical_root(workspace)
    project_id = BeamAgent.Project.id_for_workspace(workspace)

    on_exit(fn ->
      _ = BeamAgent.stop_project(project_id)
      File.rm_rf(root)
    end)

    %{workspace: workspace, data_dir: data_dir, project_id: project_id}
  end

  test "the same canonical workspace reuses one long-lived project runtime", context do
    alias_path = Path.join(Path.dirname(context.workspace), "workspace-alias")
    File.ln_s!(context.workspace, alias_path)

    assert {:ok, project_id} = BeamAgent.start_project(workspace_root: context.workspace)
    assert {:ok, ^project_id} = BeamAgent.start_project(workspace_root: alias_path)
    assert project_id == context.project_id

    assert {:ok, first_supervisor} = BeamAgent.project_supervisor_pid(project_id)
    assert {:ok, ^project_id} = BeamAgent.start_project(workspace_root: context.workspace)
    assert {:ok, ^first_supervisor} = BeamAgent.project_supervisor_pid(project_id)
    assert {:ok, project} = BeamAgent.project(project_id)
    assert project.project_id == project_id
    assert project.workspace_root == context.workspace
  end

  test "root sessions are project-owned goals and retain durable identity", context do
    assert {:ok, session_id} =
             BeamAgent.start_session(
               session_id: "compatibility-goal",
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    assert session_id == "compatibility-goal"

    assert {:ok, goal} = BeamAgent.goal(session_id)
    assert goal.goal_id == session_id
    assert goal.project_id == context.project_id
    assert goal.session_id == session_id

    assert {:ok, events} = BeamAgent.events(session_id)
    started = hd(events)
    assert started["type"] == "session_started"
    assert started["data"]["project_id"] == context.project_id
    assert started["data"]["goal_id"] == session_id

    assert {:ok, "goal-worker"} =
             BeamAgent.spawn_subagent(session_id,
               session_id: "goal-worker",
               data_dir: context.data_dir,
               provider: :echo
             )

    assert {:ok, child_events} = BeamAgent.events("goal-worker")
    child_started = hd(child_events)
    assert child_started["data"]["parent_session_id"] == session_id
    assert child_started["data"]["project_id"] == context.project_id
    assert child_started["data"]["goal_id"] == session_id

    assert {:ok, goal_events} = BeamAgent.goal_events(session_id)

    sequences_before_restart =
      Map.new(goal_events, &{&1.event_id, &1.goal_seq})

    assert Enum.any?(goal_events, fn event ->
             event.version == 1 and event.durability == :durable and
               event.scope.project_id == context.project_id and
               event.scope.goal_id == session_id and
               event.scope.session_id == "goal-worker" and
               event.payload.type == "agent_started"
           end)

    assert {:ok, first_event_hub} = BeamAgent.goal_event_hub_pid(session_id)
    Process.exit(first_event_hub, :kill)
    assert wait_for_new_pid(:goal_event_hub, session_id, first_event_hub) != first_event_hub
    assert wait_for_goal_event(session_id, "goal-worker", "agent_started")
    assert {:ok, rebuilt_goal_events} = BeamAgent.goal_events(session_id)

    assert Enum.all?(sequences_before_restart, fn {event_id, goal_seq} ->
             Enum.any?(
               rebuilt_goal_events,
               &(&1.event_id == event_id and &1.goal_seq == goal_seq)
             )
           end)

    assert :ok = BeamAgent.stop_session(session_id)
    wait_until_missing(:goal, session_id)
    wait_until_missing(:agent, "goal-worker")
    assert {:ok, _project_pid} = BeamAgent.project_pid(context.project_id)

    assert {:ok, ^session_id} =
             BeamAgent.resume_session(session_id,
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    assert {:ok, "echo(1): resumed"} = BeamAgent.ask(session_id, "resumed")
  end

  test "goal failure and shutdown remain isolated from sibling goals", context do
    assert {:ok, project_id} = BeamAgent.start_project(workspace_root: context.workspace)

    assert {:ok, "goal-one"} =
             BeamAgent.start_goal(project_id,
               goal_id: "goal-one",
               data_dir: context.data_dir,
               provider: :echo,
               objective: "exercise recovery"
             )

    assert {:ok, "goal-two"} =
             BeamAgent.start_goal(project_id,
               goal_id: "goal-two",
               data_dir: context.data_dir,
               provider: :echo
             )

    assert {:ok, "echo(1): before crash"} = BeamAgent.ask("goal-one", "before crash")
    assert {:ok, sibling_agent} = BeamAgent.agent_pid("goal-two")
    assert {:ok, project_state} = BeamAgent.project_pid(project_id)
    assert {:ok, first_goal_agent} = BeamAgent.agent_pid("goal-one")

    Process.exit(project_state, :kill)

    assert wait_for_new_pid(:project, project_id, project_state) != project_state
    assert {:ok, ^first_goal_agent} = BeamAgent.agent_pid("goal-one")
    assert {:ok, ^sibling_agent} = BeamAgent.agent_pid("goal-two")

    assert {:ok, old_goal} = BeamAgent.goal_pid("goal-one")
    assert {:ok, old_goal_agent} = BeamAgent.agent_pid("goal-one")

    Process.exit(old_goal, :kill)

    new_goal = wait_for_new_pid(:goal, "goal-one", old_goal)
    new_goal_agent = wait_for_new_pid(:agent, "goal-one", old_goal_agent)
    assert new_goal != old_goal
    assert new_goal_agent != old_goal_agent
    assert {:ok, ^sibling_agent} = BeamAgent.agent_pid("goal-two")
    assert {:ok, "echo(2): after crash"} = BeamAgent.ask("goal-one", "after crash")

    assert :ok = BeamAgent.stop_goal("goal-one")
    wait_until_missing(:goal, "goal-one")
    assert {:ok, _project_pid} = BeamAgent.project_pid(project_id)
    assert {:ok, ^sibling_agent} = BeamAgent.agent_pid("goal-two")
    assert {:ok, "echo(1): sibling survived"} = BeamAgent.ask("goal-two", "sibling survived")
  end

  test "stopping a project terminates all of its active goals", context do
    assert {:ok, project_id} = BeamAgent.start_project(workspace_root: context.workspace)

    for goal_id <- ["project-stop-one", "project-stop-two"] do
      assert {:ok, ^goal_id} =
               BeamAgent.start_goal(project_id,
                 goal_id: goal_id,
                 data_dir: context.data_dir,
                 provider: :echo
               )
    end

    assert :ok = BeamAgent.stop_project(project_id)
    wait_until_missing(:project_supervisor, project_id)
    wait_until_missing(:goal, "project-stop-one")
    wait_until_missing(:goal, "project-stop-two")
  end

  test "legacy session logs acquire a durable project and goal binding", context do
    session_id = "legacy-goal-binding"

    assert {:ok, ^session_id} =
             BeamAgent.start_session(
               session_id: session_id,
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    assert :ok = BeamAgent.stop_session(session_id)
    path = Path.join([context.data_dir, session_id, "events.jsonl"])

    legacy_events =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        event = JSON.decode!(line)

        if event["type"] == "session_started" do
          put_in(event, ["data"], Map.drop(event["data"], ["project_id", "goal_id"]))
        else
          event
        end
      end)

    File.write!(path, Enum.map_join(legacy_events, "", &(JSON.encode!(&1) <> "\n")))

    assert {:ok, ^session_id} =
             BeamAgent.resume_session(session_id,
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    assert {:ok, events} = BeamAgent.events(session_id)

    assert Enum.any?(events, fn event ->
             event["type"] == "goal_bound" and
               event["data"]["project_id"] == context.project_id and
               event["data"]["goal_id"] == session_id and
               event["data"]["reason"] == "legacy_session"
           end)
  end

  defp wait_for_new_pid(kind, id, old_pid, attempts \\ 100)

  defp wait_for_new_pid(_kind, _id, _old_pid, 0), do: flunk("process was not restarted")

  defp wait_for_new_pid(kind, id, old_pid, attempts) do
    case BeamAgent.Names.pid(kind, id) do
      {:ok, pid} when pid != old_pid ->
        pid

      _ ->
        Process.sleep(10)
        wait_for_new_pid(kind, id, old_pid, attempts - 1)
    end
  end

  defp wait_until_missing(kind, id, attempts \\ 100)
  defp wait_until_missing(_kind, _id, 0), do: flunk("process did not stop")

  defp wait_until_missing(kind, id, attempts) do
    case BeamAgent.Names.pid(kind, id) do
      {:error, :not_found} ->
        :ok

      _ ->
        Process.sleep(10)
        wait_until_missing(kind, id, attempts - 1)
    end
  end

  defp wait_for_goal_event(goal_id, session_id, event_type, attempts \\ 100)

  defp wait_for_goal_event(_goal_id, _session_id, _event_type, 0),
    do: flunk("goal event was not reconstructed")

  defp wait_for_goal_event(goal_id, session_id, event_type, attempts) do
    case BeamAgent.goal_events(goal_id) do
      {:ok, events} ->
        if Enum.any?(events, fn event ->
             event.scope.session_id == session_id and event.payload.type == event_type
           end) do
          true
        else
          Process.sleep(10)
          wait_for_goal_event(goal_id, session_id, event_type, attempts - 1)
        end

      {:error, :not_found} ->
        Process.sleep(10)
        wait_for_goal_event(goal_id, session_id, event_type, attempts - 1)
    end
  end
end
