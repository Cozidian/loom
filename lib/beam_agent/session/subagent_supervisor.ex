defmodule BeamAgent.Session.SubagentSupervisor do
  @moduledoc false
  use DynamicSupervisor

  alias BeamAgent.Names

  def start_link(opts) do
    id = Keyword.fetch!(opts, :session_id)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: Names.via(:subagent_supervisor, id))
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
end
