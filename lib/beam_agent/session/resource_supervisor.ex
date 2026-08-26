defmodule BeamAgent.Session.ResourceSupervisor do
  @moduledoc "Dynamic owner for stateful resources such as terminals, browsers, or MCP connections."
  use DynamicSupervisor

  alias BeamAgent.Names

  def start_link(opts) do
    id = Keyword.fetch!(opts, :session_id)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: Names.via(:resource_supervisor, id))
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
end
