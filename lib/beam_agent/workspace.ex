defmodule BeamAgent.Workspace do
  @moduledoc "Path resolution and containment for one immutable agent workspace."

  @max_symlink_hops 40

  def canonical_root(path) when is_binary(path) and path != "" do
    expanded = Path.expand(path)

    with {:ok, resolved} <- resolve_links(expanded, 0),
         {:ok, %File.Stat{type: :directory}} <- File.stat(resolved) do
      {:ok, resolved}
    else
      {:ok, %File.Stat{}} -> {:error, {:workspace_not_directory, expanded}}
      {:error, reason} -> {:error, {:invalid_workspace, expanded, reason}}
    end
  end

  def canonical_root(path), do: {:error, {:invalid_workspace, path}}

  def resolve(root, relative_path) when is_binary(relative_path) and relative_path != "" do
    if Path.type(relative_path) == :absolute do
      {:error, {:workspace_path_must_be_relative, relative_path}}
    else
      candidate = Path.expand(relative_path, root)

      with :ok <- ensure_inside(root, candidate),
           {:ok, resolved} <- resolve_links(candidate, 0),
           :ok <- ensure_inside(root, resolved) do
        {:ok, resolved}
      end
    end
  end

  def resolve(_root, path), do: {:error, {:invalid_workspace_path, path}}

  def relative(root, path), do: Path.relative_to(path, root)

  defp resolve_links(_path, hops) when hops > @max_symlink_hops,
    do: {:error, :too_many_symlinks}

  defp resolve_links(path, hops) do
    expanded = Path.expand(path)
    {prefix, parts} = split_absolute(expanded)
    walk_parts(prefix, parts, hops)
  end

  defp walk_parts(current, [], _hops), do: {:ok, current}

  defp walk_parts(current, [part | rest], hops) do
    candidate = Path.join(current, part)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(candidate) do
          target =
            if Path.type(target) == :absolute,
              do: target,
              else: Path.expand(target, Path.dirname(candidate))

          target
          |> append_parts(rest)
          |> resolve_links(hops + 1)
        end

      {:ok, _stat} ->
        walk_parts(candidate, rest, hops)

      {:error, :enoent} ->
        {:ok, append_parts(candidate, rest)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp split_absolute(path) do
    case Path.split(path) do
      [root | rest] -> {root, rest}
      [] -> {path, []}
    end
  end

  defp append_parts(path, []), do: path
  defp append_parts(path, parts), do: Path.join(path, Path.join(parts))

  defp ensure_inside(root, path) do
    relative = Path.relative_to(path, root)

    if relative == ".." or String.starts_with?(relative, "../") or
         String.starts_with?(relative, "..\\") or
         Path.type(relative) == :absolute do
      {:error, {:workspace_escape, path}}
    else
      :ok
    end
  end
end
