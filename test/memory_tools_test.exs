defmodule BeamAgent.MemoryToolsTest do
  use ExUnit.Case, async: true

  alias BeamAgent.Project.Memory
  alias BeamAgent.Tools.{Forget, Recall, Remember}

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "memory-tools-test-#{System.unique_integer([:positive])}")

    project_id = "project-#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf(data_dir) end)
    start_supervised!({Memory, project_id: project_id, data_dir: data_dir})
    %{context: %{project_id: project_id}}
  end

  test "remember writes a memory and recall lists then reads it", ctx do
    assert {:ok, json} =
             Remember.execute(
               %{
                 "type" => "feedback",
                 "description" => "Prefers terse responses",
                 "content" => "Don't summarize after every response."
               },
               ctx.context
             )

    assert %{"id" => id, "type" => "feedback"} = JSON.decode!(json)

    assert {:ok, index_json} = Recall.execute(%{}, ctx.context)
    assert %{"memories" => [entry]} = JSON.decode!(index_json)
    assert entry["id"] == id
    refute Map.has_key?(entry, "content")

    assert {:ok, full_json} = Recall.execute(%{"id" => id}, ctx.context)
    assert %{"content" => "Don't summarize after every response."} = JSON.decode!(full_json)
  end

  test "forget removes a memory that recall can no longer find", ctx do
    assert {:ok, json} =
             Remember.execute(
               %{
                 "type" => "project",
                 "description" => "Merge freeze",
                 "content" => "Starts Friday."
               },
               ctx.context
             )

    %{"id" => id} = JSON.decode!(json)

    assert {:ok, forget_json} = Forget.execute(%{"id" => id}, ctx.context)
    assert %{"forgotten" => ^id} = JSON.decode!(forget_json)

    assert {:ok, index_json} = Recall.execute(%{}, ctx.context)
    assert %{"memories" => []} = JSON.decode!(index_json)
    assert {:error, :unknown_memory} = Forget.execute(%{"id" => id}, ctx.context)
  end

  test "remember rejects an invalid type without touching the store", ctx do
    assert {:error, {:invalid_memory_type, "vibes"}} =
             Remember.execute(
               %{"type" => "vibes", "description" => "d", "content" => "c"},
               ctx.context
             )

    assert {:ok, index_json} = Recall.execute(%{}, ctx.context)
    assert %{"memories" => []} = JSON.decode!(index_json)
  end

  test "recall and forget reject malformed arguments instead of crashing", ctx do
    assert {:error, :invalid_recall_arguments} = Recall.execute(%{"id" => ""}, ctx.context)
    assert {:error, :expected_memory_id} = Forget.execute(%{}, ctx.context)
  end
end
