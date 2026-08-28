defmodule BeamAgent.Project.RepositoryIndex do
  @moduledoc "Project-level reactive repository snapshot with generation-safe incremental analysis."
  use GenServer

  alias BeamAgent.{Goal, Names}
  alias BeamAgent.Project.ContextStore
  alias BeamAgent.Session.EventLog

  @ignored MapSet.new([".git", "_build", "deps", ".elixir_ls", "node_modules"])

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
      scan_interval_ms: Keyword.get(opts, :repository_scan_interval_ms, 2_000)
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
    {_reply, state} = do_refresh(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    {_reply, state} = do_refresh(state)
    Process.send_after(self(), :refresh, state.scan_interval_ms)
    {:noreply, state}
  end

  defp do_refresh(state) do
    generation = state.generation + 1

    case scan(state.workspace_root, generation) do
      {:ok, files, git} ->
        changes = diff(state.files, files)

        state = %{
          state
          | generation: generation,
            files: files,
            git: git,
            last_refreshed_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        persist_context(state)
        publish_changes(state, changes)
        {{:ok, public_snapshot(state)}, state}

      {:error, reason} ->
        publish(state.project_id, :repository_refresh_failed, %{
          "failure_code" => reason_code(reason)
        })

        {{:error, reason}, state}
    end
  end

  defp scan(root, generation) do
    files =
      root
      |> walk("")
      |> Enum.sort()
      |> Map.new(fn relative ->
        absolute = Path.join(root, relative)
        stat = File.stat!(absolute, time: :posix)
        content = if stat.size <= 1_000_000, do: File.read!(absolute), else: ""

        {relative,
         %{
           path: relative,
           size: stat.size,
           modified_at: stat.mtime,
           hash: hash(content),
           generation: generation,
           language: language(relative),
           symbols: symbols(relative, content),
           dependencies: dependencies(relative, content),
           diagnostics: BeamAgent.Tools.FileDiagnostics.diagnostics(relative, content),
           test_relationships: []
         }}
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

  defp walk(root, relative) do
    directory = Path.join(root, relative)

    case File.ls(directory) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          child = if relative == "", do: entry, else: Path.join(relative, entry)

          cond do
            MapSet.member?(@ignored, entry) -> []
            File.dir?(Path.join(root, child)) -> walk(root, child)
            File.regular?(Path.join(root, child)) -> [child]
            true -> []
          end
        end)

      {:error, _reason} ->
        []
    end
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
    Enum.each(changes.added, &publish_file(state, &1, "added"))
    Enum.each(changes.changed, &publish_file(state, &1, "changed"))
    Enum.each(changes.removed, &publish_file(state, &1, "removed"))

    publish(state.project_id, :repository_updated, %{
      "generation" => state.generation,
      "added_count" => length(changes.added),
      "changed_count" => length(changes.changed),
      "removed_count" => length(changes.removed)
    })
  end

  defp publish_file(state, path, change) do
    file = state.files[path]

    publish(state.project_id, :file_changed, %{
      "path" => path,
      "change" => change,
      "generation" => state.generation,
      "hash" => file && file.hash
    })
  end

  defp publish(project_id, type, data) do
    case Names.pid(:goal_root_supervisor, project_id) do
      {:ok, supervisor} ->
        supervisor
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn {_, pid, _, _} ->
          case goal_for_supervisor(pid, project_id) do
            {:ok, goal} -> _ = EventLog.append(goal.session_id, type, data)
            _other -> :ok
          end
        end)

      _other ->
        :ok
    end
  end

  defp goal_for_supervisor(supervisor_pid, project_id) do
    Registry.select(BeamAgent.Registry, [
      {{{:goal_supervisor, :"$1"}, supervisor_pid, :"$2"}, [], [:"$1"]}
    ])
    |> Enum.find_value({:error, :not_found}, fn goal_id ->
      case Goal.snapshot(goal_id) do
        {:ok, %{project_id: ^project_id} = goal} -> {:ok, goal}
        _other -> nil
      end
    end)
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
