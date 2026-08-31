defmodule BeamAgent.Goal.ModelLease do
  @moduledoc "Keeps one model route stable for the lifetime of a Goal work contract."
  use GenServer

  alias BeamAgent.Names

  def start_link(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:goal_model_lease, goal_id))
  end

  def fetch(goal_id, work_id) when is_binary(work_id) do
    with {:ok, pid} <- Names.pid(:goal_model_lease, goal_id) do
      GenServer.call(pid, {:fetch, work_id})
    end
  end

  def put_new(goal_id, work_id, route) when is_binary(work_id) do
    with {:ok, pid} <- Names.pid(:goal_model_lease, goal_id) do
      GenServer.call(pid, {:put_new, work_id, route})
    end
  end

  def release(goal_id, work_id) when is_binary(work_id) do
    with {:ok, pid} <- Names.pid(:goal_model_lease, goal_id) do
      GenServer.call(pid, {:release, work_id})
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{routes: %{}}}

  @impl true
  def handle_call({:fetch, work_id}, _from, state) do
    case Map.fetch(state.routes, work_id) do
      {:ok, route} -> {:reply, {:ok, route}, state}
      :error -> {:reply, :not_found, state}
    end
  end

  def handle_call({:put_new, work_id, route}, _from, state) do
    {selected, routes} = Map.get_and_update(state.routes, work_id, &{&1 || route, &1 || route})
    {:reply, {:ok, selected}, %{state | routes: routes}}
  end

  def handle_call({:release, work_id}, _from, state) do
    {:reply, :ok, %{state | routes: Map.delete(state.routes, work_id)}}
  end
end
