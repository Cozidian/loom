defmodule HarnessFixture.Runtime do
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def goals, do: GenServer.call(__MODULE__, :goals)
  def start_goal(objective), do: GenServer.call(__MODULE__, {:start, objective})
  def cancel_goal(id), do: GenServer.call(__MODULE__, {:cancel, id})
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(goals), do: {:ok, goals}
  @impl true
  def handle_call(:goals, _from, goals), do: {:reply, Map.values(goals), goals}
  def handle_call(:reset, _from, _goals), do: {:reply, :ok, %{}}
  def handle_call({:start, objective}, _from, goals) do
    if is_binary(objective) and String.trim(objective) != "" do
      id = "goal-#{System.unique_integer([:positive])}"
      goal = %{id: id, objective: String.trim(objective), status: :running}
      {:reply, {:ok, goal}, Map.put(goals, id, goal)}
    else
      {:reply, {:error, :blank_objective}, goals}
    end
  end
  def handle_call({:cancel, id}, _from, goals) do
    case goals[id] do
      nil -> {:reply, {:error, :not_found}, goals}
      goal -> {:reply, :ok, Map.put(goals, id, %{goal | status: :cancelled})}
    end
  end
end
