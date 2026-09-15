defmodule BeamAgent.Project.MemoryTest do
  use ExUnit.Case, async: true

  alias BeamAgent.Project.Memory

  setup do
    data_dir = Path.join(System.tmp_dir!(), "memory-test-#{System.unique_integer([:positive])}")
    project_id = "project-#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf(data_dir) end)
    %{data_dir: data_dir, project_id: project_id}
  end

  defp memory_path(data_dir, project_id),
    do: Path.join([data_dir, "projects", project_id, "memory.jsonl"])

  defp start(context, overrides \\ []) do
    start_supervised!(
      {Memory, [project_id: context.project_id, data_dir: context.data_dir] ++ overrides}
    )
  end

  test "a memory is written, listed as an index entry and fully readable by id", context do
    start(context)

    assert {:ok, entry} =
             Memory.put(context.project_id, %{
               id: "feedback_style",
               type: "feedback",
               description: "Prefers terse responses",
               content: "Don't summarize after every response."
             })

    assert entry.id == "feedback_style"

    assert {:ok, [index]} = Memory.list(context.project_id)
    assert index.id == "feedback_style"
    assert index.type == "feedback"
    refute Map.has_key?(index, :content)

    assert {:ok, full} = Memory.fetch(context.project_id, "feedback_style")
    assert full.content == "Don't summarize after every response."
  end

  test "an id is derived from the description when none is given", context do
    start(context)

    assert {:ok, entry} =
             Memory.put(context.project_id, %{
               type: "project",
               description: "Merge freeze starts Friday",
               content: "Flag any non-critical PR work scheduled after that date."
             })

    assert entry.id == "merge_freeze_starts_friday"
  end

  test "repeated puts to the same id upsert instead of appending forever", context do
    start(context)

    for version <- 1..20 do
      assert {:ok, _} =
               Memory.put(context.project_id, %{
                 id: "user_role",
                 type: "user",
                 description: "User's role",
                 content: "version #{version}"
               })
    end

    lines =
      context.data_dir
      |> memory_path(context.project_id)
      |> File.read!()
      |> String.split("\n", trim: true)

    assert length(lines) == 1

    assert {:ok, entry} = Memory.fetch(context.project_id, "user_role")
    assert entry.content == "version 20"
  end

  test "forget removes an entry and it no longer appears in the index", context do
    start(context)

    assert {:ok, _} =
             Memory.put(context.project_id, %{
               type: "reference",
               description: "Bugs tracked in Linear project INGEST",
               content: "Pipeline bugs live in the INGEST Linear project."
             })

    assert {:ok, [_entry]} = Memory.list(context.project_id)
    assert :ok = Memory.forget(context.project_id, "bugs_tracked_in_linear_project_ingest")
    assert {:ok, []} = Memory.list(context.project_id)

    assert {:error, :unknown_memory} =
             Memory.forget(context.project_id, "bugs_tracked_in_linear_project_ingest")
  end

  test "rejects an invalid type, and missing description/content", context do
    start(context)

    assert {:error, {:invalid_memory_type, "vibes"}} =
             Memory.put(context.project_id, %{
               id: "x",
               type: "vibes",
               description: "d",
               content: "c"
             })

    assert {:error, :invalid_memory_content} =
             Memory.put(context.project_id, %{
               id: "x",
               type: "user",
               description: "d",
               content: ""
             })
  end

  test "a new entry is rejected once the configured entry cap is reached", context do
    start(context, memory_max_entries: 2)

    for n <- 1..2 do
      assert {:ok, _} =
               Memory.put(context.project_id, %{
                 id: "m#{n}",
                 type: "user",
                 description: "d#{n}",
                 content: "c#{n}"
               })
    end

    assert {:error, :memory_entry_limit_reached} =
             Memory.put(context.project_id, %{
               id: "m3",
               type: "user",
               description: "d3",
               content: "c3"
             })

    # Updating an existing entry still succeeds even while at the cap.
    assert {:ok, _} =
             Memory.put(context.project_id, %{
               id: "m1",
               type: "user",
               description: "d1",
               content: "updated"
             })
  end

  test "an oversized entry is rejected by the byte cap", context do
    start(context, memory_max_bytes: 100)

    assert {:error, :memory_byte_limit_reached} =
             Memory.put(context.project_id, %{
               id: "big",
               type: "user",
               description: "d",
               content: String.duplicate("x", 200)
             })
  end

  test "memory writes are refused while disabled, but reads still work", context do
    start(context, memory_enabled: false)

    assert {:error, :memory_disabled} =
             Memory.put(context.project_id, %{
               id: "x",
               type: "user",
               description: "d",
               content: "c"
             })

    assert {:ok, []} = Memory.list(context.project_id)
  end

  test "a prior process's history is already compacted on init", context do
    path = memory_path(context.data_dir, context.project_id)
    File.mkdir_p!(Path.dirname(path))

    entries =
      for version <- 1..5 do
        JSON.encode!(%{
          "id" => "note",
          "type" => "project",
          "description" => "d",
          "content" => "version #{version}",
          "links" => [],
          "created_at" => "2026-01-01T00:00:00Z",
          "updated_at" => "2026-01-01T00:00:00Z"
        })
      end

    File.write!(path, Enum.map(entries, &(&1 <> "\n")))
    start(context)

    lines = path |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 1
    assert {:ok, entry} = Memory.fetch(context.project_id, "note")
    assert entry.content == "version 5"
  end
end
