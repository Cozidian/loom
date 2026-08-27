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
    context_window: :integer,
    compact_at: :integer,
    tui: :boolean
  ]

  def main(args) do
    status = run(args)
    if status != 0, do: System.halt(status)
  end

  def run(args) do
    {config_path, args} = extract_config_path(args)

    case args do
      [] ->
        default_command(config_path)

      ["init", flag] when flag in ["--help", "-h"] ->
        init_help()

      ["run", flag] when flag in ["--help", "-h"] ->
        run_help()

      ["resume", flag] when flag in ["--help", "-h"] ->
        resume_help()

      ["run" | rest] ->
        run_command(config_path, rest)

      ["resume", session_id | rest] ->
        run_command(config_path, ["--session", session_id | rest], true)

      ["init" | rest] ->
        init_command(config_path, rest)

      ["doctor" | rest] ->
        doctor_command(config_path, rest)

      ["providers" | rest] ->
        providers_command(rest)

      ["provider" | rest] ->
        provider_command(config_path, rest)

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
        output("beam_agent #{@version}")

      ["--" <> _option | _rest] ->
        run_command(config_path, args)

      [unknown | _rest] ->
        usage_error("unknown command #{inspect(unknown)}")
    end
  end

  defp default_command(config_path) do
    case Config.load(config_path) do
      {:ok, _config} ->
        run_command(config_path, [])

      {:error, {:not_initialized, ^config_path}} ->
        case init_command(config_path, []) do
          0 -> run_command(config_path, [])
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
      "data_dir" => Path.expand(data_dir),
      "context_window_tokens" => parse_integer(context_window),
      "compaction_threshold_percent" => parse_integer(compact_at)
    }

    {:ok, globals}
  end

  defp run_command(config_path, args, require_existing? \\ false) do
    with {:ok, opts, prompt_parts} <- parse(args, @run_switches),
         {:ok, stored_config} <- Config.load(config_path),
         {:ok, config} <- Config.runtime(stored_config, opts[:profile]),
         config <- Config.merge_overrides(config, opts),
         config <- Map.put(config, "workspace_root", Path.expand(opts[:workspace] || File.cwd!())),
         :ok <- Config.validate_runtime(config),
         :ok <- require_existing_session(opts[:session], config, require_existing?),
         {:ok, provider} <- Config.provider_atom(config["provider"]),
         :ok <- ensure_application_started(),
         {:ok, session_id} <- ensure_session(opts[:session], config, provider) do
      prompt = Enum.join(prompt_parts, " ")

      if prompt == "" do
        if TUI.available?(opts[:tui]) do
          case TUI.run(session_id, config) do
            :ok -> 0
            {:error, reason} -> error(reason)
          end
        else
          UI.session_header(config, session_id)
          chat_loop(session_id, config)
        end
      else
        UI.one_shot_header(config, session_id)
        ask_and_print(session_id, prompt)
      end
    else
      {:error, reason} -> error(reason)
    end
  end

  defp require_existing_session(_session_id, _config, false), do: :ok

  defp require_existing_session(session_id, config, true) do
    path = Path.join([config["data_dir"], session_id, "events.jsonl"])
    if File.regular?(path), do: :ok, else: {:error, {:session_not_found, session_id}}
  end

  defp ensure_session(nil, config, provider) do
    BeamAgent.start_session(
      provider: provider,
      provider_options: Config.provider_options(config),
      provider_profile: config["profile"],
      data_dir: config["data_dir"],
      context_window_tokens: config["context_window_tokens"],
      compaction_threshold_percent: config["compaction_threshold_percent"],
      workspace_root: config["workspace_root"],
      approval_policy: Config.approval_policy_atom(config["approval_policy"]),
      approval_handler: self()
    )
  end

  defp ensure_session(session_id, config, provider) do
    case BeamAgent.agent_pid(session_id) do
      {:ok, _pid} ->
        {:ok, session_id}

      {:error, :not_found} ->
        BeamAgent.resume_session(session_id,
          provider: provider,
          provider_options: Config.provider_options(config),
          provider_profile: config["profile"],
          data_dir: config["data_dir"],
          context_window_tokens: config["context_window_tokens"],
          compaction_threshold_percent: config["compaction_threshold_percent"],
          workspace_root: config["workspace_root"],
          approval_policy: Config.approval_policy_atom(config["approval_policy"]),
          approval_handler: self()
        )
    end
  end

  defp chat_loop(session_id, config) do
    case UI.prompt() do
      :eof ->
        0

      {:error, reason} ->
        error({:input_error, reason})

      input ->
        case String.trim(input) do
          "" ->
            chat_loop(session_id, config)

          "/exit" ->
            0

          "/quit" ->
            0

          "/help" ->
            UI.command_help()
            chat_loop(session_id, config)

          "/" ->
            UI.command_help()
            chat_loop(session_id, config)

          "/events" ->
            print_event_summary(session_id)
            chat_loop(session_id, config)

          "/status" ->
            print_status(session_id, config)
            chat_loop(session_id, config)

          "/auto" ->
            chat_loop(session_id, toggle_auto_mode(session_id, config))

          "/compact" ->
            compact_session_context(session_id)
            chat_loop(session_id, config)

          "/skills" ->
            print_session_skills(session_id)
            chat_loop(session_id, config)

          "/reload" ->
            reload_session_context(session_id)
            chat_loop(session_id, config)

          "/sessions" ->
            print_sessions(config)
            chat_loop(session_id, config)

          "/new" ->
            start_new_chat(config, session_id)

          "/clear" ->
            UI.clear()
            UI.session_header(config, session_id)
            chat_loop(session_id, config)

          "/model" ->
            print_status(session_id, config)
            chat_loop(session_id, config)

          "/" <> command ->
            UI.warning("Unknown command /#{command} · type /help")
            chat_loop(session_id, config)

          prompt ->
            _status = ask_and_print(session_id, prompt)
            chat_loop(session_id, config)
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

  defp start_new_chat(config, previous_session_id) do
    with {:ok, provider} <- Config.provider_atom(config["provider"]),
         {:ok, session_id} <- ensure_session(nil, config, provider) do
      _ = BeamAgent.stop_session(previous_session_id)
      UI.notice("Started a new session")
      UI.session_header(config, session_id)
      chat_loop(session_id, config)
    else
      {:error, reason} ->
        _ = error(reason)
        chat_loop(previous_session_id, config)
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

    Enum.each(Config.profiles(config), fn {name, profile} ->
      marker = if name == config["active_profile"], do: "*", else: "-"
      model = if profile["model"], do: "/#{profile["model"]}", else: ""
      output("profile:    #{marker} #{name}  #{profile["provider"]}#{model}")
    end)

    output("approval:   #{config["approval_policy"]}")
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
    beam agent #{@version}

    Start here:
      beam_agent                             open an interactive chat
      beam_agent run "your prompt"           run once and exit
      beam_agent resume SESSION              continue a saved session

    Setup and inspect:
      beam_agent init                        configure a provider
      beam_agent doctor                      check the active provider
      beam_agent provider list               list configured provider profiles
      beam_agent provider add NAME           add a provider profile
      beam_agent provider use NAME           change the active profile
      beam_agent sessions                    list durable sessions
      beam_agent providers                   list available providers
      beam_agent tools                       list model-callable tools
      beam_agent skills                      list project skills in this workspace
      beam_agent config show                 show active configuration
      beam_agent config path                 show configuration path

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
      --context-window TOKENS                estimated model context capacity
      --compact-at PERCENT                   automatic compaction threshold
      --no-tui                               use the line-oriented interactive UI

    Running `beam_agent init` opens a guided setup. For automated setup, add
    --non-interactive and provide provider/model flags explicitly.
    """)
  end

  defp init_help do
    output("""
    Configure beam agent

      beam_agent init [options]

      --provider NAME        demo, echo, ollama, openai, anthropic, xai, or grok
      --profile NAME         name for the initial provider profile
      --model MODEL          required for real LLM providers
      --base-url URL         provider endpoint or compatible proxy
      --api-key-env NAME     environment variable containing the credential
      --approval POLICY      ask, deny, or auto-approve risky tools
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

      beam_agent provider list
      beam_agent provider add NAME [options]
      beam_agent provider use NAME

      --provider ADAPTER     ollama, openai, anthropic, xai, grok, demo, or echo
      --model MODEL          required for real LLM providers
      --base-url URL         provider endpoint or compatible proxy
      --api-key-env NAME     environment variable containing the credential
      --activate             make the new profile active
      --non-interactive      validate supplied/default values without prompts
      --force                replace a profile with the same name

    Secrets are never written to the config; only environment-variable names are stored.
    Use `--profile NAME` on run or doctor to select a profile without changing the active one.
    """)
  end

  defp run_help do
    output("""
    Chat with beam agent

      beam_agent run [options] [prompt]

    Omit the prompt for interactive chat. Supplying one runs a single turn and
    exits. Provider, model, endpoint, limits, and session storage can be
    overridden with the common options shown by `beam_agent help`. Interactive
    chat opens the full-screen TUI on a capable terminal; use `--no-tui` for the
    line-oriented fallback.
    """)
  end

  defp resume_help do
    output("""
    Resume a durable session

      beam_agent resume SESSION [prompt]

    Use `beam_agent sessions` to find session IDs. Omit the prompt to continue
    interactively.
    """)
  end

  defp usage_error(message) do
    IO.puts(:stderr, "error: #{message}\nRun `beam_agent help` for usage.")
    2
  end

  defp error({:not_initialized, path}) do
    IO.puts(
      :stderr,
      "error: BeamAgent is not configured. Run `beam_agent init --config #{path}`."
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
      "error: provider profile #{inspect(name)} was not found; run `beam_agent provider list`"
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
