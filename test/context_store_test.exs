defmodule BeamAgent.Project.ContextStoreTest do
  use ExUnit.Case, async: true

  alias BeamAgent.Project.ContextStore

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "context-store-test-#{System.unique_integer([:positive])}")

    project_id = "project-#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf(data_dir) end)
    %{data_dir: data_dir, project_id: project_id}
  end

  defp artifact_path(data_dir, project_id),
    do: Path.join([data_dir, "projects", project_id, "context_artifacts.jsonl"])

  test "repeated puts to the same id do not grow the file without bound", context do
    start_supervised!({ContextStore, project_id: context.project_id, data_dir: context.data_dir})

    for version <- 1..20 do
      assert {:ok, _} =
               ContextStore.put(context.project_id, %{
                 id: "repository:snapshot",
                 kind: "repository",
                 source: "workspace",
                 source_version: version,
                 content: "generation #{version}"
               })
    end

    path = artifact_path(context.data_dir, context.project_id)
    lines = path |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 1

    assert {:ok, artifact} = ContextStore.fetch(context.project_id, "repository:snapshot")
    assert artifact.content == "generation 20"
  end

  test "a pre-existing append-only history is compacted on init", context do
    path = artifact_path(context.data_dir, context.project_id)
    File.mkdir_p!(Path.dirname(path))

    body =
      for version <- 1..50 do
        JSON.encode!(%{
          "type" => "artifact_put",
          "artifact" => %{
            "id" => "repository:snapshot",
            "kind" => "repository",
            "source" => "workspace",
            "source_version" => version,
            "content" => "generation #{version}",
            "hash" => "h#{version}",
            "size_bytes" => 0,
            "confidence" => 1.0,
            "metadata" => %{},
            "observed_at" => "2026-01-01T00:00:00Z",
            "status" => "current"
          }
        }) <> "\n"
      end

    File.write!(path, body)
    before_size = File.stat!(path).size

    start_supervised!({ContextStore, project_id: context.project_id, data_dir: context.data_dir})

    after_size = File.stat!(path).size
    lines = path |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 1
    assert after_size < before_size

    assert {:ok, artifact} = ContextStore.fetch(context.project_id, "repository:snapshot")
    assert artifact.content == "generation 50"
  end

  test "distinct artifact ids each keep their own line", context do
    start_supervised!({ContextStore, project_id: context.project_id, data_dir: context.data_dir})

    assert {:ok, _} =
             ContextStore.put(context.project_id, %{
               id: "repository:snapshot",
               kind: "repository",
               source: "workspace",
               source_version: 1,
               content: "repo"
             })

    assert {:ok, _} =
             ContextStore.put(context.project_id, %{
               id: "project:preferences",
               kind: "preference",
               source: "user_runtime_configuration",
               source_version: 1,
               content: "prefs"
             })

    path = artifact_path(context.data_dir, context.project_id)
    lines = path |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 2
  end
end
