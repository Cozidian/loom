defmodule BeamAgent.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: BeamAgent.Registry},
      BeamAgent.CapabilityCatalog,
      BeamAgent.Auth.CredentialStore,
      BeamAgent.Auth.SessionSupervisor,
      {DynamicSupervisor, strategy: :one_for_one, name: BeamAgent.LocalEndpointSupervisor},
      BeamAgent.ProjectRootSupervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BeamAgent.Supervisor)
  end
end
