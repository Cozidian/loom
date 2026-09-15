defmodule BeamAgent.MemorySessionIntegrationTest do
  use ExUnit.Case, async: false

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-memory-integration-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace, data_dir: data_dir}
  end

  test "a real session's project can remember, recall and forget through the top-level API",
       context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               memory_max_entries: 5
             )

    {:ok, goal} = BeamAgent.goal(root_id)

    assert {:ok, entry} =
             BeamAgent.remember(goal.project_id, %{
               "type" => "feedback",
               "description" => "Prefers terse responses",
               "content" => "Don't summarize after every response."
             })

    assert {:ok, [index]} = BeamAgent.recall(goal.project_id)
    assert index.id == entry.id

    assert {:ok, full} = BeamAgent.recall(goal.project_id, entry.id)
    assert full.content == "Don't summarize after every response."

    assert :ok = BeamAgent.forget(goal.project_id, entry.id)
    assert {:ok, []} = BeamAgent.recall(goal.project_id)
  end
end
