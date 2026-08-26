defmodule BeamAgent.CLI do
  @moduledoc "Command-line entry point for configuring and running BeamAgent."

  alias BeamAgent.CLI.Config

  @version Mix.Project.config()[:version]
  @run_switches [
    provider: :string,
    data_dir: :string,
    max_steps: :integer,
    timeout: :integer,
    session: :string,
    model: :string,
    base_url: :string,
    api_key_env: :string
  ]

  def main(args) do
    status = run(args)
    if status != 0, do: System.halt(status)
  end

  def run(args) do
    {config_path, args} = extract_config_path(args)

    case args do
      [] ->
        run_command(config_path, [])

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

      ["tools" | rest] ->
        tools_command(rest)

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

      [unknown | _rest] ->
        usage_error("unknown command #{inspect(unknown)}")
    end
  end

  defp init_command(config_path, args) do
    switches = [
      provider: :string,
      data_dir: :string,
      max_steps: :integer,
      timeout: :integer,
      model: :string,
      base_url: :string,
      api_key_env: :string,
      force: :boolean,
      non_interactive: :boolean
    ]

    with {:ok, opts, []} <- parse(args, switches),
         :ok <- ensure_replacement_allowed(config_path, opts[:force]),
         {:ok, config} <- build_config(opts),
         {:ok, ^config_path} <- Config.write(config, config_path) do
      output("Configuration written to #{config_path}")
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
        maybe_prompt(
          interactive,
          "Provider (#{Enum.join(Config.supported_providers(), "/")})",
          defaults["provider"]
        )

    with {:ok, provider_config} <- BeamAgent.Providers.fetch(provider) do
      build_provider_config(opts, defaults, provider, provider_config, interactive)
    end
  end

  defp build_provider_config(opts, defaults, provider, provider_config, interactive) do
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

    data_dir =
      opts[:data_dir] || maybe_prompt(interactive, "Session data directory", defaults["data_dir"])

    max_steps =
      opts[:max_steps] ||
        maybe_prompt(
          interactive,
          "Maximum tool-loop steps",
          Integer.to_string(defaults["max_steps"])
        )

    timeout =
      opts[:timeout] ||
        maybe_prompt(
          interactive,
          "Turn timeout in milliseconds",
          Integer.to_string(defaults["timeout_ms"])
        )

    config = %{
      "version" => defaults["version"],
      "provider" => provider,
      "model" => model,
      "base_url" => base_url,
      "api_key_env" => api_key_env,
      "data_dir" => Path.expand(data_dir),
      "max_steps" => parse_integer(max_steps),
      "timeout_ms" => parse_integer(timeout)
    }

    case Config.validate(config) do
      :ok -> {:ok, config}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_command(config_path, args, require_existing? \\ false) do
    with {:ok, opts, prompt_parts} <- parse(args, @run_switches),
         {:ok, config} <- Config.load(config_path),
         config <- Config.merge_overrides(config, opts),
         :ok <- Config.validate(config),
         :ok <- require_existing_session(opts[:session], config, require_existing?),
         {:ok, provider} <- Config.provider_atom(config["provider"]),
         :ok <- ensure_application_started(),
         {:ok, session_id} <- ensure_session(opts[:session], config, provider) do
      prompt = Enum.join(prompt_parts, " ")
      output("Session #{session_id} (provider: #{config["provider"]})")

      if prompt == "" do
        output("Interactive mode. Type /help for commands or /exit to quit.")
        chat_loop(session_id, config)
      else
        ask_and_print(session_id, prompt, config["timeout_ms"])
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
      data_dir: config["data_dir"],
      max_steps: config["max_steps"]
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
          data_dir: config["data_dir"],
          max_steps: config["max_steps"]
        )
    end
  end

  defp chat_loop(session_id, config) do
    case IO.gets("you> ") do
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
            output("/events  show event count and log path")
            output("/exit    stop this CLI session")
            chat_loop(session_id, config)

          "/events" ->
            print_event_summary(session_id)
            chat_loop(session_id, config)

          prompt ->
            _status = ask_and_print(session_id, prompt, config["timeout_ms"])
            chat_loop(session_id, config)
        end
    end
  end

  defp ask_and_print(session_id, prompt, timeout) do
    case BeamAgent.ask(session_id, prompt, timeout + 2_000) do
      {:ok, answer} ->
        output("agent> #{answer}")
        0

      {:error, reason} ->
        error(reason)
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

  defp doctor_command(config_path, args) do
    with {:ok, _opts, []} <- parse(args, []),
         {:ok, config} <- Config.load(config_path),
         :ok <- ensure_application_started(),
         {:ok, provider} <- Config.provider_atom(config["provider"]),
         {:ok, module} <- BeamAgent.CapabilityCatalog.provider(provider),
         {:ok, detail} <- provider_healthcheck(module, Config.provider_options(config)),
         :ok <- File.mkdir_p(config["data_dir"]) do
      output("ok  config    #{config_path}")
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

  defp sessions_command(config_path, args) do
    with {:ok, _opts, []} <- parse(args, []),
         {:ok, config} <- Config.load(config_path),
         {:ok, entries} <- File.ls(config["data_dir"]) do
      sessions =
        entries
        |> Enum.filter(&File.regular?(Path.join([config["data_dir"], &1, "events.jsonl"])))
        |> Enum.sort()

      if sessions == [], do: output("No sessions."), else: Enum.each(sessions, &output/1)
      0
    else
      {:error, :enoent} ->
        output("No sessions.")

      {:ok, _opts, positional} ->
        usage_error("unexpected arguments: #{Enum.join(positional, " ")}")

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
    output("provider:   #{config["provider"]}")
    if config["model"], do: output("model:      #{config["model"]}")
    if config["base_url"], do: output("base_url:   #{config["base_url"]}")
    if config["api_key_env"], do: output("api_key:    environment #{config["api_key_env"]}")
    output("data_dir:   #{config["data_dir"]}")
    output("max_steps:  #{config["max_steps"]}")
    output("timeout_ms: #{config["timeout_ms"]}")
  end

  defp ensure_replacement_allowed(config_path, force?) do
    if File.exists?(config_path) and force? != true,
      do: {:error, {:config_exists, config_path}},
      else: :ok
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
    BeamAgent #{@version}

    Usage:
      beam_agent init [options]              create first-run configuration
      beam_agent run [options] [prompt]      start a session or interactive chat
      beam_agent resume SESSION [prompt]     resume a durable session
      beam_agent sessions                    list durable sessions
      beam_agent doctor                      validate configuration and runtime
      beam_agent providers                   list configured provider modules
      beam_agent tools                       list model-callable tools
      beam_agent config show                 show active configuration
      beam_agent config path                 show configuration path

    Global:
      --config PATH                          use a specific configuration file

    Init options:
      --provider demo|echo|ollama|openai|anthropic|xai
      --model MODEL
      --base-url URL
      --api-key-env VARIABLE
      --data-dir PATH
      --max-steps N
      --timeout MILLISECONDS
      --non-interactive
      --force

    Run options:
      --session ID
      --provider demo|echo|ollama|openai|anthropic|xai  (`grok` aliases `xai`)
      --model MODEL
      --base-url URL
      --api-key-env VARIABLE
      --data-dir PATH
      --max-steps N
      --timeout MILLISECONDS
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

  defp error(reason) do
    IO.puts(:stderr, "error: #{inspect(reason)}")
    1
  end

  defp output(message) do
    IO.puts(message)
    0
  end
end
