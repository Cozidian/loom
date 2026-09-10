defmodule BeamAgent.Project.WorktreeManager do
  @moduledoc "Project-owned lifecycle and evidence tracker for isolated Git worktrees."
  use GenServer

  alias BeamAgent.{Names, WorktreeHandle}
  alias BeamAgent.Session.EventLog

  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:worktree_manager, project_id))
  end

  def create(project_id, owner_worker_id, opts \\ []),
    do: call(project_id, {:create, owner_worker_id, opts}, 30_000)

  def inspect(project_id, handle_id), do: call(project_id, {:inspect, handle_id}, 30_000)

  def validate(project_id, handle_id, owner_worker_id),
    do: call(project_id, {:validate, handle_id, owner_worker_id})

  def cleanup(project_id, handle_id, opts \\ []),
    do: call(project_id, {:cleanup, handle_id, opts}, 30_000)

  def list(project_id), do: call(project_id, :list)

  @impl true
  def init(opts) do
    data_dir =
      Keyword.get_lazy(opts, :data_dir, fn -> Application.fetch_env!(:beam_agent, :data_dir) end)

    project_id = Keyword.fetch!(opts, :project_id)
    root = Path.join([data_dir, "projects", project_id, "worktrees"])
    :ok = File.mkdir_p(root)

    {:ok,
     %{
       project_id: project_id,
       workspace_root: Keyword.fetch!(opts, :workspace_root),
       worktree_root: root,
       handles: %{},
       event_sessions: %{}
     }}
  end

  @impl true
  def handle_call({:create, owner_worker_id, opts}, _from, state) do
    id = "worktree-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    path = Path.join(state.worktree_root, id)
    base_ref = Keyword.get(opts, :base_ref, "HEAD")
    purpose = Keyword.get(opts, :purpose, "isolated implementation")

    with :ok <- ensure_repository(state.workspace_root),
         {:ok, base_revision} <- revision(state.workspace_root, base_ref),
         {_, 0} <-
           System.cmd("git", ["worktree", "add", "--detach", path, base_revision],
             cd: state.workspace_root,
             stderr_to_stdout: true
           ),
         {:ok, canonical_path} <- BeamAgent.Workspace.canonical_root(path) do
      handle = %WorktreeHandle{
        id: id,
        project_id: state.project_id,
        owner_worker_id: owner_worker_id,
        path: canonical_path,
        base_revision: base_revision,
        status: :active,
        purpose_fingerprint: fingerprint(purpose),
        created_at: DateTime.utc_now()
      }

      state = put_in(state, [:handles, id], handle)
      event_session_id = Keyword.get(opts, :event_session_id, owner_worker_id)
      state = put_in(state, [:event_sessions, id], event_session_id)
      record(event_session_id, :worktree_created, handle, %{})
      {:reply, {:ok, handle}, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {_output, status} ->
        _ = File.rmdir(path)
        {:reply, {:error, {:worktree_create_failed, status}}, state}
    end
  end

  def handle_call({:validate, id, owner_worker_id}, _from, state) do
    case state.handles[id] do
      %WorktreeHandle{owner_worker_id: ^owner_worker_id, status: :active} = handle ->
        {:reply, {:ok, handle}, state}

      %WorktreeHandle{} ->
        {:reply, {:error, :worktree_owner_or_state_mismatch}, state}

      nil ->
        {:reply, {:error, :unknown_worktree}, state}
    end
  end

  def handle_call({:inspect, id}, _from, state) do
    case state.handles[id] do
      %WorktreeHandle{status: :active} = handle ->
        status = git(handle.path, ["status", "--porcelain=v1"])
        patch = git(handle.path, ["diff", "--binary", handle.base_revision, "--"])

        result = %{
          handle: handle,
          changed_files: changed_files(status),
          status: status,
          patch: patch,
          patch_fingerprint: fingerprint(patch)
        }

        record(state.event_sessions[id], :worktree_inspected, handle, %{
          changed_file_count: length(result.changed_files),
          patch_fingerprint: result.patch_fingerprint
        })

        {:reply, {:ok, result}, state}

      %WorktreeHandle{} ->
        {:reply, {:error, :worktree_not_active}, state}

      nil ->
        {:reply, {:error, :unknown_worktree}, state}
    end
  end

  def handle_call({:cleanup, id, opts}, _from, state) do
    case state.handles[id] do
      %WorktreeHandle{status: :active} = handle ->
        force = Keyword.get(opts, :force, false)

        if force or git(handle.path, ["status", "--porcelain=v1"]) == "" do
          args = ["worktree", "remove"] ++ if(force, do: ["--force"], else: []) ++ [handle.path]

          case System.cmd("git", args, cd: state.workspace_root, stderr_to_stdout: true) do
            {_output, 0} ->
              handle = %{handle | status: :reclaimed}
              state = put_in(state, [:handles, id], handle)
              record(state.event_sessions[id], :worktree_reclaimed, handle, %{force: force})
              {:reply, :ok, state}

            {_output, status} ->
              {:reply, {:error, {:worktree_cleanup_failed, status}}, state}
          end
        else
          {:reply, {:error, :worktree_has_uncommitted_changes}, state}
        end

      %WorktreeHandle{} ->
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :unknown_worktree}, state}
    end
  end

  def handle_call(:list, _from, state),
    do: {:reply, {:ok, state.handles |> Map.values() |> Enum.sort_by(& &1.id)}, state}

  defp ensure_repository(root) do
    case System.cmd("git", ["rev-parse", "--git-dir"], cd: root, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _other -> {:error, :workspace_not_git_repository}
    end
  end

  defp revision(root, ref) do
    case System.cmd("git", ["rev-parse", "--verify", ref], cd: root, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      _other -> {:error, :invalid_worktree_base}
    end
  end

  defp git(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} -> String.trim_trailing(output)
      _other -> ""
    end
  end

  defp changed_files(status) do
    status
    |> String.split("\n", trim: true)
    |> Enum.map(fn line -> line |> String.slice(3..-1//1) |> String.trim() end)
    |> Enum.reject(&(&1 == ""))
  end

  defp record(session_id, type, handle, extra) do
    data =
      Map.merge(
        %{
          "worktree_id" => handle.id,
          "owner_worker_id" => handle.owner_worker_id,
          "base_revision" => handle.base_revision,
          "worktree_status" => to_string(handle.status),
          "purpose_fingerprint" => handle.purpose_fingerprint
        },
        Map.new(extra, fn {key, value} -> {to_string(key), value} end)
      )

    _ = EventLog.append(session_id, type, data)
    :ok
  end

  defp fingerprint(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp call(project_id, message, timeout \\ 5_000) do
    with {:ok, pid} <- Names.pid(:worktree_manager, project_id),
         do: GenServer.call(pid, message, timeout)
  end
end
