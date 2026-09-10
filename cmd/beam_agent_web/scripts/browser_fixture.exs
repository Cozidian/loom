# Isolated, deterministic browser fixture. Never loads user provider configuration.
{:ok, _} = Application.ensure_all_started(:beam_agent)
root = Path.join(System.tmp_dir!(), "beam-desk-browser-#{System.unique_integer([:positive])}")
File.mkdir_p!(Path.join(root, "workspace"))
System.at_exit(fn _ -> File.rm_rf(root) end)

{:ok, id} =
  BeamAgent.start_session(
    workspace_root: Path.join(root, "workspace"),
    data_dir: Path.join(root, "runtime"),
    provider: :echo,
    strategy: BeamAgent.Strategies.ToolLoop
  )

{:ok, _} = BeamAgent.ask(id, "Welcome to the real runtime")
token = "local-browser-fixture-token-only"
{:ok, server} = BeamAgent.start_web_control_plane(id, token: token)
{:ok, url} = BeamAgent.ControlPlane.HTTPServer.url(server)
Application.put_env(:beam_agent_web, :runtime_url, "http://127.0.0.1:#{URI.parse(url).port}")
Application.put_env(:beam_agent_web, :runtime_token, token)
config = Application.fetch_env!(:beam_agent_web, BeamAgentWeb.Endpoint)

Application.put_env(
  :beam_agent_web,
  BeamAgentWeb.Endpoint,
  Keyword.merge(config, server: true, http: [ip: {127, 0, 0, 1}, port: 4174])
)

{:ok, _} = Application.ensure_all_started(:beam_agent_web)
Process.sleep(:infinity)
