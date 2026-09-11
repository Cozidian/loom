defmodule BeamAgent.CLI.Mission do
  @moduledoc "CLI entry for a bounded documentation mission and existing-owner controls."
  alias BeamAgent.CLI.Config
  alias BeamAgent.Missions.Documentation

  def run(["docs" | args], config_path) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          workspace: :string,
          profile: :string,
          path: :keep,
          quiet_seconds: :integer,
          cooldown_seconds: :integer,
          max_assessments: :integer
        ]
      )

    with true <- rest == [] and invalid == [],
         {:ok, stored} <- Config.load(config_path),
         {:ok, config} <- Config.runtime(stored, opts[:profile]),
         {:ok, workspace} <- BeamAgent.Workspace.canonical_root(opts[:workspace] || File.cwd!()),
         {:ok, provider} <- Config.provider_atom(config["provider"]),
         {:ok, _} <- Application.ensure_all_started(:beam_agent) do
      config =
        Map.merge(config, %{
          "workspace_root" => workspace,
          "approval_policy" => "deny",
          "team_mode" => "solo",
          "model_strategy" => "manual"
        })

      with {:ok, id} <-
             BeamAgent.start_session(
               workspace_root: workspace,
               data_dir: config["data_dir"],
               provider: provider,
               provider_profile: config["profile"],
               provider_options: Config.provider_options(config),
               model_strategy: :manual,
               team_mode: :solo,
               approval_policy: :deny,
               capabilities: %{
                 tools: ["read_file", "git_inspect"],
                 paths: ["."],
                 git_operations: ["status"],
                 model_classes: :all
               }
             ) do
        try do
          with :ok <- Documentation.command(id, "start", options(opts)),
               {:ok, endpoint} <-
                 DynamicSupervisor.start_child(
                   BeamAgent.LocalEndpointSupervisor,
                   {BeamAgent.LocalEndpoint,
                    session_id: id, config: config, config_path: config_path}
                 ) do
            try do
              IO.puts(
                "Documentation mission #{id}\nRead-only · tracks future changes · #{config["profile"]} / #{config["model"]}\nVisible in Desk; attach with: loom attach #{id}\nControls: loom mission #{id} status|pause|resume|dismiss\nKeep this owner running. Ctrl+C stops it; observations/reports remain in session history."
              )

              follow(id, nil)
            after
              DynamicSupervisor.terminate_child(BeamAgent.LocalEndpointSupervisor, endpoint)
            end
          else
            error -> fail(error)
          end
        after
          BeamAgent.stop_session(id)
        end
      else
        error -> fail(error)
      end
    else
      error -> fail(error)
    end
  end

  def run([id, action | args], _config)
      when action in ["start", "status", "pause", "resume", "dismiss", "stop", "delete"] do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          path: :keep,
          quiet_seconds: :integer,
          cooldown_seconds: :integer,
          max_assessments: :integer
        ]
      )

    with true <- rest == [] and invalid == [] and (action == "start" or opts == []),
         {:ok, record} <- BeamAgent.LocalDiscovery.lookup(id),
         {:ok, result} <-
           BeamAgent.LocalDiscovery.request(record, :post, "/api/v1/command", %{
             version: 1,
             request_id: "mission-cli",
             command: "documentation_mission",
             arguments: Map.put(options(opts), "action", action)
           }) do
      IO.puts(JSON.encode!(result))
      0
    else
      error -> fail(error)
    end
  end

  def run(_, _) do
    IO.puts("""
    loom mission docs [--workspace PATH] [--profile NAME]
    loom mission SESSION_ID start [options]
    loom mission SESSION_ID status|pause|resume|dismiss|stop|delete

    Stop cancels observation and its fix agents. Delete also removes observer configuration.
    Session history and retained worktrees are kept; the owning harness stays running.

    Options: --path PATH (repeatable; tracked files only)
             --quiet-seconds 60 --cooldown-seconds 300 --max-assessments 3
    Default paths: lib, src, test, docs, README.md. Use paths without . or .. components.
    No model calls until a future stable change; each assessment can consume provider allowance.
    Read-only suggestions, never automatic edits or publication. At the finite limit,
    start a new owner for further work. Recovery pauses; it never retries paid work automatically.
    This runs with a live foreground owner, not an installed background service.
    """)

    0
  end

  defp options(opts) do
    values =
      opts
      |> Keyword.take([:quiet_seconds, :cooldown_seconds, :max_assessments])
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    case Keyword.get_values(opts, :path) do
      [] -> values
      paths -> Map.put(values, "paths", paths)
    end
  end

  defp follow(id, previous) do
    case Documentation.command(id, "status") do
      {:ok, status} ->
        visible = Map.take(status, ["status", "attempts", "max_assessments", "reason", "report"])
        if visible != previous, do: IO.puts(JSON.encode!(visible))

        receive do
          :stop -> 0
        after
          1_000 -> follow(id, visible)
        end

      error ->
        fail(error)
    end
  end

  defp fail(error) do
    IO.puts(:stderr, "Mission unavailable: #{inspect(error)}. Run loom mission --help.")
    1
  end
end
