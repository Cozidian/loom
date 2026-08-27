defmodule BeamAgent.Goal.ResourceSupervisor do
  @moduledoc "Dynamic owner for goal-scoped resources such as MCP server processes."
  use DynamicSupervisor

  alias BeamAgent.Names

  def start_link(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)

    DynamicSupervisor.start_link(__MODULE__, :ok,
      name: Names.via(:goal_resource_supervisor, goal_id)
    )
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
end
