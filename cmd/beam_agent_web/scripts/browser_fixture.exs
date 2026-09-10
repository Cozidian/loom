# Isolated, deterministic browser fixture. Never loads user provider configuration.
{:ok, _} = Application.ensure_all_started(:beam_agent)
root = Path.join(System.tmp_dir!(), "beam-desk-browser-#{System.unique_integer([:positive])}")
File.mkdir_p!(Path.join(root, "workspace"))
System.at_exit(fn _ -> File.rm_rf(root) end)

Application.put_env(:beam_agent, :discovery_dir, Path.join(root, "live"))
{:ok, profile} = BeamAgent.CLI.Config.profile("echo", nil, nil, nil)

stored =
  BeamAgent.CLI.Config.defaults()
  |> Map.put("active_profile", "echo")
  |> Map.put("profiles", %{"echo" => profile})
  |> Map.put("data_dir", Path.join(root, "runtime"))

{:ok, runtime_config} = BeamAgent.CLI.Config.runtime(stored)

runtime_config =
  Map.put(
    runtime_config,
    "model_endpoints",
    BeamAgent.CLI.Config.model_endpoints(stored, runtime_config)
  )

runtime_config = Map.put(runtime_config, "workspace_root", Path.join(root, "workspace"))
{:ok, id, _} = BeamAgent.CLI.create_local_session(runtime_config, Path.join(root, "config.json"))
File.mkdir_p!(Path.join(root, "second-workspace"))

{:ok, _, _} =
  BeamAgent.CLI.create_local_session(
    Map.put(runtime_config, "workspace_root", Path.join(root, "second-workspace")),
    Path.join(root, "config.json")
  )

{:ok, _} = BeamAgent.ask(id, "Welcome to the real runtime")
token = "local-browser-fixture-token-only"

{:ok, server} =
  BeamAgent.ControlPlane.HTTPServer.start_link(
    token: token,
    catalog: [config: runtime_config, config_path: Path.join(root, "config.json")]
  )

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
BeamAgentWeb.LaunchTicket.issue("disposable-browser-launch-ticket-0123456789", 300_000)
Process.sleep(:infinity)
