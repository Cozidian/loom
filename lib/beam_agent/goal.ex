defmodule BeamAgent.Goal do
  @moduledoc "The identity and state boundary for one ephemeral project goal."
  use GenServer

  alias BeamAgent.Names

  def start_link(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:goal, goal_id))
  end

  def snapshot(goal_id) do
    with {:ok, pid} <- Names.pid(:goal, goal_id) do
      GenServer.call(pid, :snapshot)
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       goal_id: Keyword.fetch!(opts, :goal_id),
       project_id: Keyword.fetch!(opts, :project_id),
       session_id: Keyword.fetch!(opts, :session_id),
       workspace_root: Keyword.fetch!(opts, :workspace_root),
       objective: Keyword.get(opts, :objective),
       capability_envelope: Keyword.fetch!(opts, :capability_envelope)
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, state}, state}
end
