defmodule BeamAgent.Tools.ListFiles do
  @moduledoc false
  @behaviour BeamAgent.Tool

  alias BeamAgent.Tools.FileSupport
  alias BeamAgent.Workspace

  @impl true
  def name, do: "list_files"

  @impl true
  def description,
    do: "List files and directories inside the workspace without following directory symlinks."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        path: %{type: "string", description: "Workspace-relative directory; defaults to ."},
        depth: %{type: "integer", minimum: 1, maximum: 8},
        limit: %{type: "integer", minimum: 1, maximum: 1_000}
      }
    }
  end

  @impl true
  def access, do: :read

  @impl true
  def execute(arguments, context) do
    path = Map.get(arguments, "path", ".")
    depth = Map.get(arguments, "depth", 2)
    limit = Map.get(arguments, "limit", 200)

    with true <- is_integer(depth) and depth in 1..8,
         true <- is_integer(limit) and limit in 1..1_000,
         {:ok, target} <- FileSupport.resolve(context, path),
         {:ok, %File.Stat{type: :directory}} <- File.stat(target),
         {:ok, entries} <- walk(target, context.workspace_root, depth, limit) do
      {:ok, JSON.encode!(%{path: path, entries: entries, truncated: length(entries) == limit})}
    else
      false -> {:error, :invalid_list_options}
      {:ok, %File.Stat{type: type}} -> {:error, {:not_directory, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp walk(root, workspace, depth, limit) do
    do_walk([{root, 0}], workspace, depth, limit, [])
  end

  defp do_walk(_queue, _workspace, _depth, limit, entries) when length(entries) >= limit,
    do: {:ok, Enum.take(entries, limit)}

  defp do_walk([], _workspace, _depth, _limit, entries), do: {:ok, entries}

  defp do_walk([{directory, level} | queue], workspace, depth, limit, entries) do
    case File.ls(directory) do
      {:ok, names} ->
        {next, additions} =
          names
          |> Enum.sort()
          |> Enum.reduce({queue, []}, fn name, {pending, found} ->
            path = Path.join(directory, name)
            relative = Workspace.relative(workspace, path)

            case File.lstat(path) do
              {:ok, %File.Stat{type: :directory}} when level + 1 < depth ->
                {pending ++ [{path, level + 1}],
                 found ++ [%{path: relative <> "/", type: "directory"}]}

              {:ok, %File.Stat{type: type}} ->
                {pending, found ++ [%{path: relative, type: to_string(type)}]}

              {:error, _reason} ->
                {pending, found}
            end
          end)

        do_walk(next, workspace, depth, limit, entries ++ additions)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
