defmodule BeamAgent.Auth.SessionSupervisor do
  @moduledoc "Dynamic supervisor for disposable provider-login sessions."
  use DynamicSupervisor

  def start_link(opts \\ []),
    do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
