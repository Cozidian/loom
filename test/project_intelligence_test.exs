defmodule BeamAgent.ProjectIntelligenceTest do
  use ExUnit.Case, async: false

  alias BeamAgent.Project.ContextStore

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-project-intelligence-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(Path.join(workspace, "lib"))
    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace, data_dir: data_dir}
  end

  test "repository intelligence refreshes incrementally and feeds bounded context", context do
    source = Path.join(context.workspace, "lib/sample.ex")

    File.write!(source, """
    defmodule Sample do
      alias Example.Dependency
      def hello, do: :world
    end
    """)

    test_source = Path.join(context.workspace, "test/sample_test.exs")
    File.mkdir_p!(Path.dirname(test_source))
    File.write!(test_source, "defmodule SampleTest do\nend\n")

    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               repository_scan_interval_ms: 60_000
             )

    {:ok, goal} = BeamAgent.goal(root_id)
    assert {:ok, first} = BeamAgent.refresh_repository(goal.project_id)
    assert first.file_count == 2
    assert first.files["lib/sample.ex"].symbols == ["Sample", "hello"]
    assert first.files["lib/sample.ex"].dependencies == ["Example.Dependency"]
    assert first.files["lib/sample.ex"].diagnostics == []
    assert first.files["lib/sample.ex"].test_relationships == ["test/sample_test.exs"]
    assert first.files["test/sample_test.exs"].test_relationships == ["lib/sample.ex"]

    File.write!(source, "defmodule Sample do\n  def changed, do: :ok\nend\n")
    assert {:ok, second} = BeamAgent.refresh_repository(goal.project_id)
    assert second.generation > first.generation
    assert second.files["lib/sample.ex"].symbols == ["Sample", "changed"]

    assert {:ok, view} =
             BeamAgent.project_context(goal.project_id,
               kinds: ["repository"],
               maximum_bytes: 64_000
             )

    assert [%{kind: "repository", source_version: version}] = view.artifacts
    assert version == second.generation
    assert view.total_bytes > 0
    assert [%{source: source_path}] = view.provenance
    assert {:ok, canonical_workspace} = BeamAgent.Workspace.canonical_root(context.workspace)
    assert source_path == canonical_workspace

    assert {:error, :stale_context_artifact} =
             ContextStore.put(goal.project_id, %{
               id: "repository:snapshot",
               kind: "repository",
               source: context.workspace,
               source_version: 0,
               content: "stale"
             })

    {:ok, events} = BeamAgent.events(root_id)
    update = List.last(Enum.filter(events, &(&1["type"] == "repository_updated")))
    assert "lib/sample.ex" in update["data"]["changed_paths"]
    refute Enum.any?(events, &(&1["type"] == "file_changed"))
  end

  test "project routing preferences are durable runtime knowledge", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    {:ok, goal} = BeamAgent.goal(root_id)

    assert {:ok, preferences} =
             BeamAgent.set_project_preferences(goal.project_id, %{
               evidence_mode: "enabled",
               exploration_percent: 2,
               excluded_endpoint_ids: ["retired-model"],
               preferred_endpoint_ids: ["echo"]
             })

    assert preferences.evidence_mode == :enabled
    assert preferences.preferred_endpoint_ids == ["echo"]
    assert {:ok, artifact} = ContextStore.fetch(goal.project_id, "project:preferences")
    assert artifact.kind == "preference"

    assert artifact.metadata == %{"authority" => "user"} or
             artifact.metadata == %{authority: "user"}

    {:ok, router} = BeamAgent.Names.pid(:model_router, goal.project_id)
    monitor = Process.monitor(router)
    Process.exit(router, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^router, _reason}, 2_000

    assert {:ok, restarted} = wait_for_router(goal.project_id)
    assert restarted.evidence_mode == :enabled
    assert restarted.excluded_endpoint_ids == ["retired-model"]
  end

  defp wait_for_router(project_id, attempts \\ 40)
  defp wait_for_router(_project_id, 0), do: {:error, :router_not_restarted}

  defp wait_for_router(project_id, attempts) do
    case BeamAgent.project_preferences(project_id) do
      {:ok, preferences} ->
        {:ok, preferences}

      _other ->
        Process.sleep(25)
        wait_for_router(project_id, attempts - 1)
    end
  end
end
