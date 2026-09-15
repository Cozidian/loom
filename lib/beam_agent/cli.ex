defmodule BeamAgent.CLI do
  @moduledoc "Command-line entry point for configuring and running BeamAgent."

  alias BeamAgent.{ProjectContext, Workspace}
  alias BeamAgent.CLI.{Config, TUI, TurnRunner, UI}

  @version Mix.Project.config()[:version]
  @run_switches [
    profile: :string,
    provider: :string,
    data_dir: :string,
    session: :string,
    model: :string,
    base_url: :string,
    api_key_env: :string,
    workspace: :string,
    approval: :string,
    model_strategy: :string,
    team_mode: :string,
    max_workers: :integer,
    model_concurrency: :integer,
    context_window: :integer,
    compact_at: :integer,
    frontend: :string,
    tui: :boolean
  ]

  def main(args) do
    status = run(args)
    if status != 0, do: System.halt(status)
  end

  def run(args) do
    {config_path, args} = extract_config_path(args)

    case args do
      ["diagnostics" | rest] ->
        BeamAgent.CLI.Diagnostics.run(rest)

      ["service" | rest] ->
        BeamAgent.CLI.Service.run(rest, config_path)

      ["tui" | rest] ->
        BeamAgent.CLI.Service.tui(rest, config_path)

      ["attach", id | rest] ->
        with {:ok, opts, []} <- parse(rest, frontend: :string),
             :ok <- validate_frontend(opts[:frontend]),
             {:ok, record} <- BeamAgent.LocalDiscovery.lookup(id),
             :ok <- TUI.attach(record, opts[:frontend]) do
          0
        else
          _ ->
            error(
              "Cannot attach. Use an interactive terminal and a live session from Desk. No session was resumed."
            )
        end

      ["document" | rest] ->
        BeamAgent.CLI.Document.run(rest, config_path)

      ["mission" | rest] ->
        BeamAgent.CLI.Mission.run(rest, config_path)

      ["desk", flag] when flag in ["--help", "-h"] ->
        desk_help()

      ["desk" | rest] ->
        if "--foreground" in rest do
          desk_command(config_path, List.delete(rest, "--foreground"))
        else
          case Config.load(config_path) do
            {:error, {:not_initialized, _}} ->
              case init_command(config_path, []) do
                0 -> BeamAgent.CLI.Service.desk(rest, config_path)
                status -> status
              end

            _ ->
              BeamAgent.CLI.Service.desk(rest, config_path)
          end
        end

      [] ->
        default_command(config_path)

      ["init", flag] when flag in ["--help", "-h"] ->
        init_help()

      ["run", flag] when flag in ["--help", "-h"] ->
        run_help()

      ["resume", flag] when flag in ["--help", "-h"] ->
        resume_help()

      ["serve", flag] when flag in ["--help", "-h"] ->
        serve_help()

      ["auth", flag] when flag in ["--help", "-h"] ->
        auth_help()

      ["run" | rest] ->
        run_command(config_path, rest)

      ["resume", session_id | rest] ->
        run_command(config_path, ["--session", session_id | rest], true)

      ["serve", session_id | rest] ->
        serve_command(config_path, session_id, rest)

      ["init" | rest] ->
        init_command(config_path, rest)

      ["doctor" | rest] ->
        doctor_command(config_path, rest)

      ["providers" | rest] ->
        providers_command(rest)

      ["provider" | rest] ->
        provider_command(config_path, rest)

      ["auth" | rest] ->
        auth_command(config_path, rest)

      ["tools" | rest] ->
        tools_command(rest)

      ["skills" | rest] ->
        skills_command(rest)

      ["sessions" | rest] ->
        sessions_command(config_path, rest)

      ["config", "show"] ->
        config_show(config_path)

      ["config", "path"] ->
        output(config_path)

      ["help"] ->
        help()

      ["--help"] ->
        help()

      ["-h"] ->
        help()

      ["--version"] ->
        output("loom #{@version}")

      ["--" <> _option | _rest] ->
        run_command(config_path, args)

      [unknown | _rest] ->
        usage_error("unknown command #{inspect(unknown)}")
    end
  end

  defp default_command(config_path) do
    case Config.load(config_path) do
      {:ok, _config} ->
        if TUI.available?(),
          do: BeamAgent.CLI.Service.tui([], config_path),
          else: run_command(config_path, [])

      {:error, {:not_initialized, ^config_path}} ->
        case init_command(config_path, []) do
          0 -> default_command(config_path)
          status -> status
        end

      {:error, reason} ->
        error(reason)
    end
  end

  defp init_command(config_path, args) do
    switches = [
      provider: :string,
      profile: :string,
      data_dir: :string,
      model: :string,
      base_url: :string,
      api_key_env: :string,
      approval: :string,
      model_strategy: :string,
      team_mode: :string,
      max_workers: :integer,
      model_concurrency: :integer,
      context_window: :integer,
      compact_at: :integer,
      force: :boolean,
      non_interactive: :boolean
    ]

    with {:ok, opts, []} <- parse(args, switches),
         :ok <- ensure_replacement_allowed(config_path, opts[:force]),
         :ok <- maybe_show_setup_header(opts),
         {:ok, config} <- build_config(opts),
         {:ok, ^config_path} <- Config.write(config, config_path) do
      UI.success("Configuration saved")
      UI.notice(config_path)
      output_config(config)
    else
      {:ok, _opts, positional} ->
        usage_error("unexpected arguments: #{Enum.join(positional, " ")}")

      {:error, reason} ->
        error(reason)
    end
  end

  defp build_config(opts) do
    defaults = Config.defaults()
    interactive = opts[:non_interactive] != true

    provider =
      opts[:provider] ||
        choose_provider(interactive, defaults["active_profile"])

    profile_name = opts[:profile] || provider

    with {:ok, provider_config} <- BeamAgent.Providers.fetch(provider),
         {:ok, profile} <- build_profile(opts, provider, provider_config, interactive),
         {:ok, globals} <- build_globals(opts, defaults, interactive) do
      Config.new(profile_name, profile, globals)
    end
  end

  defp build_profile(opts, provider, provider_config, interactive) do
    model =
      if provider_config[:model_required] do
        opts[:model] ||
          maybe_prompt(interactive, "Model", provider_config[:default_model])
      end

    base_url =
      if provider_config[:default_base_url] do
        opts[:base_url] ||
          maybe_prompt(interactive, "API base URL", provider_config.default_base_url)
      end

    api_key_env =
      if provider_config[:default_api_key_env] do
        opts[:api_key_env] ||
          maybe_prompt(
            interactive,
            "API key environment variable",
            provider_config.default_api_key_env
          )
      end

    Config.profile(provider, model, base_url, api_key_env)
  end

  defp build_globals(opts, defaults, interactive) do
    data_dir =
      opts[:data_dir] || maybe_prompt(interactive, "Session data directory", defaults["data_dir"])

    approval_policy =
      opts[:approval] ||
        maybe_prompt(
          interactive,
          "Risky tool policy (ask/deny/auto)",
          defaults["approval_policy"]
        )

    context_window =
      opts[:context_window] ||
        maybe_prompt(
          interactive,
          "Model context window in estimated tokens",
          Integer.to_string(defaults["context_window_tokens"])
        )

    compact_at =
      opts[:compact_at] ||
        maybe_prompt(
          interactive,
          "Compact context at percent",
          Integer.to_string(defaults["compaction_threshold_percent"])
        )

    globals = %{
      "approval_policy" => approval_policy,
      "model_strategy" => opts[:model_strategy] || defaults["model_strategy"],
      "team_mode" => opts[:team_mode] || defaults["team_mode"],
      "max_workers" => opts[:max_workers] || defaults["max_workers"],
      "model_concurrency" => opts[:model_concurrency] || defaults["model_concurrency"],
      "data_dir" => Path.expand(data_dir),
      "context_window_tokens" => parse_integer(context_window),
      "compaction_threshold_percent" => parse_integer(compact_at),
      "memory_enabled" => defaults["memory_enabled"],
      "memory_max_entries" => defaults["memory_max_entries"],
      "memory_max_bytes" => defaults["memory_max_bytes"]
    }

    {:ok, globals}
  end

  defp run_command(config_path, args, require_existing? \\ false) do
    with {:ok, opts, prompt_parts} <- parse(args, @run_switches),
         :ok <- validate_frontend(opts[:frontend]),
         {:ok, stored_config} <- Config.load(config_path),
         {:ok, config} <- Config.runtime(stored_config, opts[:profile]),
         config <- Config.merge_overrides(config, opts),
         config <-
           Map.put(config, "model_endpoints", Config.model_endpoints(stored_config, config)),
         config <- Map.put(config, "workspace_root", Path.expand(opts[:workspace] || File.cwd!())),
         :ok <- Config.validate_runtime(config),
         :ok <- require_existing_session(opts[:session], config, require_existing?),
         {:ok, provider} <- Config.provider_atom(config["provider"]),
         :ok <- ensure_application_started(),
         {:ok, session_id} <- ensure_session(opts[:session], config, provider) do
      prompt = Enum.join(prompt_parts, " ")

      if prompt == "" do
        {:ok, endpoint} = publish_local_session(session_id, config, config_path)

        try do
          if TUI.available?(opts[:tui], opts[:frontend]) do
            case TUI.run(session_id, Map.put(config, "frontend", opts[:frontend]), config_path) do
              :ok -> 0
              {:error, reason} -> error(reason)
            end
          else
            UI.session_header(config, session_id)
            chat_loop(session_id, config, config_path)
          end
        after
          DynamicSupervisor.terminate_child(BeamAgent.LocalEndpointSupervisor, endpoint)
        end
      else
        UI.one_shot_header(config, session_id)
        ask_and_print(session_id, prompt)
      end
    else
      {:error, reason} -> error(reason)
    end
  end

  defp serve_command(config_path, session_id, args) do
    switches = [
      profile: :string,
      workspace: :string,
      web_port: :integer,
      api_port: :integer,
      token: :string
    ]

    with {:ok, opts, []} <- parse(args, switches),
         {:ok, stored_config} <- Config.load(config_path),
         {:ok, config} <- Config.runtime(stored_config, opts[:profile]),
         config <-
           Map.put(config, "model_endpoints", Config.model_endpoints(stored_config, config)),
         config <- Map.put(config, "workspace_root", Path.expand(opts[:workspace] || File.cwd!())),
         :ok <- Config.validate_runtime(config),
         :ok <- require_existing_session(session_id, config, true),
         {:ok, provider} <- Config.provider_atom(config["provider"]),
         :ok <- ensure_application_started(),
         {:ok, ^session_id} <- ensure_session(session_id, config, provider),
         token <- opts[:token] || api_token(),
         {:ok, web} <-
           BeamAgent.start_web_control_plane(session_id,
             port: opts[:web_port] || 0,
             token: token
           ),
         {:ok, api} <-
           BeamAgent.start_json_api(session_id,
             port: opts[:api_port] || 0,
             token: token
           ),
         {:ok, url} <- BeamAgent.ControlPlane.HTTPServer.url(web),
         {:ok, {{127, 0, 0, 1}, api_port}} <- BeamAgent.Runtime.JSONLineServer.address(api) do
      output("Web control plane  #{url}")
      output("JSON-lines API    127.0.0.1:#{api_port}")
      output("Press Ctrl+C to stop these interface servers; the goal remains durable.")

      receive do
        :shutdown -> 0
      end
    else
      {:ok, _opts, positional} ->
        usage_error("unexpected arguments: #{Enum.join(positional, " ")}")

      {:error, reason} ->
        error(reason)
    end
  end

  defp desk_command(config_path, args) do
    # The first-run wizard is shared with the terminal workflow.
    if match?({:error, {:not_initialized, _}}, Config.load(config_path)) do
      case init_command(config_path, []) do
        0 -> desk_command(config_path, args)
        status -> status
      end
    else
      with {:ok, opts, []} <- parse(args, @run_switches ++ [port: :integer, open: :boolean]),
           :ok <- validate_frontend(opts[:frontend]),
           :ok <- validate_desk_tui(opts),
           true <- is_nil(opts[:port]) or opts[:port] in 0..65535,
           {:ok, stored} <- Config.load(config_path),
           {:ok, config} <- Config.runtime(stored, opts[:profile]),
           config <- Config.merge_overrides(config, opts),
           config <- Map.put(config, "model_endpoints", Config.model_endpoints(stored, config)),
           config <-
             Map.put(config, "workspace_root", Path.expand(opts[:workspace] || File.cwd!())),
           :ok <- Config.validate_runtime(config),
           :ok <- ensure_application_started(),
           {:ok, id, owner?} <- desk_session(opts, config, config_path) do
        try do
          opts =
            Keyword.merge(opts,
              catalog_config: config,
              config_path: config_path,
              initial_session: id
            )

          launch_opts =
            if opts[:tui] do
              Keyword.put(opts, :on_ready, fn ->
                if owner? do
                  TUI.run(id, Map.put(config, "frontend", opts[:frontend]), config_path)
                else
                  with {:ok, record} <- BeamAgent.LocalDiscovery.lookup(id),
                       do: TUI.attach(record, opts[:frontend])
                end
              end)
            else
              opts
            end

          case BeamAgent.CLI.Desk.run(id, launch_opts) do
            :ok -> 0
            {:error, reason} -> error(reason)
          end
        after
          if owner?, do: BeamAgent.stop_session(id)
        end
      else
        false -> usage_error("--port must be between 0 and 65535")
        {:ok, _, _} -> usage_error("desk accepts flags, not a prompt")
        {:error, reason} -> error(reason)
      end
    end
  end

  defp desk_session(opts, config, config_path) do
    cond do
      is_binary(opts[:session]) ->
        with {:ok, _} <- BeamAgent.LocalDiscovery.lookup(opts[:session]),
             do: {:ok, opts[:session], false}

      opts[:tui] == true ->
        with {:ok, id, _} <- create_local_session(config, config_path), do: {:ok, id, true}

      true ->
        {:ok, nil, false}
    end
  end

  @doc false
  def create_local_session(config, config_path) do
    with {:ok, provider} <- Config.provider_atom(config["provider"]),
         {:ok, id} <- ensure_session(nil, config, provider) do
      case publish_local_session(id, config, config_path) do
        {:ok, endpoint} ->
          case BeamAgent.Service.remember(id, config) do
            :ok ->
              {:ok, id, endpoint}

            error ->
              DynamicSupervisor.terminate_child(BeamAgent.LocalEndpointSupervisor, endpoint)
              BeamAgent.stop_session(id)
              error
          end

        error ->
          BeamAgent.stop_session(id)
          error
      end
    end
  end

  defp publish_local_session(id, config, config_path) do
    DynamicSupervisor.start_child(
      BeamAgent.LocalEndpointSupervisor,
      {BeamAgent.LocalEndpoint, session_id: id, config: config, config_path: config_path}
    )
  end

  @doc false
  def restore_local_session(id, saved, config_path) do
    case BeamAgent.LocalDiscovery.lookup(id) do
      {:ok, _} ->
        :ok

      _ ->
        with true <- BeamAgent.LocalDiscovery.valid_id?(id),
             true <- File.dir?(Path.join(saved["data_dir"], id)),
             {:ok, root} <- Workspace.canonical_root(saved["workspace_root"]),
             {:ok, stored} <- Config.load(config_path),
             {:ok, config} <- Config.runtime(stored, saved["profile"]),
             config =
               Map.merge(config, %{
                 "workspace_root" => root,
                 "data_dir" => saved["data_dir"],
                 "model_endpoints" => Config.model_endpoints(stored, config)
               }),
             {:ok, provider} <- Config.provider_atom(config["provider"]),
             :ok <- BeamAgent.LocalDiscovery.clear_stale(id),
             {:ok, ^id} <- ensure_session(id, config, provider),
             {:ok, _} <- publish_local_session(id, config, config_path),
             do: :ok,
             else: (_ -> {:error, :session_recovery_unavailable})
    end
  end

  defp validate_frontend(nil), do: :ok
  defp validate_frontend("rust"), do: :ok
  defp validate_frontend(_), do: {:error, "--frontend must be rust"}

  defp validate_desk_tui(opts) do
    if opts[:tui] == true and not TUI.available?(true, opts[:frontend]),
      do: {:error, "desk --tui needs an interactive terminal and a built TUI"},
      else: :ok
  end

  defp desk_help do
    output("""
    Open the local session control center in your browser

      loom desk [--workspace PATH] [--session ID]
      --no-open         print the one-time launch link without opening a browser
      --session ID      open an existing LIVE session without resuming its storage
      --tui             also open a TUI on the SAME live session (reuses workspace session)

    No exported variables or separate server terminals. The browser authenticates
    through a short-lived, single-use launch link; the runtime token stays private.
    Starts or connects to the per-user Loom service on macOS. This command exits;
    closing the tab or an attached TUI does not stop work. Run it again to renew login.
    Plain desk creates no work session. The overview discovers live CLI sessions.
    Older running binaries need one restart to publish their connection.
    Use loom attach SESSION_ID to attach a terminal without a second owner.
    loom service start|stop|status|logs manages the backend explicitly.
    loom service install opts into starting at login; uninstall removes that registration.
    --foreground retains the legacy terminal-owned launcher (supports --port PORT).
    One-time build: mix loom.build
    """)
  end

  defp api_token,
    do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp require_existing_session(_session_id, _config, false), do: :ok

  defp require_existing_session(session_id, config, true) do
    path = Path.join([config["data_dir"], session_id, "events.jsonl"])

    cond do
      not File.regular?(path) ->
        {:error, {:session_not_found, session_id}}

      match?({:ok, _}, BeamAgent.LocalDiscovery.lookup(session_id)) ->
        {:error, "Session is already live. Use loom attach #{session_id}, not resume."}

      true ->
        :ok
    end
  end

  defp ensure_session(nil, config, provider) do
    BeamAgent.start_session(
      Config.capacity_options(config) ++
        [
          provider: provider,
          strategy: BeamAgent.Strategies.ToolLoop,
          provider_options: Config.provider_options(config),
          provider_profile: config["profile"],
          data_dir: config["data_dir"],
          context_window_tokens: config["context_window_tokens"],
          compaction_threshold_percent: config["compaction_threshold_percent"],
          memory_enabled: config["memory_enabled"],
          memory_max_entries: config["memory_max_entries"],
          memory_max_bytes: config["memory_max_bytes"],
          workspace_root: config["workspace_root"],
          approval_policy: Config.approval_policy_atom(config["approval_policy"]),
          model_strategy: Config.model_strategy_atom(config["model_strategy"]),
          team_mode: Config.team_mode_atom(config["team_mode"]),
          approval_handler: self(),
          discover_models: true,
          model_endpoints: config["model_endpoints"] || []
        ]
    )
  end

  defp ensure_session(session_id, config, provider) do
    case BeamAgent.agent_pid(session_id) do
      {:ok, _pid} ->
        {:ok, session_id}

      {:error, :not_found} ->
        BeamAgent.resume_session(
          session_id,
          Config.capacity_options(config) ++
            [
              provider: provider,
              strategy: BeamAgent.Strategies.ToolLoop,
              provider_options: Config.provider_options(config),
              provider_profile: config["profile"],
              data_dir: config["data_dir"],
              context_window_tokens: config["context_window_tokens"],
              compaction_threshold_percent: config["compaction_threshold_percent"],
              memory_enabled: config["memory_enabled"],
              memory_max_entries: config["memory_max_entries"],
              memory_max_bytes: config["memory_max_bytes"],
              workspace_root: config["workspace_root"],
              approval_policy: Config.approval_policy_atom(config["approval_policy"]),
              model_strategy: Config.model_strategy_atom(config["model_strategy"]),
              team_mode: Config.team_mode_atom(config["team_mode"]),
              approval_handler: self(),
              discover_models: true,
              model_endpoints: config["model_endpoints"] || []
            ]
        )
    end
  end

  defp chat_loop(session_id, config, config_path) do
    case UI.prompt() do
      :eof ->
        0

      {:error, reason} ->
        error({:input_error, reason})

      input ->
        case String.trim(input) do
          "" ->
            chat_loop(session_id, config, config_path)

          "/exit" ->
            0

          "/quit" ->
            0

          "/help" ->
            UI.command_help()
            chat_loop(session_id, config, config_path)

          "/" ->
            UI.command_help()
            chat_loop(session_id, config, config_path)

          "/events" ->
            print_event_summary(session_id)
            chat_loop(session_id, config, config_path)

          "/tree" ->
            print_goal_tree(session_id)
            chat_loop(session_id, config, config_path)

          "/verify" ->
            verify_goal(session_id)
            chat_loop(session_id, config, config_path)

          "/status" ->
            print_status(session_id, config)
            chat_loop(session_id, config, config_path)

          "/models" ->
            print_session_models(session_id, config)
            chat_loop(session_id, config, config_path)

          "/models refresh" ->
            refresh_session_models(session_id, :all)
            chat_loop(session_id, config, config_path)

          "/models " <> endpoint_id ->
            refresh_session_models(session_id, endpoint_id)
            chat_loop(session_id, config, config_path)

          "/auto" ->
            chat_loop(session_id, toggle_auto_mode(session_id, config), config_path)

          "/connect" ->
            connect_chat(session_id, config, config_path, [])

          "/connect chatgpt" ->
            connect_chat(session_id, config, config_path, ["--chatgpt"])

          "/compact" ->
            compact_session_context(session_id)
            chat_loop(session_id, config, config_path)

          "/skills" ->
            print_session_skills(session_id)
            chat_loop(session_id, config, config_path)

          "/reload" ->
            reload_session_context(session_id)
            chat_loop(session_id, config, config_path)

          "/sessions" ->
            print_sessions(config)
            chat_loop(session_id, config, config_path)

          "/new" ->
            start_new_chat(config, session_id, config_path)

          "/clear" ->
            UI.clear()
            UI.session_header(config, session_id)
            chat_loop(session_id, config, config_path)

          "/model" ->
            print_status(session_id, config)
            chat_loop(session_id, config, config_path)

          "/" <> command ->
            UI.warning("Unknown command /#{command} · type /help")
            chat_loop(session_id, config, config_path)

          prompt ->
            _status = ask_and_print(session_id, prompt)
            chat_loop(session_id, config, config_path)
        end
    end
  end

  defp ask_and_print(session_id, prompt) do
    event_count = event_count(session_id)
    UI.begin_live_turn()

    result =
      TurnRunner.run_live(
        session_id,
        prompt,
        :infinity,
        &UI.approval/1,
        &UI.live_event/1
      )

    UI.end_live_turn()

    case result do
      {:ok, answer, meta} ->
        unless meta.live_tool_events?, do: render_new_tool_events(session_id, event_count)
        unless meta.streamed_text?, do: UI.assistant(answer)
        0

      {:error, reason, _meta} ->
        error(reason)
    end
  end

  defp event_count(session_id) do
    case BeamAgent.events(session_id) do
      {:ok, events} -> length(events)
      _ -> 0
    end
  end

  defp render_new_tool_events(session_id, previous_count) do
    case BeamAgent.events(session_id) do
      {:ok, events} -> events |> Enum.drop(previous_count) |> UI.tool_trace()
      _ -> :ok
    end
  end

  defp start_new_chat(config, previous_session_id, config_path) do
    with {:ok, provider} <- Config.provider_atom(config["provider"]),
         {:ok, session_id} <- ensure_session(nil, config, provider) do
      _ = BeamAgent.stop_session(previous_session_id)
      UI.notice("Started a new session")
      UI.session_header(config, session_id)
      chat_loop(session_id, config, config_path)
    else
      {:error, reason} ->
        _ = error(reason)
        chat_loop(previous_session_id, config, config_path)
    end
  end

  defp refresh_auth_config(config, config_path) do
    with {:ok, stored} <- Config.load(config_path),
         {:ok, runtime} <- Config.runtime(stored, config["profile"]) do
      config
      |> Map.put("credential_ref", runtime["credential_ref"])
      |> Map.put("auth", runtime["auth"])
      |> Map.put("model_endpoints", Config.model_endpoints(stored, runtime))
    else
      _error -> config
    end
  end

  defp connect_chat(session_id, config, config_path, auth_args) do
    case auth_login_command(config_path, config["profile"], auth_args) do
      0 -> start_new_chat(refresh_auth_config(config, config_path), session_id, config_path)
      _error -> chat_loop(session_id, config, config_path)
    end
  end

  defp print_event_summary(session_id) do
    with {:ok, events} <- BeamAgent.events(session_id),
         {:ok, path} <- BeamAgent.event_log_path(session_id) do
      output("#{length(events)} events at #{path}")
    else
      {:error, reason} -> error(reason)
    end
  end

  defp print_goal_tree(session_id) do
    with {:ok, goal} <- BeamAgent.goal(session_id),
         {:ok, tree} <- BeamAgent.goal_tree(goal.goal_id) do
      lines = BeamAgent.RuntimeGoalTree.render(tree)
      IO.puts("")
      output("Goal tree")
      Enum.each(lines, &output("  #{&1}"))
      IO.puts("")
      0
    else
      {:error, reason} -> error(reason)
    end
  end

  defp verify_goal(session_id) do
    with {:ok, goal} <- BeamAgent.goal(session_id),
         {:ok, result} <- BeamAgent.verify(goal.goal_id) do
      output("Verification #{result.status} · #{result.summary}")
    else
      {:error, reason} -> error(reason)
    end
  end

  defp print_status(session_id, config) do
    with {:ok, path} <- BeamAgent.event_log_path(session_id),
         {:ok, context} <- BeamAgent.context_snapshot(session_id),
         {:ok, context_stats} <- BeamAgent.conversation_context_stats(session_id),
         {:ok, approval_policy} <- BeamAgent.approval_policy(session_id) do
      config = Map.put(config, "approval_policy", to_string(approval_policy))
      UI.status(config, session_id, path, context, context_stats)
    else
      {:error, reason} -> error(reason)
    end
  end

  defp print_session_models(session_id, config) do
    with {:ok, identity} <- BeamAgent.Agent.runtime_identity(session_id),
         {:ok, endpoints} <- BeamAgent.models(identity.project_id),
         {:ok, evidence} <- BeamAgent.routing_evidence(identity.project_id) do
      IO.puts("")
      output("Model registry")

      Enum.each(endpoints, fn endpoint ->
        marker = if endpoint.id == config["profile"], do: "*", else: " "
        model = endpoint.model || "provider default"
        capabilities = endpoint.claims.capabilities |> Enum.map(&to_string/1) |> Enum.join(",")
        empirical = Enum.find(evidence.endpoints, &(&1.endpoint_id == endpoint.id))

        output(
          "#{marker} #{endpoint.id}  #{endpoint.provider}/#{model}  #{endpoint.claims.locality}  #{endpoint.health.status}  #{capabilities}#{cli_model_evidence(empirical)}"
        )
      end)

      IO.puts("")
      0
    else
      {:error, reason} -> error(reason)
    end
  end

  defp cli_model_evidence(nil), do: "  evidence=0 verified"

  defp cli_model_evidence(evidence) do
    pass_rate =
      if is_number(evidence.verified_pass_rate),
        do: " pass=#{round(evidence.verified_pass_rate * 100)}%",
        else: ""

    latency =
      if is_number(evidence.average_latency_ms),
        do: " latency=#{evidence.average_latency_ms}ms",
        else: ""

    "  evidence=#{evidence.verified_samples}/#{evidence.operational_samples}#{pass_rate}#{latency}"
  end

  defp refresh_session_models(session_id, endpoint_id) do
    with {:ok, identity} <- BeamAgent.Agent.runtime_identity(session_id),
         {:ok, endpoint_ids} <- BeamAgent.refresh_models(identity.project_id, endpoint_id) do
      UI.notice("Checking #{length(endpoint_ids)} model endpoints · run /models for status")
      0
    else
      {:error, reason} -> error(reason)
    end
  end

  defp toggle_auto_mode(session_id, config) do
    with {:ok, current} <- BeamAgent.approval_policy(session_id) do
      {next, config} = next_auto_policy(current, config)

      case BeamAgent.set_approval_policy(session_id, next) do
        :ok ->
          if next == :auto do
            UI.warning("Auto mode enabled · risky tool requests will be approved")
          else
            UI.success("Auto mode disabled · risky tools will ask for approval")
          end

          Map.put(config, "approval_policy", to_string(next))

        {:error, reason} ->
          _ = error(reason)
          config
      end
    else
      {:error, reason} ->
        _ = error(reason)
        config
    end
  end

  defp next_auto_policy(:auto, config) do
    policy =
      config
      |> Map.get("approval_policy_before_auto", "ask")
      |> Config.approval_policy_atom()

    policy = if policy == :auto, do: :ask, else: policy
    {policy, Map.delete(config, "approval_policy_before_auto")}
  end

  defp next_auto_policy(current, config) do
    {:auto, Map.put(config, "approval_policy_before_auto", to_string(current))}
  end

  defp compact_session_context(session_id) do
    case BeamAgent.compact_context(session_id) do
      {:ok, :compacted, stats} ->
        UI.success(
          "Context compacted · #{stats.estimated_tokens}/#{stats.window_tokens} estimated tokens"
        )

        0

      {:ok, :not_needed, stats} ->
        UI.notice(
          "Nothing to compact · #{stats.estimated_tokens}/#{stats.window_tokens} estimated tokens"
        )

        0

      {:error, reason} ->
        error(reason)
    end
  end

  defp print_session_skills(session_id) do
    case BeamAgent.skills(session_id) do
      {:ok, []} ->
        UI.notice("No project skills discovered")
        0

      {:ok, skills} ->
        IO.puts("")
        output("Skills")
        Enum.each(skills, &output("  #{&1.name}  #{&1.description}"))
        IO.puts("")
        0

      {:error, reason} ->
        error(reason)
    end
  end

  defp reload_session_context(session_id) do
    case BeamAgent.reload_context(session_id) do
      {:ok, summary} ->
        UI.success(
          "Context reloaded · #{summary.instruction_count} instructions · #{summary.skill_count} skills"
        )

        0

      {:error, reason} ->
        error(reason)
    end
  end

  defp doctor_command(config_path, args) do
    with {:ok, opts, []} <- parse(args, profile: :string),
         {:ok, stored_config} <- Config.load(config_path),
         {:ok, config} <- Config.runtime(stored_config, opts[:profile]),
         :ok <- ensure_application_started(),
         {:ok, provider} <- Config.provider_atom(config["provider"]),
         {:ok, module} <- BeamAgent.CapabilityCatalog.provider(provider),
         {:ok, detail} <- provider_healthcheck(module, Config.provider_options(config)),
         :ok <- File.mkdir_p(config["data_dir"]) do
      output("ok  config    #{config_path}")
      output("ok  profile   #{config["profile"]}")
      output("ok  provider  #{config["provider"]}: #{detail}")

      if notice = provider_tool_support_notice(module, Config.provider_options(config)) do
        output("warn tools     #{notice}")
      end

      output("ok  data      #{config["data_dir"]}")
      output("ok  runtime   Elixir #{System.version()} / OTP #{System.otp_release()}")
    else
      {:ok, _opts, positional} ->
        usage_error("unexpected arguments: #{Enum.join(positional, " ")}")

      {:error, reason} ->
        error(reason)
    end
  end

  defp provider_command(_config_path, [flag]) when flag in ["--help", "-h"],
    do: provider_help()

  defp provider_command(config_path, ["list" | rest]),
    do: provider_list_command(config_path, rest)

  defp provider_command(config_path, ["use", name | rest]),
    do: provider_use_command(config_path, name, rest)

  defp provider_command(config_path, ["add", name | rest]),
    do: provider_add_command(config_path, name, rest)

  defp provider_command(_config_path, []), do: provider_help()

  defp provider_command(_config_path, _args),
    do: usage_error("expected `provider add NAME`, `provider list`, or `provider use NAME`")

  defp auth_command(config_path, ["list" | rest]), do: auth_list_command(config_path, rest)

  defp auth_command(config_path, ["login", profile | rest]),
    do: auth_login_command(config_path, profile, rest)

  defp auth_command(config_path, ["logout", profile | rest]),
    do: auth_logout_command(config_path, profile, rest)

  defp auth_command(_config_path, []), do: auth_help()

  defp auth_command(_config_path, _args),
    do: usage_error("expected `auth login PROFILE`, `auth list`, or `auth logout PROFILE`")

  defp auth_list_command(config_path, args) do
    with {:ok, _opts, []} <- parse(args, []),
         {:ok, config} <- Config.load(config_path) do
      Enum.each(Config.profiles(config), fn {name, profile} ->
        method = get_in(profile, ["auth", "type"]) || "environment"
        connected = if profile_connected?(profile), do: "connected", else: "not connected"
        output("#{name}\t#{profile["provider"]}\t#{method}\t#{connected}")
      end)

      0
    else
      {:ok, _opts, positional} ->
        usage_error("unexpected arguments: #{Enum.join(positional, " ")}")

      {:error, reason} ->
        error(reason)
    end
  end

  defp auth_login_command(config_path, profile_name, args) do
    switches = [
      chatgpt: :boolean,
      api_key: :boolean,
      api_key_stdin: :boolean,
      device_endpoint: :string,
      token_endpoint: :string,
      client_id: :string,
      scope: :string,
      no_browser: :boolean
    ]

    with {:ok, opts, []} <- parse(args, switches),
         :ok <- validate_auth_login_options(opts),
         {:ok, config} <- Config.load(config_path),
         {:ok, profile} <- fetch_cli_profile(config, profile_name),
         :ok <- ensure_application_started() do
      cond do
        device_login?(opts, profile) ->
          auth_device_login(config_path, config, profile_name, profile, opts)

        chatgpt_login?(opts, profile) ->
          auth_chatgpt_login(config_path, config, profile_name, profile, opts)

        true ->
          auth_api_key_login(config_path, config, profile_name, profile, opts)
      end
    else
      {:ok, _opts, positional} ->
        usage_error("unexpected arguments: #{Enum.join(positional, " ")}")

      {:error, reason} ->
        error(reason)
    end
  end

  defp auth_chatgpt_login(config_path, config, profile_name, profile, opts) do
    with :ok <- require_openai_profile(profile),
         {:ok, session} <-
           BeamAgent.Auth.start_chatgpt_login(profile_name, :openai, owner: self()),
         {:ok, action} <- await_auth_action(session),
         :ok <- present_auth_action(action, opts),
         {:ok, result} <- BeamAgent.Auth.await(session),
         {:ok, config} <-
           Config.put_profile_auth(config, profile_name, nil, result.auth),
         {:ok, ^config_path} <- Config.write(config, config_path) do
      plan = if result.plan_type, do: " (#{result.plan_type})", else: ""
      UI.success("Connected #{profile_name} through ChatGPT#{plan}")
      0
    else
      {:error, reason} -> error(reason)
    end
  end

  defp auth_api_key_login(config_path, config, profile_name, profile, opts) do
    secret =
      cond do
        opts[:api_key_stdin] -> IO.read(:stdio, :eof) |> normalize_secret()
        opts[:api_key] -> UI.secret("API key")
        true -> UI.secret("API key")
      end

    with secret when is_binary(secret) and secret != "" <- secret,
         {:ok, reference} <-
           BeamAgent.Auth.login_api_key(profile_name, profile["provider"], secret),
         {:ok, config} <-
           Config.put_profile_auth(config, profile_name, reference, %{"type" => "api_key"}),
         {:ok, ^config_path} <- Config.write(config, config_path) do
      UI.success("Stored credential for #{profile_name} in the operating-system keyring")
      0
    else
      nil ->
        error(:empty_api_key)

      "" ->
        error(:empty_api_key)

      {:error, reason} ->
        _ = BeamAgent.Auth.logout(profile_name)
        error(reason)
    end
  end

  defp auth_device_login(config_path, config, profile_name, profile, opts) do
    with {:ok, auth} <- device_auth(profile, opts),
         {:ok, session} <-
           BeamAgent.Auth.start_device_login(profile_name, profile["provider"],
             device_endpoint: auth["device_endpoint"],
             token_endpoint: auth["token_endpoint"],
             client_id: auth["client_id"],
             scope: auth["scope"],
             owner: self()
           ),
         {:ok, action} <- await_auth_action(session),
         :ok <- present_auth_action(action, opts),
         {:ok, result} <- BeamAgent.Auth.await(session),
         {:ok, config} <-
           Config.put_profile_auth(
             config,
             profile_name,
             result.credential_reference,
             auth
           ),
         {:ok, ^config_path} <- Config.write(config, config_path) do
      UI.success("Connected #{profile_name} through browser authorization")
      0
    else
      {:error, reason} ->
        error(reason)
    end
  end

  defp auth_logout_command(config_path, profile_name, args) do
    with {:ok, _opts, []} <- parse(args, []),
         {:ok, config} <- Config.load(config_path),
         {:ok, profile} <- fetch_cli_profile(config, profile_name),
         :ok <- ensure_application_started(),
         :ok <- logout_profile(profile_name, config),
         {:ok, config} <- Config.clear_profile_auth(config, profile_name),
         {:ok, ^config_path} <- Config.write(config, config_path) do
      UI.success(logout_message(profile_name, profile))
      0
    else
      {:ok, _opts, positional} ->
        usage_error("unexpected arguments: #{Enum.join(positional, " ")}")

      {:error, reason} ->
        error(reason)
    end
  end

  defp device_login?(opts, profile) do
    is_binary(opts[:device_endpoint]) or get_in(profile, ["auth", "type"]) == "device_code"
  end

  defp validate_auth_login_options(opts) do
    explicit_methods =
      [
        opts[:chatgpt] == true,
        opts[:api_key] == true,
        opts[:api_key_stdin] == true,
        is_binary(opts[:device_endpoint])
      ]
      |> Enum.count(& &1)

    if explicit_methods <= 1,
      do: :ok,
      else: {:error, :conflicting_authentication_methods}
  end

  defp chatgpt_login?(opts, profile) do
    opts[:chatgpt] == true or
      (profile["provider"] == "openai" and opts[:api_key] != true and
         opts[:api_key_stdin] != true)
  end

  defp require_openai_profile(%{"provider" => "openai"}), do: :ok

  defp require_openai_profile(profile),
    do: {:error, {:chatgpt_login_not_supported, profile["provider"]}}

  defp logout_profile(profile_name, config) do
    profile = get_in(config, ["profiles", profile_name]) || %{}

    case get_in(profile, ["auth", "type"]) do
      "chatgpt" -> :ok
      _ -> BeamAgent.Auth.logout(profile_name)
    end
  end

  defp logout_message(profile_name, %{"auth" => %{"type" => "chatgpt"}}) do
    "Disconnected #{profile_name}; the shared Codex login remains available"
  end

  defp logout_message(profile_name, _profile), do: "Removed stored credential for #{profile_name}"

  defp profile_connected?(%{"auth" => %{"type" => "chatgpt"}}) do
    match?(
      {:ok, %{"account" => %{"type" => "chatgpt"}}},
      BeamAgent.CodexAppServer.account()
    )
  end

  defp profile_connected?(profile), do: is_binary(profile["credential_ref"])

  defp device_auth(profile, opts) do
    existing = profile["auth"] || %{}

    auth = %{
      "type" => "device_code",
      "device_endpoint" => opts[:device_endpoint] || existing["device_endpoint"],
      "token_endpoint" => opts[:token_endpoint] || existing["token_endpoint"],
      "client_id" => opts[:client_id] || existing["client_id"],
      "scope" => opts[:scope] || existing["scope"]
    }

    with true <- present?(auth["device_endpoint"]),
         true <- present?(auth["token_endpoint"]),
         true <- present?(auth["client_id"]) do
      {:ok, auth}
    else
      false -> {:error, :incomplete_device_auth_configuration}
    end
  end

  defp await_auth_action(session) do
    receive do
      {:beam_agent_auth, ^session, %{type: :auth_user_action_required, data: action}} ->
        {:ok, action}

      {:beam_agent_auth, ^session, %{type: :auth_failed, data: data}} ->
        {:error, {:authentication_failed, data.reason}}
    after
      60_000 ->
        _ = BeamAgent.Auth.cancel(session)
        {:error, :authentication_start_timeout}
    end
  end

  defp present_auth_action(action, opts) do
    UI.notice("Open #{action.verification_uri}")
    if action.user_code, do: UI.notice("Enter code: #{action.user_code}")

    if opts[:no_browser] != true do
      _ = open_browser(action.verification_uri_complete || action.verification_uri)
    end

    :ok
  end

  defp open_browser(url) do
    executable =
      case :os.type() do
        {:unix, :darwin} -> System.find_executable("open")
        _ -> System.find_executable("xdg-open")
      end

    if executable do
      Task.start(fn -> System.cmd(executable, [url], stderr_to_stdout: true) end)
      :ok
    else
      {:error, :browser_launcher_unavailable}
    end
  end

  defp fetch_cli_profile(config, profile_name) do
    case get_in(config, ["profiles", profile_name]) do
      profile when is_map(profile) -> {:ok, profile}
      _ -> {:error, {:unknown_profile, profile_name}}
    end
  end

  defp normalize_secret(:eof), do: nil
  defp normalize_secret(secret) when is_binary(secret), do: String.trim(secret)
  defp normalize_secret(_secret), do: nil

  defp present?(value), do: is_binary(value) and value != ""

  defp provider_list_command(config_path, args) do
    with {:ok, _opts, []} <- parse(args, []),
         {:ok, config} <- Config.load(config_path) do
      Enum.each(Config.profiles(config), fn {name, profile} ->
        marker = if name == config["active_profile"], do: "*", else: " "
        model = if profile["model"], do: "  #{profile["model"]}", else: ""
        output("#{marker} #{name}  #{profile["provider"]}#{model}")
      end)

      0
    else
      {:ok, _opts, positional} ->
        usage_error("unexpected arguments: #{Enum.join(positional, " ")}")

      {:error, reason} ->
        error(reason)
    end
  end

  defp provider_use_command(config_path, name, args) do
    with {:ok, _opts, []} <- parse(args, []),
         {:ok, config} <- Config.load(config_path),
         {:ok, config} <- Config.use_profile(config, name),
         {:ok, ^config_path} <- Config.write(config, config_path) do
      UI.success("Active provider profile: #{name}")
      0
    else
      {:ok, _opts, positional} ->
        usage_error("unexpected arguments: #{Enum.join(positional, " ")}")

      {:error, reason} ->
        error(reason)
    end
  end

  defp provider_add_command(config_path, name, args) do
    switches = [
      provider: :string,
      model: :string,
      base_url: :string,
      api_key_env: :string,
      activate: :boolean,
      force: :boolean,
      non_interactive: :boolean
    ]

    with {:ok, opts, []} <- parse(args, switches),
         {:ok, config} <- Config.load(config_path),
         {:ok, active} <- Config.runtime(config),
         interactive = opts[:non_interactive] != true,
         {:ok, provider} <-
           resolve_profile_provider(opts[:provider], name, active["provider"], interactive),
         {:ok, provider_config} <- BeamAgent.Providers.fetch(provider),
         {:ok, profile} <- build_profile(opts, provider, provider_config, interactive),
         {:ok, config} <-
           Config.put_profile(config, name, profile,
             force: opts[:force] == true,
             activate: opts[:activate] == true
           ),
         {:ok, ^config_path} <- Config.write(config, config_path) do
      UI.success("Provider profile saved: #{name}")
      if opts[:activate] == true, do: UI.notice("Active profile is now #{name}")
      0
    else
      {:ok, _opts, positional} ->
        usage_error("unexpected arguments: #{Enum.join(positional, " ")}")

      {:error, reason} ->
        error(reason)
    end
  end

  defp resolve_profile_provider(provider, _name, _default, _interactive)
       when is_binary(provider),
       do: {:ok, provider}

  defp resolve_profile_provider(nil, name, default, interactive) do
    case BeamAgent.Providers.fetch(name) do
      {:ok, _provider} -> {:ok, name}
      {:error, _reason} when interactive -> {:ok, choose_provider(true, default)}
      {:error, _reason} -> {:error, {:provider_required, name}}
    end
  end

  defp providers_command(args) do
    with {:ok, _opts, []} <- parse(args, []),
         :ok <- ensure_application_started() do
      BeamAgent.CapabilityCatalog.providers()
      |> Enum.sort_by(& &1.id())
      |> Enum.each(fn module ->
        config =
          if function_exported?(module, :configuration, 0) do
            module.configuration()
          else
            %{name: to_string(module.id()), label: "custom provider"}
          end

        output("#{config.name}\t#{config.label}\t#{inspect(module)}")
      end)

      0
    else
      {:ok, _opts, positional} ->
        usage_error("unexpected arguments: #{Enum.join(positional, " ")}")

      {:error, reason} ->
        error(reason)
    end
  end

  defp tools_command(args) do
    with {:ok, _opts, []} <- parse(args, []),
         :ok <- ensure_application_started() do
      BeamAgent.CapabilityCatalog.tool_schemas()
      |> Enum.sort_by(& &1.name)
      |> Enum.each(fn tool -> output("#{tool.name}\t#{tool.description}") end)

      0
    else
      {:ok, _opts, positional} ->
        usage_error("unexpected arguments: #{Enum.join(positional, " ")}")

      {:error, reason} ->
        error(reason)
    end
  end

  defp skills_command(args) do
    with {:ok, opts, []} <- parse(args, workspace: :string),
         {:ok, workspace} <- Workspace.canonical_root(opts[:workspace] || File.cwd!()),
         {:ok, context} <- ProjectContext.load(workspace) do
      if context.skills == [] do
        UI.notice("No project skills discovered in #{workspace}")
      else
        Enum.each(context.skills, fn skill ->
          output("#{skill.name}\t#{skill.path}\t#{skill.description}")
        end)
      end

      Enum.each(context.warnings, fn warning ->
        UI.warning("#{warning.path}: #{warning.reason}")
      end)

      0
    else
      {:ok, _opts, positional} ->
        usage_error("unexpected arguments: #{Enum.join(positional, " ")}")

      {:error, reason} ->
        error(reason)
    end
  end

  defp sessions_command(config_path, args) do
    with {:ok, _opts, []} <- parse(args, []),
         {:ok, config} <- Config.load(config_path) do
      print_sessions(config)
    else
      {:error, :enoent} ->
        output("No sessions.")

      {:ok, _opts, positional} ->
        usage_error("unexpected arguments: #{Enum.join(positional, " ")}")

      {:error, reason} ->
        error(reason)
    end
  end

  defp print_sessions(config) do
    case File.ls(config["data_dir"]) do
      {:ok, entries} ->
        sessions =
          entries
          |> Enum.filter(&File.regular?(Path.join([config["data_dir"], &1, "events.jsonl"])))
          |> Enum.sort()

        if sessions == [] do
          UI.notice("No saved sessions")
        else
          IO.puts("")
          output("Sessions")
          Enum.each(sessions, &output("  #{&1}"))
          IO.puts("")
        end

        0

      {:error, :enoent} ->
        UI.notice("No saved sessions")
        0

      {:error, reason} ->
        error(reason)
    end
  end

  defp config_show(config_path) do
    case Config.load(config_path) do
      {:ok, config} -> output_config(config)
      {:error, reason} -> error(reason)
    end
  end

  defp output_config(config) do
    {:ok, active} = Config.runtime(config)
    output("active:     #{config["active_profile"]}")
    output("provider:   #{active["provider"]}")
    if active["model"], do: output("model:      #{active["model"]}")
    if active["base_url"], do: output("base_url:   #{active["base_url"]}")

    if active["api_key_env"],
      do: output("api_key:    environment #{active["api_key_env"]}")

    if active["credential_ref"],
      do: output("credential: #{active["credential_ref"]}")

    Enum.each(Config.profiles(config), fn {name, profile} ->
      marker = if name == config["active_profile"], do: "*", else: "-"
      model = if profile["model"], do: "/#{profile["model"]}", else: ""
      output("profile:    #{marker} #{name}  #{profile["provider"]}#{model}")
    end)

    output("approval:   #{config["approval_policy"]}")
    output("routing:    #{config["model_strategy"]}")
    output("data_dir:   #{config["data_dir"]}")
    output("context:    #{config["context_window_tokens"]} tokens")
    output("compact_at: #{config["compaction_threshold_percent"]}%")
  end

  defp ensure_replacement_allowed(config_path, force?) do
    if File.exists?(config_path) and force? != true,
      do: {:error, {:config_exists, config_path}},
      else: :ok
  end

  defp maybe_show_setup_header(opts) do
    if opts[:non_interactive] == true, do: :ok, else: UI.setup_header()
  end

  defp ensure_application_started do
    case Application.ensure_all_started(:beam_agent) do
      {:ok, _applications} -> :ok
      {:error, reason} -> {:error, {:application_start_failed, reason}}
    end
  end

  defp provider_healthcheck(module, options) do
    if function_exported?(module, :healthcheck, 1) do
      case module.healthcheck(options) do
        :ok -> {:ok, "ready"}
        {:ok, detail} -> {:ok, detail}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, "no provider-specific check"}
    end
  end

  defp provider_tool_support_notice(module, options) do
    if function_exported?(module, :tool_support_notice, 1),
      do: module.tool_support_notice(options),
      else: nil
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp choose_provider(false, default), do: default

  defp choose_provider(true, default) do
    preferred_order = ["ollama", "openai", "anthropic", "xai", "demo", "echo"]
    configurations = BeamAgent.Providers.configurations()

    providers =
      preferred_order
      |> Enum.filter(&Map.has_key?(configurations, &1))
      |> Enum.map(&Map.fetch!(configurations, &1))

    UI.choose_provider(providers, default)
  end

  defp maybe_prompt(false, _label, default), do: default

  defp maybe_prompt(true, label, default) do
    suffix = if default, do: " [#{default}]", else: ""

    case IO.gets("#{label}#{suffix}: ") do
      :eof -> default
      input -> if String.trim(input) == "", do: default, else: String.trim(input)
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> value
    end
  end

  defp parse(args, switches) do
    case OptionParser.parse(args, strict: switches, aliases: [h: :help]) do
      {opts, positional, []} -> {:ok, opts, positional}
      {_opts, _positional, invalid} -> {:error, {:invalid_options, invalid}}
    end
  end

  defp extract_config_path(args) do
    do_extract_config_path(args, Config.path(), [])
  end

  defp do_extract_config_path([], config_path, acc), do: {config_path, Enum.reverse(acc)}

  defp do_extract_config_path(["--config", path | rest], _config_path, acc),
    do: do_extract_config_path(rest, Path.expand(path), acc)

  defp do_extract_config_path(["--config=" <> path | rest], _config_path, acc),
    do: do_extract_config_path(rest, Path.expand(path), acc)

  defp do_extract_config_path([arg | rest], config_path, acc),
    do: do_extract_config_path(rest, config_path, [arg | acc])

  defp help do
    output("""
    Loom #{@version}

    Start here:
      loom                             connect a TUI to your workspace in the service
      loom tui                         connect a TUI (explicit command)
      loom desk                        open/reconnect Loom Desk; service stays running
      loom diagnostics --help          capture or control runtime incident recording
      loom service --help              start, stop, inspect or install the backend
      loom attach SESSION_ID           attach a TUI to an existing live runtime
      loom document --help             guarded Word editing and verification
      loom mission --help              opt-in read-only documentation observer
      loom run "your prompt"           run once and exit
      loom resume SESSION              continue a saved session
      loom serve SESSION               web control plane + JSON API

    Setup and inspect:
      loom init                        configure a provider
      loom doctor                      check the active provider
      loom provider list               list configured provider profiles
      loom provider add NAME           add a provider profile
      loom provider use NAME           change the active profile
      loom auth login PROFILE          connect with an API key or browser code
      loom auth list                   list profile authentication methods
      loom auth logout PROFILE         remove a stored credential
      loom sessions                    list durable sessions
      loom providers                   list available providers
      loom tools                       list model-callable tools
      loom skills                      list project skills in this workspace
      loom config show                 show active configuration
      loom config path                 show configuration path

    Common options:
      --provider NAME                        demo, echo, ollama, openai,
                                             anthropic, xai, or grok
      --profile NAME                         configured profile for this run
      --model MODEL                          model used for this session
      --config PATH                          use another configuration file
      --base-url URL                         override the provider endpoint
      --api-key-env VARIABLE                 credential environment variable
      --workspace PATH                       root visible to file and command tools
      --approval ask|auto|deny               risky tool policy (`allow` is an alias)
      --model-strategy auto|manual|local_only intelligence routing policy
      --team-mode auto|solo  task-based delegation independent of the selected model
      --max-workers N       concurrent subagents per goal (default: 4; extras queue)
      --model-concurrency N  slots per project model pool (default: 4)
      --context-window TOKENS                estimated model context capacity
      --compact-at PERCENT                   automatic compaction threshold
      --no-tui                               use the line-oriented interactive UI
      --frontend rust                        select the TUI frontend (default: rust/ION)

    Running `loom init` opens a guided setup. For automated setup, add
    --non-interactive and provide provider/model flags explicitly.
    """)
  end

  defp init_help do
    output("""
    Configure Loom

      loom init [options]

      --provider NAME        demo, echo, ollama, openai, anthropic, xai, or grok
      --profile NAME         name for the initial provider profile
      --model MODEL          required for real LLM providers
      --base-url URL         provider endpoint or compatible proxy
      --api-key-env NAME     environment variable containing the credential
      --approval POLICY      ask, deny, or auto-approve risky tools
      --model-strategy MODE  auto, manual, or local_only
      --team-mode MODE       auto or solo; independent of model routing
      --max-workers N       concurrent subagents per goal (default: 4)
      --model-concurrency N  slots per project model pool (default: 4)
      --data-dir PATH        durable session directory
      --context-window N     estimated model context capacity in tokens
      --compact-at PERCENT   automatic compaction threshold (50-95)
      --non-interactive      do not prompt; validate supplied/default values
      --force                replace an existing configuration
    """)
  end

  defp provider_help do
    output("""
    Manage provider profiles

      loom provider list
      loom provider add NAME [options]
      loom provider use NAME

      --provider ADAPTER     ollama, openai, anthropic, xai, grok, demo, or echo
      --model MODEL          required for real LLM providers
      --base-url URL         provider endpoint or compatible proxy
      --api-key-env NAME     environment variable containing the credential
      --activate             make the new profile active
      --non-interactive      validate supplied/default values without prompts
      --force                replace a profile with the same name

    Secrets are never written to the config; it stores environment-variable names
    or opaque operating-system keyring references.
    Use `--profile NAME` on run or doctor to select a profile without changing the active one.
    """)
  end

  defp auth_help do
    output("""
    Authenticate provider profiles

      loom auth login PROFILE --api-key
      loom auth login PROFILE --api-key-stdin
      loom auth login PROFILE --chatgpt
      loom auth login PROFILE --device-endpoint URL \\
        --token-endpoint URL --client-id ID [--scope SCOPES]
      loom auth list
      loom auth logout PROFILE

      --api-key             read an API key without terminal echo
      --api-key-stdin       read an API key from standard input
      --chatgpt             open OpenAI browser login for ChatGPT plan access
      --device-endpoint     OAuth 2.0 device authorization endpoint
      --token-endpoint      OAuth token endpoint
      --client-id           registered public OAuth client identifier
      --scope               provider-defined OAuth scopes
      --no-browser          print the verification URL without opening it

    API keys are stored in the operating-system keyring. OpenAI ChatGPT login is
    owned by Codex App Server, which persists and refreshes its credential.
    Configuration, events, prompts, and agent state never contain token values.
    Device login is available only when the provider permits a registered
    third-party OAuth client; API-key environments remain supported.
    """)
  end

  defp run_help do
    output("""
    Chat with beam agent

      loom run [options] [prompt]

    Omit the prompt for interactive chat. Supplying one runs a single turn and
    exits. Provider, model, endpoint, limits, and session storage can be
    overridden with the common options shown by `loom help`. Interactive
    chat opens the full-screen TUI on a capable terminal; use `--no-tui` for the
    line-oriented fallback.
    """)
  end

  defp resume_help do
    output("""
    Resume a durable session

      loom resume SESSION [prompt]

    Use `loom sessions` to find session IDs. Omit the prompt to continue
    interactively.
    """)
  end

  defp serve_help do
    output("""
    Serve a durable session through interface-neutral runtime clients

      loom serve SESSION [options]

      --web-port PORT       loopback web-control-plane port (default: dynamic)
      --api-port PORT       loopback JSON-lines API port (default: dynamic)
      --token TOKEN         shared bearer token (default: generated)
      --profile NAME        configured provider profile used when resuming
      --workspace PATH      immutable repository root for the resumed session

    Both listeners bind only to 127.0.0.1. Closing them does not stop the goal.
    """)
  end

  defp usage_error(message) do
    IO.puts(:stderr, "error: #{message}\nRun `loom help` for usage.")
    2
  end

  defp error({:not_initialized, path}) do
    IO.puts(
      :stderr,
      "error: Loom is not configured. Run `loom init --config #{path}`."
    )

    1
  end

  defp error({:config_exists, path}) do
    IO.puts(:stderr, "error: configuration already exists at #{path}; use --force to replace it")
    1
  end

  defp error({:unsupported_provider, provider}) do
    IO.puts(:stderr, "error: unsupported provider #{inspect(provider)}")
    1
  end

  defp error({:invalid_config_value, name}) do
    IO.puts(:stderr, "error: invalid configuration value for #{name}")
    1
  end

  defp error({:missing_api_key, env}) do
    IO.puts(:stderr, "error: environment variable #{env} is not set")
    1
  end

  defp error({:ollama_model_not_found, model, installed}) do
    IO.puts(
      :stderr,
      "error: Ollama model #{inspect(model)} is not installed; available: #{Enum.join(installed, ", ")}"
    )

    1
  end

  defp error({:chatgpt_model_unavailable, model, available}) do
    IO.puts(
      :stderr,
      "error: ChatGPT model #{inspect(model)} is unavailable; available: #{Enum.join(available, ", ")}. " <>
        "Run with --model MODEL or update the provider profile."
    )

    1
  end

  defp error({:invalid_options, invalid}) do
    IO.puts(:stderr, "error: invalid options #{inspect(invalid)}")
    2
  end

  defp error({:session_not_found, session_id}) do
    IO.puts(:stderr, "error: durable session #{inspect(session_id)} was not found")
    1
  end

  defp error({:unknown_profile, name}) do
    IO.puts(
      :stderr,
      "error: provider profile #{inspect(name)} was not found; run `loom provider list`"
    )

    1
  end

  defp error({:profile_exists, name}) do
    IO.puts(
      :stderr,
      "error: provider profile #{inspect(name)} already exists; use --force to replace it"
    )

    1
  end

  defp error({:provider_required, name}) do
    IO.puts(
      :stderr,
      "error: profile #{inspect(name)} is not a provider name; supply --provider ADAPTER"
    )

    1
  end

  defp error({:invalid_profile_name, name}) do
    IO.puts(:stderr, "error: invalid provider profile name #{inspect(name)}")
    1
  end

  defp error(reason) do
    IO.puts(:stderr, "error: #{inspect(reason)}")
    1
  end

  defp output(message) do
    IO.puts(message)
    0
  end
end
