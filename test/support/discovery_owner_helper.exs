# Separate OS process helper; never reads real provider profiles.
[root, name] = System.argv()
{:ok, _} = Application.ensure_all_started(:beam_agent)
Application.put_env(:beam_agent, :discovery_dir, Path.join(root, "live"))
workspace = Path.join(root, name)
File.mkdir_p!(workspace)
{:ok, profile} = BeamAgent.CLI.Config.profile("echo", nil, nil, nil)

stored =
  BeamAgent.CLI.Config.defaults()
  |> Map.put("active_profile", "echo")
  |> Map.put("profiles", %{"echo" => profile})
  |> Map.put("data_dir", Path.join(root, "sessions"))

{:ok, config} = BeamAgent.CLI.Config.runtime(stored)
config = Map.put(config, "model_endpoints", BeamAgent.CLI.Config.model_endpoints(stored, config))

{:ok, id, endpoint} =
  BeamAgent.CLI.create_local_session(
    Map.put(config, "workspace_root", workspace),
    Path.join(root, "config.json")
  )

IO.puts("OWNER_READY " <> id)
IO.read(:stdio, :line)
DynamicSupervisor.terminate_child(BeamAgent.LocalEndpointSupervisor, endpoint)
BeamAgent.stop_session(id)
System.stop(0)
