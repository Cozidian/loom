defmodule BeamAgent.Project.GoalRootSupervisor do
  @moduledoc "Owns the ephemeral goal subtrees for one project."
  use DynamicSupervisor

  alias BeamAgent.Names

  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)

    DynamicSupervisor.start_link(__MODULE__, opts,
      name: Names.via(:goal_root_supervisor, project_id)
    )
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
