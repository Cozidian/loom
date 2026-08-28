defmodule BeamAgent.WorktreeRuntimeTest do
  use ExUnit.Case, async: false

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-worktree-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "README.md"), "base\n")
    {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)
    {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace)

    {_output, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=Beam Agent",
          "-c",
          "user.email=beam@example.test",
          "commit",
          "-m",
          "base"
        ],
        cd: workspace,
        stderr_to_stdout: true
      )

    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace, data_dir: data_dir}
  end

  test "implementation workers can be bound to owned isolated worktrees", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    {:ok, goal} = BeamAgent.goal(root_id)
    worker_id = BeamAgent.new_session_id()

    assert {:ok, worktree} =
             BeamAgent.create_worktree(goal.project_id, worker_id,
               purpose: "isolated test implementation",
               event_session_id: root_id
             )

    assert File.dir?(worktree.path)

    assert {:ok, worker} =
             BeamAgent.spawn_worker(
               root_id,
               %{goal: "Implement inside the isolated worktree", template: "implementer"},
               provider: :echo,
               data_dir: context.data_dir,
               session_id: worker_id,
               worktree_handle: worktree
             )

    assert {:ok, spec} = BeamAgent.agent_spec(worker.worker_id)
    assert spec.restrictions.workspace_root == worktree.path
    assert spec.restrictions.worktree_id == worktree.id
    assert %{kind: "git_worktree", id: worktree_id} = List.last(spec.context_refs)
    assert worktree_id == worktree.id

    File.write!(Path.join(worktree.path, "README.md"), "changed in worktree\n")
    assert {:ok, evidence} = BeamAgent.inspect_worktree(goal.project_id, worktree.id)
    assert evidence.changed_files == ["README.md"]
    assert evidence.patch =~ "changed in worktree"

    assert {:error, :worktree_has_uncommitted_changes} =
             BeamAgent.cleanup_worktree(goal.project_id, worktree.id)

    assert :ok = BeamAgent.cleanup_worktree(goal.project_id, worktree.id, force: true)
    refute File.exists?(worktree.path)

    {:ok, events} = BeamAgent.events(root_id)
    assert Enum.any?(events, &(&1["type"] == "worktree_created"))
    assert Enum.any?(events, &(&1["type"] == "worktree_inspected"))
    assert Enum.any?(events, &(&1["type"] == "worktree_reclaimed"))
  end
end
