# Launched by the CLI. Credentials arrive in this child only, never in argv.
config = Application.fetch_env!(:beam_agent_web, BeamAgentWeb.Endpoint)
Application.put_env(:beam_agent_web, BeamAgentWeb.Endpoint, Keyword.put(config, :server, true))
{:ok, _} = Application.ensure_all_started(:beam_agent_web)
{:ok, {_address, port}} = BeamAgentWeb.Endpoint.server_info(:http)
IO.puts("BEAM_DESK_READY #{port}")
# The owning CLI keeps stdin open. EOF also handles abrupt parent death.
case IO.read(:stdio, :line) do
  _ -> System.stop(0)
end
