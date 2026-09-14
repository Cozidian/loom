defmodule BeamAgent.RepositoryIndexTest do
  use ExUnit.Case, async: false

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-repository-index-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace, data_dir: data_dir}
  end

  test "a symlink cycle does not hang the scan or get indexed as a file", ctx do
    File.write!(Path.join(ctx.workspace, "real.txt"), "hello")
    # A directory symlinking back to its own workspace root: walking it with
    # the old code would recurse forever, growing the accumulated path list
    # without bound (root/loop/loop/loop/...).
    File.ln_s!(ctx.workspace, Path.join(ctx.workspace, "loop"))

    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: ctx.data_dir,
               workspace_root: ctx.workspace,
               provider: :echo,
               repository_scan_interval_ms: 60_000
             )

    {:ok, goal} = BeamAgent.goal(root_id)

    {time_us, result} = :timer.tc(fn -> BeamAgent.refresh_repository(goal.project_id) end)

    assert {:ok, snapshot} = result
    assert time_us < 5_000_000
    assert snapshot.file_count == 1
    assert Map.has_key?(snapshot.files, "real.txt")
    refute Enum.any?(Map.keys(snapshot.files), &String.contains?(&1, "loop"))
  end

  test "a workspace with more files than the configured cap is bounded", ctx do
    for n <- 1..8, do: File.write!(Path.join(ctx.workspace, "file-#{n}.txt"), "x")

    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: ctx.data_dir,
               workspace_root: ctx.workspace,
               provider: :echo,
               repository_scan_interval_ms: 60_000,
               repository_max_files: 3
             )

    {:ok, goal} = BeamAgent.goal(root_id)
    assert {:ok, snapshot} = BeamAgent.refresh_repository(goal.project_id)
    assert snapshot.file_count == 3
  end

  test "a workspace within the cap is indexed in full", ctx do
    for n <- 1..3, do: File.write!(Path.join(ctx.workspace, "file-#{n}.txt"), "x")

    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: ctx.data_dir,
               workspace_root: ctx.workspace,
               provider: :echo,
               repository_scan_interval_ms: 60_000,
               repository_max_files: 3
             )

    {:ok, goal} = BeamAgent.goal(root_id)
    assert {:ok, snapshot} = BeamAgent.refresh_repository(goal.project_id)
    assert snapshot.file_count == 3
  end
end
