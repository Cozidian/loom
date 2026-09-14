defmodule BeamAgent.Project.RepositoryIndex do
  @moduledoc "Project-level reactive repository snapshot with generation-safe incremental analysis."
  use GenServer
  require Logger

  alias BeamAgent.Names
  alias BeamAgent.Project.ContextStore
  alias BeamAgent.Session.EventLog

  # A workspace outside version control has no `git ls-files` to bound the
  # scan, and a symlink cycle would otherwise recurse forever; cap the count
  # so a mistakenly huge or cyclic workspace degrades instead of growing
  # without bound.
  @max_files 20_000

  @ignored MapSet.new([
             ".git",
             ".beam_agent",
             ".agents",
             ".codex",
             ".tmp",
             "_build",
             "deps",
             ".elixir_ls",
             "node_modules",
             "coverage",
             "tmp"
           ])

  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:repository_index, project_id))
  end

  def refresh(project_id), do: call(project_id, :refresh, 30_000)
  def notify_change(project_id), do: cast(project_id, :refresh)
  def snapshot(project_id), do: call(project_id, :snapshot)
  def file(project_id, path), do: call(project_id, {:file, path})

  @impl true
  def init(opts) do
    state = %{
      project_id: Keyword.fetch!(opts, :project_id),
      workspace_root: Keyword.fetch!(opts, :workspace_root),
      generation: 0,
      files: %{},
      git: %{},
      last_refreshed_at: nil,
      scan_interval_ms: Keyword.get(opts, :repository_scan_interval_ms, 5_000),
      refresh_debounce_ms: Keyword.get(opts, :repository_refresh_debounce_ms, 100),
      max_files: Keyword.get(opts, :repository_max_files, @max_files),
      refresh_timer: nil,
      scan: nil
    }

    send(self(), :refresh)
    {:ok, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    {reply, state} = do_refresh(state)
    {:reply, reply, state}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, public_snapshot(state)}, state}

  def handle_call({:file, path}, _from, state) do
    case state.files[path] do
      nil -> {:reply, {:error, :unknown_repository_file}, state}
      file -> {:reply, {:ok, file}, state}
    end
  end

  @impl true
  def handle_cast(:refresh, state) do
    if state.refresh_timer do
      {:noreply, state}
    else
      timer = Process.send_after(self(), :debounced_refresh, state.refresh_debounce_ms)
      {:noreply, %{state | refresh_timer: timer}}
    end
  end

  @impl true
  def handle_info(:refresh, state) do
    state = start_background_refresh(state)
    Process.send_after(self(), :refresh, state.scan_interval_ms)
    {:noreply, state}
  end

  def handle_info(:debounced_refresh, state) do
    {:noreply, start_background_refresh(%{state | refresh_timer: nil})}
  end

  def handle_info(
        {:repository_scan_result, ref, generation, result},
        %{scan: %{ref: ref}} = state
      ) do
    Process.demonitor(state.scan.monitor, [:flush])

    state =
      if generation > state.generation do
        apply_scan_result(%{state | scan: nil}, generation, result)
      else
        %{state | scan: nil}
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{scan: %{monitor: monitor}} = state) do
    publish(state.project_id, :repository_refresh_failed, %{
      "failure_code" => reason_code({:repository_scan_exit, reason})
    })

    {:noreply, %{state | scan: nil}}
  end

  defp do_refresh(state) do
    generation = state.generation + 1

    result = scan(state.workspace_root, generation, state.files, state.max_files)
    state = apply_scan_result(state, generation, result)

    reply =
      case result do
        {:ok, _files, _git} -> {:ok, public_snapshot(state)}
        {:error, reason} -> {:error, reason}
      end

    {reply, state}
  end

  defp apply_scan_result(state, generation, result) do
    case result do
      {:ok, files, git} ->
        changes = diff(state.files, files)
        changed? = changes != %{added: [], changed: [], removed: []} or git != state.git

        state =
          if changed? do
            %{
              state
              | generation: generation,
                files: files,
                git: git,
                last_refreshed_at: DateTime.utc_now() |> DateTime.to_iso8601()
            }
          else
            %{state | last_refreshed_at: DateTime.utc_now() |> DateTime.to_iso8601()}
          end

        if changed? do
          persist_context(state)
          publish_changes(state, changes)
        end

        state

      {:error, reason} ->
        publish(state.project_id, :repository_refresh_failed, %{
          "failure_code" => reason_code(reason)
        })

        state
    end
  end

  defp start_background_refresh(%{scan: nil} = state) do
    owner = self()
    ref = make_ref()
    generation = state.generation + 1

    case Names.pid(:repository_scan_supervisor, state.project_id) do
      {:ok, supervisor} ->
        case Task.Supervisor.start_child(supervisor, fn ->
               send(
                 owner,
                 {:repository_scan_result, ref, generation,
                  scan(state.workspace_root, generation, state.files, state.max_files)}
               )
             end) do
          {:ok, pid} ->
            %{state | scan: %{ref: ref, pid: pid, monitor: Process.monitor(pid)}}

          {:error, reason} ->
            publish(state.project_id, :repository_refresh_failed, %{
              "failure_code" => reason_code(reason)
            })

            state
        end

      {:error, reason} ->
        publish(state.project_id, :repository_refresh_failed, %{
          "failure_code" => reason_code(reason)
        })

        state
    end
  end

  defp start_background_refresh(state), do: state

  defp scan(root, generation, previous, max_files) do
    files =
      root
      |> repository_paths(max_files)
      |> Enum.sort()
      |> Map.new(fn relative ->
        absolute = Path.join(root, relative)
        stat = File.stat!(absolute, time: :posix)
        previous_file = previous[relative]
        content = if stat.size <= 1_000_000, do: File.read!(absolute), else: ""
        content_hash = hash(content)

        file =
          if unchanged?(previous_file, stat, content_hash) do
            %{
              previous_file
              | generation: generation,
                modified_at: stat.mtime,
                size: stat.size
            }
          else
            %{
              path: relative,
              size: stat.size,
              modified_at: stat.mtime,
              hash: content_hash,
              generation: generation,
              language: language(relative),
              symbols: symbols(relative, content),
              dependencies: dependencies(relative, content),
              diagnostics: BeamAgent.Tools.FileDiagnostics.diagnostics(relative, content),
              test_relationships: []
            }
          end

        {relative, file}
      end)

    paths = files |> Map.keys() |> MapSet.new()

    files =
      Map.new(files, fn {path, file} ->
        {path, Map.put(file, :test_relationships, test_relationships(path, paths))}
      end)

    {:ok, files, git_snapshot(root)}
  rescue
    error -> {:error, {:repository_scan_failed, Exception.message(error)}}
  end

  defp unchanged?(nil, _stat, _hash), do: false

  defp unchanged?(file, stat, hash),
    do: file.size == stat.size and file.hash == hash

  defp walk(root, relative) do
    directory = Path.join(root, relative)

    case File.ls(directory) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          child = if relative == "", do: entry, else: Path.join(relative, entry)
          path = Path.join(root, child)

          cond do
            MapSet.member?(@ignored, entry) -> []
            # A symlinked directory can point at an ancestor and recurse
            # forever; only regular directories/files are ever descended into.
            symlink?(path) -> []
            File.dir?(path) -> walk(root, child)
            File.regular?(path) -> [child]
            true -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp symlink?(path), do: match?({:ok, %{type: :symlink}}, File.lstat(path))

  defp repository_paths(root, max_files) do
    paths =
      if File.exists?(Path.join(root, ".git")) do
        case System.cmd(
               "git",
               ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
               cd: root,
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            output
            |> String.split(<<0>>, trim: true)
            |> Enum.reject(&ignored_path?/1)
            |> Enum.filter(&File.regular?(Path.join(root, &1)))

          _failed ->
            walk(root, "")
        end
      else
        walk(root, "")
      end

    bound_paths(root, paths, max_files)
  end

  defp bound_paths(root, paths, max_files) do
    count = length(paths)

    if count > max_files do
      Logger.warning(
        "#{root}: repository scan found #{count} files, over the #{max_files} limit; indexing only a bounded subset"
      )

      paths |> Enum.sort() |> Enum.take(max_files)
    else
      paths
    end
  end

  defp ignored_path?(path) do
    path
    |> Path.split()
    |> Enum.any?(&MapSet.member?(@ignored, &1))
  end

  defp diff(previous, current) do
    added = Map.keys(current) -- Map.keys(previous)
    removed = Map.keys(previous) -- Map.keys(current)

    changed =
      Map.keys(current)
      |> Enum.filter(fn path -> previous[path] && previous[path].hash != current[path].hash end)

    %{added: Enum.sort(added), changed: Enum.sort(changed), removed: Enum.sort(removed)}
  end

  defp persist_context(state) do
    content =
      JSON.encode!(%{
        generation: state.generation,
        file_count: map_size(state.files),
        files:
          state.files
          |> Map.values()
          |> Enum.map(
            &Map.take(&1, [
              :path,
              :hash,
              :language,
              :symbols,
              :dependencies,
              :diagnostics,
              :test_relationships
            ])
          ),
        git: state.git
      })

    _ =
      ContextStore.put(state.project_id, %{
        id: "repository:snapshot",
        kind: "repository",
        source: state.workspace_root,
        source_version: state.generation,
        content: content,
        metadata: %{file_count: map_size(state.files)}
      })

    :ok
  end

  defp publish_changes(_state, %{added: [], changed: [], removed: []}), do: :ok

  defp publish_changes(state, changes) do
    publish(state.project_id, :repository_updated, %{
      "generation" => state.generation,
      "added_count" => length(changes.added),
      "changed_count" => length(changes.changed),
      "removed_count" => length(changes.removed),
      "added_paths" => Enum.take(changes.added, 100),
      "changed_paths" => Enum.take(changes.changed, 100),
      "removed_paths" => Enum.take(changes.removed, 100)
    })
  end

  defp publish(project_id, type, data) do
    case Names.pid(:goal_root_supervisor, project_id) do
      {:ok, supervisor} ->
        supervisor
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn {_, pid, _, _} ->
          Registry.select(BeamAgent.Registry, [
            {{{:goal_supervisor, :"$1"}, pid, :"$2"}, [], [:"$1"]}
          ])
          |> Enum.each(fn goal_id -> _ = EventLog.append(goal_id, type, data) end)
        end)

      _other ->
        :ok
    end
  end

  defp git_snapshot(root) do
    if File.exists?(Path.join(root, ".git")) do
      head = System.cmd("git", ["rev-parse", "HEAD"], cd: root, stderr_to_stdout: true)
      status = System.cmd("git", ["status", "--porcelain=v1"], cd: root, stderr_to_stdout: true)

      %{
        head: command_output(head),
        dirty: command_output(status) != "",
        changed_paths: command_output(status) |> String.split("\n", trim: true) |> length()
      }
    else
      %{head: nil, dirty: false, changed_paths: 0}
    end
  rescue
    _error -> %{head: nil, dirty: false, changed_paths: 0}
  end

  defp command_output({output, 0}), do: String.trim(output)
  defp command_output({_output, _status}), do: ""

  defp symbols(path, content) do
    case language(path) do
      "elixir" ->
        Regex.scan(~r/^\s*(?:defmodule|defp?|defmacro)\s+([^\s(,]+)/m, content,
          capture: :all_but_first
        )
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.take(200)

      _other ->
        []
    end
  end

  defp dependencies(path, content) do
    case language(path) do
      "elixir" ->
        Regex.scan(~r/^\s*(?:alias|import|use)\s+([^\s,{]+)/m, content, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.take(100)

      _other ->
        []
    end
  end

  defp test_relationships("test/" <> path, paths) do
    source =
      path
      |> String.replace_suffix("_test.exs", ".ex")
      |> then(&"lib/#{&1}")

    if MapSet.member?(paths, source), do: [source], else: []
  end

  defp test_relationships(path, paths) do
    extension = Path.extname(path)
    stem = path |> Path.rootname(extension) |> String.replace_prefix("lib/", "")
    test = "test/#{stem}_test.exs"
    if MapSet.member?(paths, test), do: [test], else: []
  end

  defp language(path) do
    case Path.extname(path) do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".go" -> "go"
      ".js" -> "javascript"
      ".ts" -> "typescript"
      ".tsx" -> "typescript"
      ".py" -> "python"
      _other -> "text"
    end
  end

  defp public_snapshot(state) do
    %{
      project_id: state.project_id,
      workspace_root: state.workspace_root,
      generation: state.generation,
      file_count: map_size(state.files),
      files: state.files,
      git: state.git,
      last_refreshed_at: state.last_refreshed_at
    }
  end

  defp hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  defp reason_code({reason, _detail}) when is_atom(reason), do: to_string(reason)
  defp reason_code(reason) when is_atom(reason), do: to_string(reason)
  defp reason_code(_reason), do: "repository_refresh_failed"

  defp call(project_id, message, timeout \\ 5_000) do
    with {:ok, pid} <- Names.pid(:repository_index, project_id),
         do: GenServer.call(pid, message, timeout)
  end

  defp cast(project_id, message) do
    with {:ok, pid} <- Names.pid(:repository_index, project_id) do
      GenServer.cast(pid, message)
    end
  end
end
