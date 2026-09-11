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
File.mkdir_p!(Path.join(root, "second-workspace"))

for folder <- ["workspace", "second-workspace"] do
  workspace = Path.join(root, folder)
  File.write!(Path.join(workspace, "README.md"), "Browser documentation observer fixture")
  File.mkdir_p!(Path.join(workspace, "docs with spaces/nested"))
  File.write!(Path.join(workspace, "docs with spaces/nested/guide.md"), "Tracked guide")
  System.cmd("git", ["init", "-q"], cd: workspace)
  System.cmd("git", ["add", "README.md", "docs with spaces"], cd: workspace)

  System.cmd(
    "git",
    [
      "-c",
      "user.name=Browser Fixture",
      "-c",
      "user.email=fixture@example.invalid",
      "-c",
      "core.hooksPath=/dev/null",
      "commit",
      "--no-gpg-sign",
      "-qm",
      "Initial fixture"
    ],
    cd: workspace
  )
end

# Begin with NO sessions or TUI. Deliberately take longer than the old 8s HTTP
# timeout on the first launch, without invoking any real provider.
{:ok, first_start} = Agent.start_link(fn -> true end)

:sys.replace_state(BeamAgent.LocalSessionStarts, fn state ->
  %{
    state
    | create: fn config, path ->
        if Agent.get_and_update(first_start, &{&1, false}), do: Process.sleep(9_000)
        BeamAgent.CLI.create_local_session(config, path)
      end
  }
end)

token = "local-browser-fixture-token-only"

# Supply one representative advisory per observer for presentation/action tests.
# This is fixture-only state, never a real model evaluation or production endpoint.
Task.start(fn ->
  loop = fn recur, seen ->
    {:ok, %{sessions: sessions}} = BeamAgent.LocalDiscovery.list()

    seen =
      Enum.reduce(sessions, seen, fn session, seen ->
        id = session["session_id"]

        if MapSet.member?(seen, id) do
          seen
        else
          with {:ok, %{"status" => "observing", "paths" => paths}} <-
                 BeamAgent.Missions.Documentation.command(id, "status"),
               {:ok, context} <- BeamAgent.Agent.construction_context(id),
               {:ok, snapshot} <- BeamAgent.Missions.Snapshot.capture(context, paths),
               {:ok, pid} <- BeamAgent.Names.pid(:documentation_mission, id) do
            report = %{
              "status" => "advisory",
              "worker_id" => "browser-observer-fixture",
              "fingerprint" => snapshot.fingerprint,
              "content" =>
                "REVIEW_WARN\n\n1. **README.md — unsupported quality claims**\n- **Evidence:** The README claims full test coverage without a linked result.\n- **Uncertainty:** The excerpt may omit the supporting evidence.\n- **Next action:** Re-read the README and replace only unsupported claims.\n\n2. **Setup instructions need a closer look**\n- **Evidence:** The excerpt does not include install commands.\n- **Uncertainty:** They may be documented elsewhere.\n- **Next action:** Verify the full documentation before proposing an edit.\n\nCoverage is partial; these are fixture findings, not a model evaluation."
            }

            :sys.replace_state(pid, fn state ->
              %{state | data: Map.put(state.data, "report", report)}
            end)

            MapSet.put(seen, id)
          else
            _ -> seen
          end
        end
      end)

    Process.sleep(200)
    recur.(recur, seen)
  end

  loop.(loop, MapSet.new())
end)

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
