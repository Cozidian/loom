defmodule BeamAgentWeb.Application do
  use Application

  def start(_type, _args) do
    Supervisor.start_link([BeamAgentWeb.LaunchTicket, BeamAgentWeb.Endpoint],
      strategy: :one_for_one,
      name: BeamAgentWeb.Supervisor
    )
  end

  def config_change(changed, _new, removed) do
    BeamAgentWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
