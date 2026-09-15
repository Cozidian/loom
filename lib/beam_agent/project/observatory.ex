defmodule BeamAgent.Project.Observatory do
  @moduledoc """
  Read-only architectural telemetry for one workspace: commit churn, file
  co-change coupling, a bounded dependency inventory, best-effort CI/CD
  discovery, and a composite risk score per hotspot file.

  Every input is bounded (commit count, node/edge count, library count) so a
  huge repository degrades to a smaller honest picture rather than a slow or
  unbounded one. Nothing here mutates the workspace or the runtime; it is a
  pure projection over `git log`, a handful of manifest files, and the
  existing `RepositoryIndex` snapshot.
  """

  alias BeamAgent.Project.RepositoryIndex

  @commit_limit 200
  @noisy_commit_files 50
  @top_files 40
  @top_edges 80
  @top_libraries 250
  @top_risks 12

  @spec snapshot(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def snapshot(project_id, opts \\ []) do
    with {:ok, repository} <- RepositoryIndex.refresh(project_id) do
      root = repository.workspace_root
      commits = git_log(root, Keyword.get(opts, :commit_limit, @commit_limit))
      hotspots = hotspots(commits, repository.files)
      hotspot_paths = MapSet.new(hotspots, & &1.path)

      {:ok,
       %{
         generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
         workspace_root: root,
         head: repository.git.head,
         dirty: repository.git.dirty,
         file_count: repository.file_count,
         worktree_changes: repository.git.changed_paths,
         commits_sampled: length(commits),
         languages: language_breakdown(repository.files),
         constellation: %{
           nodes: hotspots,
           edges: coupling_edges(commits, hotspot_paths)
         },
         risk: risk_assessment(hotspots),
         libraries: dependency_inventory(root),
         ci: ci_discovery(root)
       }}
    end
  end

  defp git_log(root, limit) do
    if File.exists?(Path.join(root, ".git")) do
      case System.cmd(
             "git",
             [
               "log",
               "--no-merges",
               "-n",
               to_string(limit),
               "--pretty=format:%x01%H",
               "--name-only"
             ],
             cd: root,
             stderr_to_stdout: true
           ) do
        {output, 0} -> output |> String.split(<<1>>, trim: true) |> Enum.map(&parse_commit/1)
        _failed -> []
      end
    else
      []
    end
  rescue
    _error -> []
  end

  defp parse_commit(block) do
    case String.split(block, "\n", trim: false) do
      [hash | rest] ->
        files = rest |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
        %{hash: String.trim(hash), files: files}

      [] ->
        %{hash: "", files: []}
    end
  end

  # Merge/mass-rename commits touch far more files than any real change and
  # would swamp both the hotspot counts and the co-change graph with noise.
  defp significant_commits(commits),
    do: Enum.reject(commits, &(length(&1.files) > @noisy_commit_files or &1.files == []))

  defp hotspots(commits, files) do
    significant_commits(commits)
    |> Enum.flat_map(& &1.files)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_path, count} -> -count end)
    |> Enum.take(@top_files)
    |> Enum.map(fn {path, count} -> hotspot_row(path, count, Map.get(files, path)) end)
  end

  defp hotspot_row(path, commits, nil) do
    %{path: path, commits: commits, size: 0, language: language_for(path), has_test: false}
  end

  defp hotspot_row(path, commits, file) do
    %{
      path: path,
      commits: commits,
      size: file.size,
      language: file.language,
      has_test: file.test_relationships != []
    }
  end

  defp language_for(path) do
    case Path.extname(path) do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".go" -> "go"
      ".js" -> "javascript"
      ".jsx" -> "javascript"
      ".ts" -> "typescript"
      ".tsx" -> "typescript"
      ".py" -> "python"
      ".rs" -> "rust"
      _other -> "text"
    end
  end

  defp coupling_edges(commits, hotspot_paths) do
    significant_commits(commits)
    |> Enum.reduce(%{}, fn commit, tallies ->
      touched = commit.files |> Enum.filter(&MapSet.member?(hotspot_paths, &1)) |> Enum.uniq()

      for a <- touched, b <- touched, a < b, reduce: tallies do
        acc -> Map.update(acc, {a, b}, 1, &(&1 + 1))
      end
    end)
    |> Enum.sort_by(fn {_pair, weight} -> -weight end)
    |> Enum.take(@top_edges)
    |> Enum.map(fn {{a, b}, weight} -> %{source: a, target: b, weight: weight} end)
  end

  defp language_breakdown(files) do
    files
    |> Map.values()
    |> Enum.frequencies_by(& &1.language)
    |> Enum.sort_by(fn {_language, count} -> -count end)
    |> Enum.map(fn {language, count} -> %{language: language, files: count} end)
  end

  defp risk_assessment(hotspots) do
    max_commits = hotspots |> Enum.map(& &1.commits) |> Enum.max(fn -> 1 end) |> max(1)
    max_size = hotspots |> Enum.map(& &1.size) |> Enum.max(fn -> 1 end) |> max(1)

    hotspots
    |> Enum.map(fn hotspot ->
      churn = hotspot.commits / max_commits
      bulk = hotspot.size / max_size
      test_gap = if hotspot.has_test, do: 0.0, else: 0.35
      score = min(churn * 0.5 + bulk * 0.25 + test_gap, 1.0)

      %{
        path: hotspot.path,
        score: Float.round(score * 10, 1),
        reasons: risk_reasons(hotspot, churn, bulk)
      }
    end)
    |> Enum.sort_by(&(-&1.score))
    |> Enum.take(@top_risks)
  end

  defp risk_reasons(hotspot, churn, bulk) do
    []
    |> maybe_reason(churn > 0.5, "high churn (#{hotspot.commits} sampled commits)")
    |> maybe_reason(bulk > 0.5, "large file (#{format_bytes(hotspot.size)})")
    |> maybe_reason(not hotspot.has_test, "no matching test file found")
    |> Enum.reverse()
  end

  defp maybe_reason(reasons, true, reason), do: [reason | reasons]
  defp maybe_reason(reasons, false, _reason), do: reasons

  defp format_bytes(bytes) when bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_bytes(bytes) when bytes >= 1_024, do: "#{Float.round(bytes / 1_024, 1)} KB"
  defp format_bytes(bytes), do: "#{bytes} B"

  defp dependency_inventory(root) do
    (mix_lock(Path.join(root, "mix.lock")) ++
       npm_lock(root) ++
       cargo_lock(Path.join(root, "Cargo.lock")) ++
       go_sum(Path.join(root, "go.sum")))
    |> Enum.take(@top_libraries)
  end

  defp mix_lock(path) do
    with {:ok, content} <- File.read(path) do
      ~r/"([a-zA-Z0-9_]+)":\s*\{:(hex|git),\s*:[a-zA-Z0-9_.]+,\s*"([^"]+)"/
      |> Regex.scan(content)
      |> Enum.map(fn [_, name, kind, version] ->
        %{name: name, version: version, ecosystem: "hex", kind: kind}
      end)
    else
      _ -> []
    end
  end

  defp npm_lock(root) do
    lock_path = Path.join(root, "package-lock.json")
    manifest_path = Path.join(root, "package.json")

    with {:ok, content} <- File.read(lock_path),
         {:ok, %{"packages" => packages}} <- JSON.decode(content) do
      packages
      |> Enum.reject(fn {path, _} -> path == "" end)
      |> Enum.map(fn {path, data} ->
        %{
          name: data["name"] || Path.basename(path),
          version: data["version"] || "unresolved",
          ecosystem: "npm",
          kind: if(data["dev"], do: "dev", else: "prod")
        }
      end)
    else
      _ -> npm_manifest(manifest_path)
    end
  end

  defp npm_manifest(path) do
    with {:ok, content} <- File.read(path),
         {:ok, manifest} <- JSON.decode(content) do
      for {kind, key} <- [{"prod", "dependencies"}, {"dev", "devDependencies"}],
          {name, version} <- manifest[key] || %{} do
        %{name: name, version: version, ecosystem: "npm", kind: kind}
      end
    else
      _ -> []
    end
  end

  defp cargo_lock(path) do
    with {:ok, content} <- File.read(path) do
      ~r/\[\[package\]\]\nname = "([^"]+)"\nversion = "([^"]+)"/
      |> Regex.scan(content)
      |> Enum.map(fn [_, name, version] ->
        %{name: name, version: version, ecosystem: "cargo", kind: "prod"}
      end)
    else
      _ -> []
    end
  end

  defp go_sum(path) do
    with {:ok, content} <- File.read(path) do
      content
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(&1, " "))
      |> Enum.flat_map(fn
        [module, version | _] -> [{module, String.trim_trailing(version, "/go.mod")}]
        _ -> []
      end)
      |> Enum.uniq()
      |> Enum.map(fn {module, version} ->
        %{name: module, version: version, ecosystem: "go", kind: "prod"}
      end)
    else
      _ -> []
    end
  end

  defp ci_discovery(root) do
    workflows = Path.join([root, ".github", "workflows"])

    case File.ls(workflows) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, [".yml", ".yaml"]))
        |> Enum.sort()
        |> Enum.map(&workflow_summary(Path.join(workflows, &1), &1))

      _error ->
        []
    end
  end

  defp workflow_summary(path, filename) do
    with {:ok, content} <- File.read(path) do
      %{
        file: filename,
        name: workflow_name(content, filename),
        jobs: workflow_jobs(content),
        triggers: workflow_triggers(content)
      }
    else
      _ -> %{file: filename, name: filename, jobs: [], triggers: []}
    end
  end

  defp workflow_name(content, filename) do
    case Regex.run(~r/^name:\s*(.+)$/m, content) do
      [_, name] -> name |> String.trim() |> String.trim("\"") |> String.trim("'")
      _ -> filename
    end
  end

  defp workflow_jobs(content) do
    case Regex.run(~r/^jobs:\s*$(.+)/ms, content) do
      [_, jobs_block] ->
        ~r/^  ([a-zA-Z0-9_-]+):\s*$/m
        |> Regex.scan(jobs_block)
        |> Enum.map(&Enum.at(&1, 1))
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp workflow_triggers(content) do
    case Regex.run(~r/^on:\s*\[([^\]]+)\]/m, content) do
      [_, inline] ->
        inline |> String.split(",") |> Enum.map(&String.trim/1)

      _ ->
        case Regex.run(~r/^on:\s*$(.+?)^\S/ms, content <> "\nEOF") do
          [_, block] ->
            ~r/^  ([a-zA-Z0-9_-]+):/m
            |> Regex.scan(block)
            |> Enum.map(&Enum.at(&1, 1))
            |> Enum.uniq()

          _ ->
            []
        end
    end
  end
end
