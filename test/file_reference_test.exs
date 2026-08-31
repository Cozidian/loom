defmodule BeamAgent.Session.FileReferenceTest do
  use ExUnit.Case, async: true

  alias BeamAgent.Session.FileReference

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-file-reference-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    nested = Path.join(workspace, "lib/nested")
    File.mkdir_p!(nested)

    File.write!(Path.join(workspace, "README.md"), "hello\nworld\n")
    File.write!(Path.join(nested, "with space.ex"), "defmodule Nested.WithSpace do\nend\n")
    File.write!(Path.join(workspace, "binary.bin"), <<255, 254, 253>>)
    File.write!(Path.join(root, "outside.txt"), "outside\n")

    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace}
  end

  test "resolves unquoted and quoted workspace file references", %{workspace: workspace} do
    assert {:ok, %{resolved: resolved, rejected: []}} =
             FileReference.resolve(
               ~s(Inspect @README.md and @"lib/nested/with space.ex"),
               workspace
             )

    assert Enum.map(resolved, & &1.path) == ["README.md", "lib/nested/with space.ex"]
    assert Enum.map(resolved, & &1.status) == ["resolved", "resolved"]
    assert Enum.at(resolved, 0).content == "hello\nworld\n"
    assert Enum.at(resolved, 0).line_count == 2
  end

  test "ignores escaped at signs and email addresses", %{workspace: workspace} do
    assert {:ok, %{resolved: [], rejected: []}} =
             FileReference.resolve("literal \\@README.md person@example.test", workspace)
  end

  test "rejects missing, escaped, and binary file references", %{workspace: workspace} do
    assert {:ok, %{resolved: [], rejected: rejected}} =
             FileReference.resolve("@missing.md @../outside.txt @binary.bin", workspace)

    assert Enum.map(rejected, &{&1.path, &1.reason}) == [
             {"missing.md", "file_not_found"},
             {"../outside.txt", "workspace_escape"},
             {"binary.bin", "binary_file"}
           ]
  end

  test "stores bounded immutable snapshots and lazily reports source drift", %{
    workspace: workspace
  } do
    data_dir = Path.join(workspace, "session-data")
    large = String.duplicate("abcdef", 20_000)
    File.write!(Path.join(workspace, "large.txt"), large)

    assert {:ok, %{resolved: [reference]}} =
             FileReference.resolve("inspect @large.txt", %{
               workspace_root: workspace,
               data_dir: data_dir,
               session_id: "snapshot-session"
             })

    refute Map.has_key?(reference, :content)
    assert reference.truncated
    assert reference.size_bytes == 64_000
    assert reference.source_size_bytes == byte_size(large)
    assert File.exists?(reference.snapshot_path)

    File.write!(Path.join(workspace, "large.txt"), "changed after reference resolution\n")
    rendered = FileReference.render_prompt("inspect @large.txt", [reference])

    assert rendered =~ ~s(status="changed")
    assert rendered =~ String.slice(large, 0, 100)
    refute rendered =~ "changed after reference resolution"

    public = FileReference.public(reference)
    refute Map.has_key?(public, :snapshot_path)
    refute Map.has_key?(public, :source_path)
    refute Map.has_key?(public, :content)
  end

  test "deduplicates canonical references and rejects secret-like files", %{workspace: workspace} do
    File.write!(Path.join(workspace, ".env"), "TOKEN=secret\n")

    assert {:ok, %{resolved: resolved, rejected: rejected}} =
             FileReference.resolve("@README.md @./README.md @.env", workspace)

    assert Enum.map(resolved, & &1.path) == ["README.md"]
    assert [%{path: ".env", reason: "secret_file"}] = rejected
  end

  test "enforces the worker path capability before reading", %{workspace: workspace} do
    envelope = BeamAgent.CapabilityEnvelope.root(%{paths: ["lib"], tools: :all})

    assert {:ok, %{resolved: [], rejected: [rejected]}} =
             FileReference.resolve("@README.md", %{
               workspace_root: workspace,
               capability_envelope: envelope
             })

    assert rejected.reason == "capability_denied"
  end
end
