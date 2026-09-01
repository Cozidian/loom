defmodule BeamAgent.Goal.WorkspaceSnapshot do
  @moduledoc "Contract-scoped, filesystem-authoritative repository evidence."

  alias BeamAgent.Project.RepositoryIndex
  alias BeamAgent.Workspace

  def capture(project_id, opts \\ [])

  def capture(project_id, opts) when is_binary(project_id) and is_list(opts) do
    with {:ok, repository} <- RepositoryIndex.snapshot(project_id) do
      workspace_root = Keyword.get(opts, :workspace_root) || repository.workspace_root
      excluded_roots = Keyword.get(opts, :exclude, []) |> Enum.map(&canonical_path/1)
      runtime_data_root = opts[:data_dir] && canonical_path(opts[:data_dir])

      if git_repository?(workspace_root) do
        capture_git(repository, workspace_root, excluded_roots, runtime_data_root)
      else
        capture_index(project_id, workspace_root, excluded_roots, runtime_data_root)
      end
    end
  end

  def capture(_project_id, _opts), do: {:error, :invalid_project_id}

  def delta(%{files: before_files} = before, %{files: after_files} = current)
      when is_map(before_files) and is_map(after_files) do
    before_paths = Map.keys(before_files)
    after_paths = Map.keys(after_files)

    added = Enum.sort(after_paths -- before_paths)
    removed = Enum.sort(before_paths -- after_paths)

    modified =
      after_paths
      |> Enum.filter(fn path ->
        before_files[path] && before_files[path].hash != after_files[path].hash
      end)
      |> Enum.sort()

    entries =
      Enum.map(added, &entry(&1, :added, nil, after_files[&1])) ++
        Enum.map(modified, &entry(&1, :modified, before_files[&1], after_files[&1])) ++
        Enum.map(removed, &entry(&1, :removed, before_files[&1], nil))

    %{
      base_generation: before.generation,
      final_generation: current.generation,
      base_head: get_in(before, [:git, :head]),
      final_head: get_in(current, [:git, :head]),
      preexisting_dirty: get_in(before, [:git, :dirty]) == true,
      changed_files: Enum.map(entries, & &1.path),
      changes: entries,
      patch_fingerprint: fingerprint(entries)
    }
  end

  def delta(_before, _after), do: empty_delta()

  def empty_delta do
    %{
      base_generation: nil,
      final_generation: nil,
      base_head: nil,
      final_head: nil,
      preexisting_dirty: false,
      changed_files: [],
      changes: [],
      patch_fingerprint: fingerprint([])
    }
  end

  defp entry(path, change, before, current) do
    %{
      path: path,
      change: change,
      before_hash: before && before.hash,
      after_hash: current && current.hash,
      before_size: before && before.size,
      after_size: current && current.size
    }
  end

  defp fingerprint(entries) do
    entries
    |> Enum.map(&Map.take(&1, [:path, :change, :before_hash, :after_hash]))
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp capture_git(repository, workspace_root, excluded_roots, runtime_data_root) do
    with {:ok, changed} <- git_paths(workspace_root) do
      files =
        changed
        |> Enum.reject(&excluded?(workspace_root, &1, excluded_roots, runtime_data_root))
        |> Map.new(fn path -> {path, file_evidence(workspace_root, path)} end)

      {:ok,
       snapshot(repository, workspace_root, excluded_roots, runtime_data_root, files, %{
         head: git_output(workspace_root, ["rev-parse", "HEAD"]),
         dirty: map_size(files) > 0,
         changed_paths: map_size(files)
       })}
    end
  end

  defp capture_index(project_id, workspace_root, excluded_roots, runtime_data_root) do
    with {:ok, repository} <- RepositoryIndex.refresh(project_id) do
      files =
        repository.files
        |> Enum.reject(fn {path, _file} ->
          excluded?(workspace_root, path, excluded_roots, runtime_data_root)
        end)
        |> Map.new(fn {path, file} ->
          {path, Map.take(file, [:hash, :size, :modified_at])}
        end)

      {:ok,
       snapshot(
         repository,
         workspace_root,
         excluded_roots,
         runtime_data_root,
         files,
         repository.git
       )}
    end
  end

  defp snapshot(repository, workspace_root, excluded_roots, runtime_data_root, files, git) do
    %{
      generation: repository.generation,
      git: git,
      files: files,
      workspace_root: workspace_root,
      excluded_roots: excluded_roots,
      runtime_data_root: runtime_data_root,
      captured_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp git_paths(root) do
    with {tracked, 0} <-
           System.cmd("git", ["diff", "--name-only", "-z", "HEAD", "--"],
             cd: root,
             stderr_to_stdout: true
           ),
         {untracked, 0} <-
           System.cmd("git", ["ls-files", "--others", "--exclude-standard", "-z"],
             cd: root,
             stderr_to_stdout: true
           ) do
      {:ok, Enum.uniq(zero_paths(tracked) ++ zero_paths(untracked))}
    else
      {_output, status} -> {:error, {:git_snapshot_failed, status}}
    end
  end

  defp zero_paths(output), do: String.split(output, <<0>>, trim: true)

  defp file_evidence(root, path) do
    absolute = Path.join(root, path)

    case File.stat(absolute, time: :posix) do
      {:ok, stat} ->
        hash =
          case File.read(absolute) do
            {:ok, content} -> :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
            {:error, _reason} -> nil
          end

        %{hash: hash, size: stat.size, modified_at: stat.mtime}

      {:error, :enoent} ->
        %{hash: nil, size: nil, modified_at: nil}

      {:error, _reason} ->
        %{hash: nil, size: nil, modified_at: nil}
    end
  end

  defp git_output(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _failed -> nil
    end
  end

  defp git_repository?(root) do
    path = Path.join(root, ".git")
    File.dir?(path) or File.regular?(path)
  end

  defp excluded?(nil, _path, _excluded_roots, _runtime_data_root), do: false

  defp excluded?(workspace_root, path, excluded_roots, runtime_data_root) do
    absolute = Path.expand(path, workspace_root)

    Enum.any?(excluded_roots, &inside?(absolute, &1)) or
      runtime_path?(workspace_root, absolute, runtime_data_root)
  end

  defp runtime_path?(_workspace_root, _absolute, nil), do: false

  defp runtime_path?(workspace_root, absolute, runtime_data_root) do
    cond do
      runtime_data_root != workspace_root ->
        inside?(absolute, runtime_data_root)

      true ->
        case Path.relative_to(absolute, workspace_root) |> Path.split() do
          ["projects" | _rest] -> true
          ["session-" <> _suffix | _rest] -> true
          _other -> false
        end
    end
  end

  defp inside?(absolute, root),
    do: absolute == root or String.starts_with?(absolute, root <> "/")

  defp canonical_path(path) do
    case Workspace.canonical_path(path) do
      {:ok, canonical} -> canonical
      {:error, _reason} -> Path.expand(path)
    end
  end
end
