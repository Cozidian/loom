defmodule BeamAgent.Project.ObservatoryIntelligence do
  @moduledoc """
  Versioned, evidence-bearing repository model shared by people and agents.
  Directory roles and source references are heuristics, never runtime topology.
  Reading is bounded and contained in the workspace; no code is evaluated.
  """
  alias BeamAgent.{Workspace, Tools.FileSupport}
  @file_limit 600
  @source_limit 200_000
  @byte_budget 12_000_000
  @edge_limit 4_000
  @co_change_limit 2_000
  @noisy_commit_files 50
  @extensions ~w(.ts .tsx .js .jsx .mjs .ex .exs .py .go .rs .vue .svelte)

  def build(repository, commits, libraries, ci) do
    history = Enum.reverse(commits)
    churn = commits |> Enum.flat_map(& &1.files) |> Enum.frequencies()
    candidates = repository.files |> Map.values() |> Enum.reject(&sensitive?(&1.path))

    selected =
      candidates
      |> Enum.sort_by(&{-Map.get(churn, &1.path, 0), &1.path})
      |> Enum.take(@file_limit)
      |> Enum.filter(fn file ->
        match?({:ok, _}, Workspace.resolve(repository.workspace_root, file.path))
      end)

    {files, _remaining} =
      Enum.map_reduce(selected, @byte_budget, fn file, budget ->
        content = read_source(repository.workspace_root, file.path, budget)
        {describe(file, content, commits), budget - byte_size(content)}
      end)

    paths = MapSet.new(files, & &1.path)

    modules =
      files
      |> Enum.flat_map(fn f -> Enum.map(f.modules, &{&1, f.path}) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    references =
      for file <- files, ref <- file.references do
        targets = resolve(file.path, ref.target, paths, modules)

        %{
          source: file.path,
          target: List.first(targets),
          reference: ref.target,
          line: ref.line,
          kind: "import",
          confidence: if(length(targets) == 1, do: "static", else: "unresolved"),
          evidence: "#{file.path}:#{ref.line}",
          candidates: targets
        }
      end

    {resolved, unresolved} = Enum.split_with(references, &(&1.confidence == "static"))
    imports = Enum.take(resolved, @edge_limit)

    touchpoints_by_source =
      unresolved
      |> Enum.group_by(& &1.source)
      |> Map.new(fn {source, refs} -> {source, touchpoints(source, refs, libraries)} end)

    co_change = co_change_edges(commits, paths)
    co_change_by_file = co_change_partners(co_change)

    files =
      Enum.map(files, fn f ->
        matched = match_tests(f.path, paths)

        Map.merge(f, %{
          tests: matched,
          imports: Enum.count(imports, &(&1.source == f.path)),
          consumers: Enum.count(imports, &(&1.target == f.path)),
          unresolved: Enum.count(unresolved, &(&1.source == f.path)),
          external_touchpoints: Map.get(touchpoints_by_source, f.path, []),
          co_change: Map.get(co_change_by_file, f.path, [])
        })
        |> Map.delete(:references)
      end)

    components = components(files, imports)

    %{
      schema_version: 1,
      files: files,
      components: components,
      edges: imports,
      co_change: co_change,
      unresolved: Enum.take(unresolved, 300),
      timeline: Enum.map(history, &Map.take(&1, [:hash, :date, :author, :subject, :files])),
      dimensions: dimensions(files, imports, unresolved, ci),
      investigations: investigations(components),
      coverage: %{
        indexed_files: repository.file_count,
        modeled_files: length(files),
        omitted_files: max(repository.file_count - length(files), 0),
        source_files_read: Enum.count(files, & &1.source_read),
        file_limit: @file_limit,
        edge_limit: @edge_limit,
        edges_omitted: max(length(resolved) - @edge_limit, 0),
        unresolved_references: length(unresolved),
        history_commits: length(commits),
        topology: "current worktree",
        history: "sampled non-merge commits; not historical topology"
      },
      integrations: [
        %{
          id: "repository",
          state: "available",
          detail: "Current index, static references and sampled Git history"
        },
        %{
          id: "dependencies",
          state: "inventory only",
          detail: "#{length(libraries)} entries; no vulnerability or upgrade lookup"
        },
        %{
          id: "ci",
          state: "configuration only",
          detail: "#{length(ci)} workflow files; no run or coverage results"
        },
        %{
          id: "runtime",
          state: "not connected",
          detail: "No deployments, traces, incidents or cloud inventory"
        }
      ],
      limits: [
        "Layers and components are inferred from paths, not validated architectural boundaries.",
        "Import scans are lexical and partial: aliases, dynamic calls, generated code and runtime wiring may be missing.",
        "Test filename matches are candidate tests, not execution or coverage evidence.",
        "Commit activity is not complexity, ownership authority, defect rate or a forecast.",
        "No vulnerability scan or operational health check has run. No rewrite is recommended from churn alone.",
        "Co-change links count commits that touched two files together. This is correlation, not a runtime dependency or shared ownership.",
        "External touchpoints match unresolved import names against dependency manifests by name only. An unmatched name may be undeclared, a bundler path alias, or an internal file outside this model's file limit.",
        "Protocol matches are regex heuristics for common framework conventions (Phoenix/Plug, Express-style, Flask/FastAPI, Django). They are not a live route table and can miss or misread real endpoints."
      ]
    }
  end

  @doc "Find one shortest observed import path; this is not a runtime request trace."
  def trace(model, origin, destination) do
    starts =
      model.files
      |> Enum.filter(&(&1.path == origin or &1.component == origin))
      |> Enum.map(& &1.path)

    targets =
      model.files
      |> Enum.filter(&(&1.path == destination or &1.component == destination))
      |> Enum.map(& &1.path)
      |> MapSet.new()

    if starts == [] or MapSet.size(targets) == 0 do
      {:error, :unknown_observatory_target}
    else
      adjacency = Enum.group_by(model.edges, & &1.source)
      trace_walk(Enum.map(starts, &{&1, []}), MapSet.new(starts), targets, adjacency)
    end
  end

  defp trace_walk([], _seen, _targets, _adjacency),
    do:
      {:ok,
       %{
         found: false,
         evidence: [],
         confidence: "No path resolved in the partial static model; no runtime conclusion."
       }}

  defp trace_walk([{path, edges} | rest], seen, targets, adjacency) do
    cond do
      MapSet.member?(targets, path) ->
        {:ok,
         %{
           found: true,
           evidence: edges,
           confidence: "Observed lexical reference chain, not a runtime call trace."
         }}

      length(edges) >= 12 ->
        trace_walk(rest, seen, targets, adjacency)

      true ->
        next = Enum.reject(Map.get(adjacency, path, []), &MapSet.member?(seen, &1.target))
        seen = Enum.reduce(next, seen, &MapSet.put(&2, &1.target))
        trace_walk(rest ++ Enum.map(next, &{&1.target, edges ++ [&1]}), seen, targets, adjacency)
    end
  end

  def impact(model, target) do
    seeds =
      model.files
      |> Enum.filter(&(&1.path == target or &1.component == target))
      |> Enum.map(& &1.path)

    if seeds == [] do
      {:error, :unknown_observatory_target}
    else
      reached = walk(MapSet.new(seeds), MapSet.new(seeds), model.edges, 0)
      affected = model.files |> Enum.filter(&MapSet.member?(reached, &1.path))

      {:ok,
       %{
         target: target,
         seeds: seeds,
         affected: Enum.map(affected, & &1.path),
         downstream: Enum.reject(Enum.map(affected, & &1.path), &(&1 in seeds)),
         tests: affected |> Enum.flat_map(& &1.tests) |> Enum.uniq() |> Enum.sort(),
         components: affected |> Enum.map(& &1.component) |> Enum.uniq() |> Enum.sort(),
         security_paths: affected |> Enum.filter(& &1.security_sensitive) |> Enum.map(& &1.path),
         confidence: "partial static reachability",
         depth_limit: 12,
         unknowns: model.limits,
         evidence:
           Enum.filter(
             model.edges,
             &(MapSet.member?(reached, &1.source) and MapSet.member?(reached, &1.target))
           )
       }}
    end
  end

  defp walk(seen, _frontier, _edges, 12), do: seen

  defp walk(seen, frontier, edges, depth) do
    next =
      edges
      |> Enum.filter(&MapSet.member?(frontier, &1.target))
      |> Enum.map(& &1.source)
      |> MapSet.new()
      |> MapSet.difference(seen)

    if MapSet.size(next) == 0,
      do: seen,
      else: walk(MapSet.union(seen, next), next, edges, depth + 1)
  end

  defp read_source(root, path, budget) do
    if Path.extname(path) in @extensions and budget > 0 do
      with {:ok, full} <- Workspace.resolve(root, path),
           {:ok, content} <- FileSupport.read_text(full, min(budget, @source_limit)),
           do: content,
           else: (_ -> "")
    else
      ""
    end
  end

  @doc "Paths excluded from the model and from direct source reads: credentials, secrets, keys."
  def sensitive_path?(path),
    do:
      Regex.match?(
        ~r/(^|\/)(\.env(?:\.|$)|credentials(?:\.|$)|secrets?(?:\.|\/)|.*\.(pem|key|p12)$)/i,
        path
      )

  defp sensitive?(path), do: sensitive_path?(path)

  defp describe(file, content, commits) do
    touches = Enum.filter(commits, &(file.path in &1.files))

    authors =
      touches
      |> Enum.frequencies_by(& &1.author)
      |> Enum.sort_by(fn {name, count} -> {-count, name} end)

    role = role(file.path)

    refs =
      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, number} ->
        scans =
          Regex.scan(
            ~r/(?:\bfrom\s+["']([^"']+)["']|\b(?:import|require)\s*\(?\s*["']([^"']+)["']|^\s*(?:alias|use|import)\s+(?!\S+\s+from\s+["'])([A-Z][\w.]+)|^\s*from\s+([\w.]+)\s+import)/,
            line,
            capture: :all_but_first
          )

        Enum.flat_map(scans, fn groups ->
          groups |> Enum.reject(&(&1 == "")) |> Enum.map(&%{target: &1, line: number})
        end)
      end)
      |> Enum.uniq_by(& &1.target)
      |> Enum.take(80)

    modules =
      Regex.scan(~r/^\s*defmodule\s+([\w.]+)/m, content, capture: :all_but_first)
      |> List.flatten()

    %{
      path: file.path,
      component: component(file.path),
      layer: role,
      language: file.language,
      bytes: file.size,
      lines: if(content == "", do: nil, else: length(String.split(content, "\n"))),
      source_read: content != "",
      symbols: Enum.take(file.symbols, 24),
      modules: modules,
      references: refs,
      protocols: protocol_matches(file.path, content),
      commits: length(touches),
      authors: Enum.map(authors, fn {name, count} -> %{name: name, commits: count} end),
      last_changed:
        case touches do
          [first | _] -> first.date
          _ -> nil
        end,
      security_sensitive:
        Regex.match?(~r/auth|permission|policy|token|crypto|session|secret|login/i, file.path),
      diagnostics: Enum.map(file.diagnostics, &Map.take(&1, [:severity, :line, :column])),
      purpose: purpose(role),
      evidence: %{kind: "path inference", path: file.path}
    }
  end

  defp role(path) do
    cond do
      Regex.match?(
        ~r/(^|\/)(test[s]?|spec[s]?|__tests__|docs|evals)(\/|$)|(_test\.|\.test\.|\.spec\.|\.md$)/i,
        path
      ) ->
        "assurance"

      Regex.match?(
        ~r/(\.github|infra|deploy|terraform|Dockerfile|docker-compose|\.tf$|(^|\/)(config|scripts|ops)(\/|$))/,
        path
      ) ->
        "operations"

      Regex.match?(
        ~r/(^|\/)(data|db|database|schema|schemas|migrations|repo|storage|persistence)(\/|\.)|_repo\./,
        path
      ) ->
        "data"

      Regex.match?(
        ~r/(^|\/)(components|pages|ui|views|web|controllers|router|routes|api|public|static)(\/|\.)|(_controller|_router|_web|_view)\b/,
        path
      ) ->
        "interface"

      Regex.match?(
        ~r/(^|\/)(runtime|core|domain|engine|agent|session|goal|project|control_plane)(\/|\.)/,
        path
      ) ->
        "domain"

      true ->
        "application"
    end
  end

  defp purpose("interface"),
    do: "Likely an entry or presentation boundary. Trace inward before changing its contract."

  defp purpose("data"),
    do: "Likely persistence or schema code. Verify migrations and data compatibility."

  defp purpose("domain"),
    do: "Likely core behavior or lifecycle code. Confirm invariants with its consumers and tests."

  defp purpose("operations"),
    do: "Likely configuration or delivery machinery. Verify the actual deployment environment."

  defp purpose("assurance"),
    do: "Tests, documentation or evaluation evidence. Inspect what behavior it actually protects."

  defp purpose(_),
    do: "Application or supporting code. Its architectural role needs source-level investigation."

  defp component(path) do
    parts = Path.split(Path.dirname(path))

    case parts do
      ["."] -> "(root)"
      ["lib", app, group | _] -> "lib/#{app}/#{group}"
      ["cmd", app | _] -> "cmd/#{app}"
      ["src", group | _] -> "src/#{group}"
      ["test", group | _] -> "test/#{group}"
      [a, b | _] -> "#{a}/#{b}"
      [a] -> a
    end
  end

  defp resolve(source, reference, paths, modules) do
    module_paths = Map.get(modules, reference, [])

    cond do
      module_paths != [] ->
        Enum.uniq(module_paths)

      String.starts_with?(reference, ".") ->
        base =
          Path.expand(reference, Path.join("/", Path.dirname(source))) |> String.trim_leading("/")

        base = if Path.extname(base) in [".js", ".jsx"], do: Path.rootname(base), else: base

        candidates =
          [base] ++
            Enum.map(@extensions, &(base <> &1)) ++
            Enum.map(@extensions, &(base <> "/index" <> &1))

        Enum.filter(candidates, &MapSet.member?(paths, &1)) |> Enum.uniq()

      Path.extname(source) == ".py" ->
        base = String.replace(reference, ".", "/")
        Enum.filter([base <> ".py", base <> "/__init__.py"], &MapSet.member?(paths, &1))

      true ->
        []
    end
  end

  defp match_tests(path, paths) do
    if role(path) == "assurance" do
      []
    else
      stem = Path.rootname(path)
      base = Path.basename(stem)

      candidates = [
        String.replace_prefix(stem, "lib/", "test/") <> "_test.exs",
        stem <> ".test.ts",
        stem <> ".test.tsx",
        stem <> ".spec.ts",
        stem <> ".test.js",
        stem <> "_test.go",
        Path.join(Path.dirname(path), "test_#{base}.py")
      ]

      Enum.filter(candidates, &MapSet.member?(paths, &1))
    end
  end

  # Commits that touched two modeled files together. This is a correlation
  # signal (co-change), never promoted to a dependency edge.
  defp co_change_edges(commits, paths) do
    commits
    |> Enum.map(fn c -> c.files |> Enum.filter(&MapSet.member?(paths, &1)) |> Enum.uniq() end)
    |> Enum.reject(&(length(&1) > @noisy_commit_files or length(&1) < 2))
    |> Enum.reduce(%{}, fn touched, tallies ->
      for a <- touched, b <- touched, a < b, reduce: tallies do
        acc -> Map.update(acc, {a, b}, 1, &(&1 + 1))
      end
    end)
    |> Enum.sort_by(fn {_pair, weight} -> -weight end)
    |> Enum.take(@co_change_limit)
    |> Enum.map(fn {{a, b}, weight} -> %{source: a, target: b, commits: weight} end)
  end

  defp co_change_partners(co_change) do
    co_change
    |> Enum.reduce(%{}, fn %{source: a, target: b, commits: weight}, acc ->
      acc
      |> Map.update(a, [%{path: b, commits: weight}], &[%{path: b, commits: weight} | &1])
      |> Map.update(b, [%{path: a, commits: weight}], &[%{path: a, commits: weight} | &1])
    end)
    |> Map.new(fn {path, partners} ->
      {path, partners |> Enum.sort_by(&(-&1.commits)) |> Enum.take(12)}
    end)
  end

  # Unresolved, non-relative reference names compared against the declared
  # dependency inventory by name only -- never a real resolver or install check.
  defp touchpoints(source, refs, libraries) do
    library_index =
      libraries
      |> Enum.group_by(&String.downcase(&1.name))
      |> Map.new(fn {name, [lib | _]} -> {name, lib} end)

    refs
    |> Enum.map(&package_candidate(&1.reference, source))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(fn package ->
      case Map.get(library_index, String.downcase(package)) do
        nil -> %{package: package, declared: false, version: nil, ecosystem: nil}
        lib -> %{package: package, declared: true, version: lib.version, ecosystem: lib.ecosystem}
      end
    end)
    |> Enum.sort_by(&{not &1.declared, &1.package})
  end

  defp package_candidate(reference, _source) when reference in [nil, ""], do: nil

  defp package_candidate("." <> _, _source), do: nil

  defp package_candidate(reference, source) do
    cond do
      Path.extname(source) in ~w(.ex .exs) ->
        reference |> String.split(".") |> hd() |> Macro.underscore()

      Path.extname(source) == ".py" ->
        reference |> String.split(".") |> hd()

      true ->
        bare_package_name(reference)
    end
  end

  defp bare_package_name("@" <> _ = reference) do
    case String.split(reference, "/") do
      [scope, name | _] -> scope <> "/" <> name
      _ -> reference
    end
  end

  defp bare_package_name(reference), do: reference |> String.split("/") |> hd()

  # Regex heuristics per common framework convention. Not a live route table:
  # dynamic registration, mounted sub-routers and macros can hide real routes.
  defp protocol_matches(_path, "" = _content), do: []

  defp protocol_matches(path, content) do
    case Path.extname(path) do
      ext when ext in ~w(.ex .exs) -> phoenix_routes(content)
      ".py" -> python_routes(content)
      ext when ext in ~w(.js .jsx .ts .tsx .mjs .vue .svelte) -> js_routes(content)
      _ -> []
    end
    |> Enum.take(30)
  end

  defp phoenix_routes(content) do
    lines_with_index(content)
    |> Enum.flat_map(fn {line, number} ->
      case Regex.run(~r/^\s*(get|post|put|patch|delete|live|resources)\s+"([^"]+)"/, line) do
        [_, verb, path] ->
          [
            %{
              method: String.upcase(verb),
              path: path,
              framework: "phoenix/plug router",
              line: number
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp python_routes(content) do
    lines = lines_with_index(content)

    decorated =
      Enum.flat_map(lines, fn {line, number} ->
        case Regex.run(~r/@\w+\.(get|post|put|patch|delete)\(\s*["']([^"']+)["']/, line) do
          [_, verb, path] ->
            [%{method: String.upcase(verb), path: path, framework: "flask/fastapi", line: number}]

          _ ->
            case Regex.run(~r/@\w+\.route\(\s*["']([^"']+)["']/, line) do
              [_, path] -> [%{method: "ROUTE", path: path, framework: "flask", line: number}]
              _ -> []
            end
        end
      end)

    django =
      Enum.flat_map(lines, fn {line, number} ->
        case Regex.run(~r/\b(?:re_)?path\(\s*["']([^"']*)["']/, line) do
          [_, path] ->
            [
              %{
                method: "ROUTE",
                path: "/" <> String.trim_leading(path, "/"),
                framework: "django",
                line: number
              }
            ]

          _ ->
            []
        end
      end)

    decorated ++ django
  end

  defp js_routes(content) do
    lines_with_index(content)
    |> Enum.flat_map(fn {line, number} ->
      case Regex.run(
             ~r/\b(?:app|router|server)\.(get|post|put|patch|delete|head|options)\s*\(\s*['"`]([^'"`]+)['"`]/,
             line
           ) do
        [_, verb, path] ->
          [%{method: String.upcase(verb), path: path, framework: "express-style", line: number}]

        _ ->
          []
      end
    end)
  end

  defp lines_with_index(content), do: content |> String.split("\n") |> Enum.with_index(1)

  defp components(files, edges) do
    by_path = Map.new(files, &{&1.path, &1.component})

    files
    |> Enum.group_by(& &1.component)
    |> Enum.map(fn {id, members} ->
      paths = Enum.map(members, & &1.path)
      outgoing = Enum.filter(edges, &(&1.source in paths and &1.target not in paths))
      incoming = Enum.filter(edges, &(&1.target in paths and &1.source not in paths))

      layer =
        members
        |> Enum.frequencies_by(& &1.layer)
        |> Enum.sort_by(fn {l, n} -> {-n, l} end)
        |> hd()
        |> elem(0)

      %{
        id: id,
        name: Path.basename(id),
        layer: layer,
        files: paths,
        file_count: length(paths),
        bytes: Enum.sum(Enum.map(members, & &1.bytes)),
        commits: Enum.sum(Enum.map(members, & &1.commits)),
        test_matches: Enum.count(members, &(&1.tests != [])),
        security_paths: Enum.count(members, & &1.security_sensitive),
        consumers: incoming |> Enum.map(&by_path[&1.source]) |> Enum.uniq(),
        dependencies: outgoing |> Enum.map(&by_path[&1.target]) |> Enum.uniq(),
        unresolved: Enum.sum(Enum.map(members, & &1.unresolved)),
        purpose: purpose(layer),
        protocol_count: Enum.sum(Enum.map(members, &length(&1.protocols))),
        external_touchpoints:
          members
          |> Enum.flat_map(& &1.external_touchpoints)
          |> Enum.uniq_by(& &1.package)
          |> Enum.sort_by(&{not &1.declared, &1.package}),
        co_change_partners:
          members
          |> Enum.flat_map(& &1.co_change)
          |> Enum.map(fn %{path: p, commits: c} -> {by_path[p], c} end)
          |> Enum.reject(fn {other_id, _} -> other_id in [nil, id] end)
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
          |> Enum.map(fn {other_id, weights} -> %{id: other_id, commits: Enum.sum(weights)} end)
          |> Enum.sort_by(&(-&1.commits))
      }
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp dimensions(files, edges, unresolved, ci) do
    [
      %{
        id: "architecture",
        label: "Architecture",
        state: "partial",
        detail:
          "#{length(edges)} uniquely resolved static references; #{length(unresolved)} unresolved. Direction is consumer → dependency."
      },
      %{
        id: "tests",
        label: "Test confidence",
        state: "unknown",
        detail:
          "#{Enum.count(files, &(&1.tests != []))} files have matching test filenames. No tests were executed; coverage and assertions are unknown."
      },
      %{
        id: "security",
        label: "Security",
        state: "unverified",
        detail:
          "#{Enum.count(files, & &1.security_sensitive)} security-sensitive paths inferred by name. No vulnerabilities established or scanner run."
      },
      %{
        id: "operations",
        label: "Deployment safety",
        state: "unknown",
        detail:
          "#{length(ci)} workflow definitions discovered. Run results, rollback readiness and production topology are unknown."
      },
      %{
        id: "maintainability",
        label: "Maintainability",
        state: "signals only",
        detail:
          "File size, sampled authors and churn are available; domain complexity, dead code and ownership authority require investigation."
      },
      %{
        id: "documentation",
        label: "Documentation",
        state: "inventory only",
        detail:
          "#{Enum.count(files, &String.ends_with?(&1.path, ".md"))} Markdown files modeled. Accuracy and architectural drift are unverified."
      }
    ]
  end

  defp investigations(components) do
    components
    |> Enum.sort_by(&{-(length(&1.consumers) * 3 + &1.commits), &1.id})
    |> Enum.take(5)
    |> Enum.map(fn c ->
      %{
        target: c.id,
        title:
          if(length(c.consumers) > 0,
            do: "Verify the contract around #{c.name}",
            else: "Understand #{c.name} before changing it"
          ),
        evidence:
          "#{c.file_count} files · #{c.commits} sampled file touches · #{length(c.consumers)} observed consumer components · #{c.test_matches} test filename matches",
        next_step:
          "Read the boundary, inspect consumers, then run the matching tests. Preserve behavior before considering consolidation or a rewrite.",
        confidence: "investigation priority, not a defect finding"
      }
    end)
  end
end
