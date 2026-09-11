# Launched by the CLI. Credentials arrive in this child only, never in argv.
config = Application.fetch_env!(:beam_agent_web, BeamAgentWeb.Endpoint)
Application.put_env(:beam_agent_web, BeamAgentWeb.Endpoint, Keyword.put(config, :server, true))
{:ok, _} = Application.ensure_all_started(:beam_agent_web)
{:ok, {_address, port}} = BeamAgentWeb.Endpoint.server_info(:http)
IO.puts("BEAM_DESK_READY #{port}")
# The owning runtime keeps stdin open. Its private pipe can renew browser tickets;
# no unauthenticated HTTP endpoint can mint one. EOF handles abrupt parent death.
loop = fn loop ->
  case IO.read(:stdio, :line) do
    line when is_binary(line) ->
      case JSON.decode(line) do
        {:ok, %{"request_id" => id, "launch_ticket" => ticket}}
        when is_binary(id) and is_binary(ticket) ->
          :ok = BeamAgentWeb.LaunchTicket.issue(ticket)
          IO.puts("LOOM_TICKET_READY #{id}")

        _ ->
          :ok
      end

      loop.(loop)

    _ ->
      System.stop(0)
  end
end

loop.(loop)
