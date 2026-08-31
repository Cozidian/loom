defmodule BeamAgent.Project.PathLeaseManager do
  @moduledoc "Project-wide write leases that prevent actors from editing the same path concurrently."
  use GenServer

  alias BeamAgent.Names

  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:path_lease_manager, project_id))
  end

  def acquire(project_id, workspace_root, path, owner) do
    with {:ok, pid} <- Names.pid(:path_lease_manager, project_id) do
      GenServer.call(pid, {:acquire, lease_key(workspace_root, path), owner})
    end
  end

  def release_owner(project_id, owner) do
    with {:ok, pid} <- Names.pid(:path_lease_manager, project_id) do
      GenServer.call(pid, {:release_owner, owner})
    end
  end

  def snapshot(project_id) do
    with {:ok, pid} <- Names.pid(:path_lease_manager, project_id) do
      GenServer.call(pid, :snapshot)
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{leases: %{}, monitors: %{}}}

  @impl true
  def handle_call({:acquire, key, owner}, _from, state) do
    case Map.get(state.leases, key) do
      nil ->
        {state, lease} = grant(state, key, owner)
        {:reply, {:ok, lease}, state}

      %{owner: ^owner} = lease ->
        {:reply, {:ok, lease}, state}

      lease ->
        {:reply, {:error, {:path_leased, display_path(key), lease.owner}}, state}
    end
  end

  def handle_call({:release_owner, owner}, _from, state) do
    {:reply, :ok, release(state, owner)}
  end

  def handle_call(:snapshot, _from, state) do
    leases = state.leases |> Map.values() |> Enum.sort_by(& &1.path)
    {:reply, {:ok, leases}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.monitors, fn {_owner, monitor} -> monitor == ref end) do
      {owner, ^ref} -> {:noreply, release(state, owner)}
      nil -> {:noreply, state}
    end
  end

  defp grant(state, key, owner) do
    {state, monitor} = ensure_monitor(state, owner)

    lease = %{
      owner: owner,
      path: display_path(key),
      workspace_root: elem(key, 0),
      acquired_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {%{state | leases: Map.put(state.leases, key, lease), monitors: monitor}, lease}
  end

  defp ensure_monitor(state, owner) do
    case Map.fetch(state.monitors, owner) do
      {:ok, _ref} ->
        {state, state.monitors}

      :error ->
        monitors =
          case Names.pid(:agent, owner) do
            {:ok, pid} -> Map.put(state.monitors, owner, Process.monitor(pid))
            {:error, :not_found} -> state.monitors
          end

        {state, monitors}
    end
  end

  defp release(state, owner) do
    leases = Map.reject(state.leases, fn {_key, lease} -> lease.owner == owner end)

    monitors =
      case Map.pop(state.monitors, owner) do
        {nil, monitors} ->
          monitors

        {ref, monitors} ->
          Process.demonitor(ref, [:flush])
          monitors
      end

    %{state | leases: leases, monitors: monitors}
  end

  defp lease_key(workspace_root, path) do
    expanded =
      if Path.type(path) == :absolute,
        do: Path.expand(path),
        else: Path.expand(path, workspace_root)

    {Path.expand(workspace_root), expanded}
  end

  defp display_path({_workspace_root, path}), do: path
end
