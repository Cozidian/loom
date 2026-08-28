defmodule BeamAgent.GitDiffTest do
  use ExUnit.Case, async: true

  alias BeamAgent.GitDiff

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "beam-agent-git-diff-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    File.write!(Path.join(workspace, "kept.txt"), "one\ntwo\nthree\n")
    File.write!(Path.join(workspace, "removed.txt"), "gone\n")

    {_output, 0} =
      System.cmd("git", ["init", "--initial-branch=main"], cd: workspace, stderr_to_stdout: true)

    {_output, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    {_output, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: workspace)
    {_output, 0} = System.cmd("git", ["add", "."], cd: workspace)

    {_output, 0} =
      System.cmd("git", ["commit", "-m", "initial"], cd: workspace, stderr_to_stdout: true)

    %{workspace: workspace}
  end

  test "summary reports the branch and aggregate line counts", %{workspace: workspace} do
    File.write!(Path.join(workspace, "kept.txt"), "one\nTWO\nthree\nfour\n")
    File.rm!(Path.join(workspace, "removed.txt"))
    File.write!(Path.join(workspace, "fresh.txt"), "a\nb\n")

    assert {:ok, summary} = GitDiff.summary(workspace)
    assert summary.branch == "main"
    assert summary.changed_file_count == 3
    assert summary.insertions == 2
    assert summary.deletions == 2
  end

  test "inspect returns per-file stats and parsed hunks", %{workspace: workspace} do
    File.write!(Path.join(workspace, "kept.txt"), "one\nTWO\nthree\n")

    assert {:ok, result} = GitDiff.inspect(workspace)
    assert result.branch == "main"

    assert [%{path: "kept.txt", status: "modified", insertions: 1, deletions: 1, binary: false}] =
             result.changed_files

    assert %{"kept.txt" => file} = result.files
    assert file.status == "modified"
    assert file.insertions == 1
    assert file.deletions == 1
    assert file.raw_patch =~ "diff --git a/kept.txt b/kept.txt"

    assert [%{lines: lines}] = file.hunks

    assert lines == [
             %{kind: :context, old_line: 1, new_line: 1, text: "one"},
             %{kind: :remove, old_line: 2, new_line: nil, text: "two"},
             %{kind: :add, old_line: nil, new_line: 2, text: "TWO"},
             %{kind: :context, old_line: 3, new_line: 3, text: "three"}
           ]
  end

  test "untracked files are counted from disk without staging them", %{workspace: workspace} do
    File.write!(Path.join(workspace, "fresh.txt"), "a\nb\nc\n")

    assert {:ok, result} = GitDiff.inspect(workspace)

    assert [%{path: "fresh.txt", status: "untracked", insertions: 3, deletions: 0}] =
             result.changed_files

    {status, 0} = System.cmd("git", ["status", "--porcelain=v1"], cd: workspace)
    assert status =~ "?? fresh.txt"
  end

  test "untracked files still produce a full add-only diff against /dev/null", %{
    workspace: workspace
  } do
    File.write!(Path.join(workspace, "fresh.txt"), "a\nb\nc\n")

    assert {:ok, result} = GitDiff.inspect(workspace, hunks?: true)

    assert %{"fresh.txt" => file} = result.files
    assert file.status == "untracked"
    assert file.binary == false
    assert [%{header: "@@ -0,0 +1,3 @@", lines: lines}] = file.hunks

    assert lines == [
             %{kind: :add, old_line: nil, new_line: 1, text: "a"},
             %{kind: :add, old_line: nil, new_line: 2, text: "b"},
             %{kind: :add, old_line: nil, new_line: 3, text: "c"}
           ]

    {status, 0} = System.cmd("git", ["status", "--porcelain=v1"], cd: workspace)
    assert status =~ "?? fresh.txt"
  end

  test "deletions and additions are reported with their status", %{workspace: workspace} do
    File.rm!(Path.join(workspace, "removed.txt"))
    File.write!(Path.join(workspace, "added.txt"), "new\n")
    {_output, 0} = System.cmd("git", ["add", "added.txt"], cd: workspace)

    assert {:ok, result} = GitDiff.inspect(workspace)

    by_path = Map.new(result.changed_files, &{&1.path, &1})
    assert by_path["removed.txt"].status == "deleted"
    assert by_path["removed.txt"].deletions == 1
    assert by_path["added.txt"].status == "added"
    assert by_path["added.txt"].insertions == 1

    assert result.files["removed.txt"].hunks != []
    assert result.files["added.txt"].hunks != []
  end

  test "renamed files resolve to their target path", %{workspace: workspace} do
    {_output, 0} = System.cmd("git", ["mv", "kept.txt", "renamed.txt"], cd: workspace)

    assert {:ok, result} = GitDiff.inspect(workspace)

    assert [%{path: "renamed.txt", status: "renamed"}] = result.changed_files
    assert %{"renamed.txt" => %{status: "renamed"}} = result.files
  end

  test "binary files are flagged and carry no hunks", %{workspace: workspace} do
    File.write!(Path.join(workspace, "blob.bin"), <<0, 1, 2, 3, 0, 255>>)
    {_output, 0} = System.cmd("git", ["add", "blob.bin"], cd: workspace)

    assert {:ok, result} = GitDiff.inspect(workspace)

    assert [%{path: "blob.bin", status: "added", binary: true, insertions: 0, deletions: 0}] =
             result.changed_files

    assert result.files["blob.bin"].binary
    assert result.files["blob.bin"].hunks == []
  end

  test "hunks? false skips the expensive patch generation", %{workspace: workspace} do
    File.write!(Path.join(workspace, "kept.txt"), "one\nTWO\nthree\n")

    assert {:ok, result} = GitDiff.inspect(workspace, hunks?: false)
    assert [%{path: "kept.txt", insertions: 1, deletions: 1}] = result.changed_files
    assert result.files == %{}
  end

  test "path scoping limits the result to one file", %{workspace: workspace} do
    File.write!(Path.join(workspace, "kept.txt"), "one\nTWO\nthree\n")
    File.write!(Path.join(workspace, "removed.txt"), "changed\n")

    assert {:ok, result} = GitDiff.inspect(workspace, path: "kept.txt")
    assert Enum.map(result.changed_files, & &1.path) == ["kept.txt"]
    assert Map.keys(result.files) == ["kept.txt"]
  end

  test "paths that escape the workspace are rejected", %{workspace: workspace} do
    assert {:error, :path_escapes_workspace} = GitDiff.inspect(workspace, path: "../secrets")
    assert {:error, :path_escapes_workspace} = GitDiff.inspect(workspace, path: "/etc/passwd")
    assert {:error, :invalid_git_path} = GitDiff.inspect(workspace, path: "")
  end

  test "a clean tree reports no changes", %{workspace: workspace} do
    assert {:ok, summary} = GitDiff.summary(workspace)
    assert summary.changed_file_count == 0
    assert summary.insertions == 0
    assert summary.deletions == 0

    assert {:ok, result} = GitDiff.inspect(workspace)
    assert result.changed_files == []
    assert result.files == %{}
  end

  test "a directory that is not a git repository returns an error" do
    plain =
      Path.join(System.tmp_dir!(), "beam-agent-not-git-#{System.unique_integer([:positive])}")

    File.mkdir_p!(plain)
    on_exit(fn -> File.rm_rf(plain) end)

    assert {:error, {:git_command_failed, "status", _status}} = GitDiff.summary(plain)
  end
end
