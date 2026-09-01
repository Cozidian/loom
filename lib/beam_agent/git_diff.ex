defmodule BeamAgent.GitDiff do
  @moduledoc """
  Read-only working-tree inspection backed by fixed Git plumbing commands.

  `summary/1` is the cheap variant for status displays. `inspect/2` adds
  per-file statistics and, unless disabled, parsed hunks for rendering.
  """

  import Kernel, except: [inspect: 1, inspect: 2]

  alias BeamAgent.UnifiedDiff

  @spec summary(String.t()) ::
          {:ok,
           %{
             branch: String.t() | nil,
             changed_file_count: non_neg_integer(),
             insertions: non_neg_integer(),
             deletions: non_neg_integer()
           }}
          | {:error, term()}
  def summary(workspace_root) when is_binary(workspace_root) do
    with {:ok, status} <- git(workspace_root, ["status", "--porcelain=v1", "--branch"]),
         {:ok, numstat} <- git(workspace_root, ["diff", "--no-ext-diff", "--numstat", "HEAD"]) do
      stats = numstat_stats(numstat)

      {:ok,
       %{
         branch: branch(status),
         changed_file_count: status |> porcelain_statuses() |> map_size(),
         insertions: stats |> Map.values() |> Enum.map(& &1.insertions) |> Enum.sum(),
         deletions: stats |> Map.values() |> Enum.map(& &1.deletions) |> Enum.sum()
       }}
    end
  end

  @spec inspect(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect(workspace_root, opts \\ []) when is_binary(workspace_root) and is_list(opts) do
    hunks? = Keyword.get(opts, :hunks?, true)

    with {:ok, scope} <- scope(Keyword.get(opts, :path)),
         {:ok, status} <- git(workspace_root, ["status", "--porcelain=v1", "--branch"] ++ scope),
         {:ok, numstat} <-
           git(workspace_root, ["diff", "--no-ext-diff", "--numstat", "HEAD"] ++ scope),
         statuses = porcelain_statuses(status),
         {:ok, patch} <- patch(workspace_root, scope, statuses, hunks?) do
      stats = numstat_stats(numstat)

      changed_files =
        statuses
        |> Enum.map(fn {path, file_status} ->
          entry(workspace_root, path, file_status, Map.get(stats, path))
        end)
        |> Enum.sort_by(& &1.path)

      {:ok,
       %{
         branch: branch(status),
         changed_files: changed_files,
         files: files(patch, statuses, stats)
       }}
    end
  end

  defp entry(workspace_root, path, "untracked", _stats) do
    %{
      path: path,
      status: "untracked",
      insertions: untracked_insertions(workspace_root, path),
      deletions: 0,
      binary: false
    }
  end

  defp entry(_workspace_root, path, file_status, nil),
    do: %{path: path, status: file_status, insertions: 0, deletions: 0, binary: false}

  defp entry(_workspace_root, path, file_status, stats),
    do: Map.merge(stats, %{path: path, status: file_status})

  defp files(nil, _statuses, _stats), do: %{}

  defp files(patch, statuses, stats) do
    patch
    |> UnifiedDiff.split()
    |> Map.new(fn raw ->
      [parsed] = UnifiedDiff.parse(raw)
      numbers = Map.get(stats, parsed.file, %{insertions: 0, deletions: 0, binary: parsed.binary})

      {parsed.file,
       %{
         status: Map.get(statuses, parsed.file, parsed.status),
         insertions: numbers.insertions,
         deletions: numbers.deletions,
         binary: parsed.binary,
         hunks: parsed.hunks,
         raw_patch: raw
       }}
    end)
  end

  defp patch(_workspace_root, _scope, _statuses, false), do: {:ok, nil}

  # `git diff HEAD` never shows untracked files — they have no HEAD side to
  # compare against — so a brand-new file (exactly what an agent commonly
  # creates) would otherwise report "no diff" instead of its content. Diff
  # each untracked path against /dev/null and append those sections, giving
  # UnifiedDiff.parse/1 the same "new file mode" shape it already handles
  # for git-tracked additions.
  defp patch(workspace_root, scope, statuses, true) do
    with {:ok, tracked} <- git(workspace_root, ["diff", "--no-ext-diff", "HEAD"] ++ scope) do
      untracked =
        statuses
        |> Enum.filter(fn {_path, status} -> status == "untracked" end)
        |> Enum.map_join(fn {path, _status} -> untracked_patch(workspace_root, path) end)

      {:ok, tracked <> untracked}
    end
  end

  defp untracked_patch(workspace_root, path) do
    case System.cmd("git", ["diff", "--no-ext-diff", "--no-index", "--", "/dev/null", path],
           cd: workspace_root,
           stderr_to_stdout: true
         ) do
      {output, exit_code} when exit_code in [0, 1] -> output
      _other -> ""
    end
  rescue
    _error -> ""
  end

  defp scope(nil), do: {:ok, []}

  defp scope(path) when is_binary(path) and path != "" do
    if Path.type(path) == :absolute or ".." in Path.split(path),
      do: {:error, :path_escapes_workspace},
      else: {:ok, ["--", path]}
  end

  defp scope(_path), do: {:error, :invalid_git_path}

  defp git(workspace_root, args) do
    case System.cmd("git", args, cd: workspace_root, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, status} -> {:error, {:git_command_failed, Enum.at(args, 0), status}}
    end
  rescue
    error -> {:error, {:git_command_failed, Exception.message(error)}}
  end

  defp branch(status) do
    status
    |> String.split("\n")
    |> Enum.find_value(fn
      "## " <> rest ->
        rest
        |> String.replace_prefix("No commits yet on ", "")
        |> String.split("...")
        |> List.first()
        |> String.trim()

      _line ->
        nil
    end)
  end

  defp porcelain_statuses(status) do
    status
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "## "))
    |> Map.new(fn line ->
      path =
        line
        |> String.slice(3..-1//1)
        |> String.split(" -> ")
        |> List.last()

      {path, porcelain_status(String.slice(line, 0..1))}
    end)
  end

  defp porcelain_status("??"), do: "untracked"

  defp porcelain_status(code) do
    cond do
      String.contains?(code, "R") -> "renamed"
      String.contains?(code, "C") -> "copied"
      String.contains?(code, "A") -> "added"
      String.contains?(code, "D") -> "deleted"
      true -> "modified"
    end
  end

  defp numstat_stats(numstat) do
    numstat
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [insertions, deletions, path] = String.split(line, "\t", parts: 3)

      {numstat_path(path),
       %{
         insertions: numstat_count(insertions),
         deletions: numstat_count(deletions),
         binary: insertions == "-"
       }}
    end)
  end

  defp numstat_count("-"), do: 0
  defp numstat_count(value), do: String.to_integer(value)

  # Rename-detected numstat rows carry the source and target together, either as
  # "old => new" or brace-compacted as "dir/{old => new}/file".
  defp numstat_path(path) do
    cond do
      not String.contains?(path, " => ") ->
        path

      match = Regex.run(~r/^(.*)\{(.*) => (.*)\}(.*)$/, path) ->
        [_all, prefix, _old, new, suffix] = match
        String.replace(prefix <> new <> suffix, "//", "/")

      true ->
        path |> String.split(" => ") |> List.last()
    end
  end

  defp untracked_insertions(workspace_root, path) do
    full = Path.join(workspace_root, path)

    if within?(workspace_root, full) do
      case File.read(full) do
        {:ok, ""} -> 0
        {:ok, contents} -> line_count(contents)
        {:error, _reason} -> 0
      end
    else
      0
    end
  end

  defp within?(workspace_root, path),
    do: String.starts_with?(Path.expand(path), Path.expand(workspace_root) <> "/")

  defp line_count(contents) do
    newlines = length(:binary.matches(contents, "\n"))
    if String.ends_with?(contents, "\n"), do: newlines, else: newlines + 1
  end
end
