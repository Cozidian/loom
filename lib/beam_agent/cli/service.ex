defmodule BeamAgent.CLI.Service do
  @moduledoc "Loom's local service and short-lived clients. Login installation is explicit."
  alias BeamAgent.CLI.{Config, TUI}
  alias BeamAgent.Service.Storage

  def run(args, config_path) do
    result =
      case args do
        ["run"] ->
          foreground(config_path)

        ["start"] ->
          start(config_path)

        ["install"] ->
          install(config_path)

        ["stop"] ->
          stop()

        ["uninstall"] ->
          uninstall()

        ["status"] ->
          case Storage.lookup() do
            {:ok, record} ->
              IO.puts(
                "Loom service running · PID #{record["owner_pid"]} · #{record["sessions"]} owned sessions\nConfig: #{record["config_path"]}\nDesk: #{if record["desk_port"], do: "ready", else: "starting"}\nRecovery: #{JSON.encode!(record["recovery"])}"
              )

              :ok

            _ ->
              IO.puts("Loom service is stopped or unavailable.")
              :ok
          end

        ["logs"] ->
          case File.read(Storage.path("service.log")) do
            {:ok, text} ->
              IO.puts(String.slice(text, -20_000, 20_000))
              :ok

            _ ->
              IO.puts("No service log yet.")
              :ok
          end

        args when args in [[], ["--help"], ["-h"]] ->
          help()
          :ok

        _ ->
          {:error, :unknown_service_action}
      end

    finish(result)
  end

  def desk(args, config_path) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          open: :boolean,
          session: :string,
          workspace: :string,
          tui: :boolean,
          frontend: :string
        ]
      )

    result =
      with true <- rest == [] and invalid == [] and opts[:frontend] in [nil, "rust"],
           true <- opts[:tui] != true or TUI.available?(true, opts[:frontend]),
           :ok <- ensure(config_path),
           {:ok, record} <- Storage.lookup(),
           {:ok, id} <- initial_session(record, opts),
           {:ok, %{"url" => url}} <- await_launch(record, id) do
        if opts[:open] != false, do: open_browser(url), else: IO.puts(url)
        IO.puts("Loom Desk connected. You can close this terminal; work stays in the service.")

        if opts[:tui] do
          with {:ok, session} <- BeamAgent.LocalDiscovery.lookup(id),
               do: TUI.attach(session, opts[:frontend])
        else
          :ok
        end
      else
        false ->
          {:error,
           "Use loom desk [--no-open] [--session ID] [--workspace PATH] [--tui]. Legacy flags: loom desk --foreground."}

        error ->
          error
      end

    finish(result)
  end

  def tui(args, config_path) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [workspace: :string, session: :string, frontend: :string])

    result =
      with true <- rest == [] and invalid == [] and opts[:frontend] in [nil, "rust"],
           true <- TUI.available?(true, opts[:frontend]),
           :ok <- ensure(config_path),
           {:ok, record} <- Storage.lookup(),
           {:ok, id} <- workspace_session(record, opts),
           {:ok, session} <- BeamAgent.LocalDiscovery.lookup(id),
           do: TUI.attach(session, opts[:frontend]),
           else: (error -> error)

    finish(result)
  end

  def ensure(config_path) do
    case Storage.lookup() do
      {:ok, record} ->
        if record["config_path"] == Path.expand(config_path),
          do: :ok,
          else:
            {:error,
             "Loom is running with another config. Use that config or explicitly stop the service first."}

      _ ->
        start(config_path)
    end
  end

  def foreground(config_path) do
    with {:error, :service_unavailable} <- Storage.lookup(),
         {:ok, stored} <- Config.load(config_path),
         {:ok, config} <- Config.runtime(stored),
         config =
           Map.merge(config, %{
             "workspace_root" => File.cwd!(),
             "model_endpoints" => Config.model_endpoints(stored, config)
           }),
         {:ok, _} <- Application.ensure_all_started(:beam_agent),
         {:ok, service} <- BeamAgent.Service.start_link(config: config, config_path: config_path) do
      ref = Process.monitor(service)
      IO.puts("Loom service running. No work is replayed automatically. Clients may come and go.")

      receive do
        {:DOWN, ^ref, :process, _, reason} ->
          {:error, {:service_stopped, reason}}

        :shutdown ->
          GenServer.stop(service)
          :ok
      end
    else
      {:ok, _} -> {:error, :service_already_running}
      error -> error
    end
  end

  def start(config_path) do
    case Storage.lookup() do
      {:ok, _} ->
        ensure(config_path)

      _ ->
        with :ok <- macos(),
             {:ok, _} <- Config.load(config_path),
             :ok <- Storage.prepare(),
             :ok <- write_plist(Storage.path("launch.plist"), config_path),
             :ok <- bootstrap(Storage.path("launch.plist")),
             :ok <- await_service(config_path, 120) do
          IO.puts("Loom service ready. Start at login with: loom service install")
          :ok
        end
    end
  end

  def install(config_path) do
    with :ok <- macos(),
         {:ok, _} <- Config.load(config_path),
         :ok <- compatible_config(config_path),
         :ok <- Storage.prepare(),
         :ok <- File.mkdir_p(Path.dirname(login_path())),
         :ok <- write_plist(login_path(), config_path),
         do: start(config_path)
  end

  defp compatible_config(config_path) do
    case Storage.lookup() do
      {:ok, record} ->
        if record["config_path"] == Path.expand(config_path),
          do: :ok,
          else: {:error, :service_config_conflict}

      _ ->
        :ok
    end
  end

  def stop do
    with :ok <- macos() do
      case System.cmd("launchctl", ["bootout", target()], stderr_to_stdout: true) do
        {_, 0} ->
          IO.puts(
            "Loom service stopped. Active work is interrupted; session history is retained."
          )

          :ok

        _ ->
          case Storage.lookup() do
            {:ok, _} -> {:error, "Service was started in foreground; stop its owning terminal."}
            _ -> :ok
          end
      end
    end
  end

  def uninstall do
    with :ok <- stop() do
      File.rm(Storage.path("launch.plist"))

      case File.rm(login_path()) do
        :ok ->
          IO.puts(
            "Removed Loom's login registration. Configuration, logs and sessions are retained."
          )

          :ok

        {:error, :enoent} ->
          :ok

        error ->
          error
      end
    end
  end

  def plist(config_path, executable) do
    values = [executable, "--config", Path.expand(config_path), "service", "run"]

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>Label</key><string>#{xml(label())}</string>
    <key>ProgramArguments</key><array>#{Enum.map_join(values, &"<string>#{xml(&1)}</string>")}</array>
    <key>WorkingDirectory</key><string>#{xml(Path.dirname(executable))}</string>
    <key>EnvironmentVariables</key><dict><key>PATH</key><string>#{xml(System.get_env("PATH") || "/usr/bin:/bin")}</string>
    <key>LOOM_SERVICE_DIR</key><string>#{xml(Storage.directory())}</string>
    <key>LOOM_DISCOVERY_DIR</key><string>#{xml(BeamAgent.LocalDiscovery.directory())}</string></dict>
    <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>#{xml(Storage.path("service.log"))}</string>
    <key>StandardErrorPath</key><string>#{xml(Storage.path("service.log"))}</string>
    </dict></plist>
    """
  end

  defp write_plist(path, config_path) do
    executable = :escript.script_name() |> List.to_string() |> Path.expand()

    with true <- File.regular?(executable),
         {:error, :enoent} <- File.lstat(path) do
      with :ok <- File.write(path, plist(config_path, executable), [:exclusive]),
           do: File.chmod(path, 0o600)
    else
      {:ok, %{type: :regular}} ->
        # Never silently replace another job or change a live service's configuration.
        if File.read!(path) == plist(config_path, executable),
          do: :ok,
          else:
            {:error,
             "Service registration differs. Stop/uninstall it before changing the executable or config."}

      _ ->
        {:error, :unsafe_service_registration}
    end
  end

  defp bootstrap(path) do
    case System.cmd("launchctl", ["bootstrap", domain(), path], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        case System.cmd("launchctl", ["print", target()], stderr_to_stdout: true) do
          {_, 0} -> :ok
          _ -> {:error, :launch_agent_start_failed}
        end
    end
  end

  defp await_service(_, 0), do: {:error, "Service did not become ready. Run loom service logs."}

  defp await_service(config, n) do
    case Storage.lookup() do
      {:ok, _} ->
        ensure(config)

      _ ->
        Process.sleep(250)
        await_service(config, n - 1)
    end
  end

  defp await_launch(record, id, n \\ 120)
  defp await_launch(_, _, 0), do: {:error, "Desk did not become ready. Run loom service logs."}

  defp await_launch(record, id, n) do
    case Storage.request(record, :post, "/api/v1/service/launch", %{session_id: id}) do
      {:error, "desk_starting"} ->
        Process.sleep(250)
        await_launch(record, id, n - 1)

      result ->
        result
    end
  end

  defp initial_session(record, opts) do
    if opts[:tui] || opts[:workspace],
      do: workspace_session(record, opts),
      else: {:ok, opts[:session]}
  end

  defp workspace_session(record, opts) do
    if opts[:session] do
      with {:ok, _} <- BeamAgent.LocalDiscovery.lookup(opts[:session]), do: {:ok, opts[:session]}
    else
      with {:ok, root} <- BeamAgent.Workspace.canonical_root(opts[:workspace] || File.cwd!()),
           {:ok, %{"sessions" => sessions}} <- Storage.request(record, :get, "/api/v1/sessions") do
        case sessions
             |> Enum.filter(&(&1["workspace"] == root))
             |> Enum.sort_by(& &1["started_at"], :desc) do
          [session | _] -> {:ok, session["session_id"]}
          [] -> create_session(record, root)
        end
      end
    end
  end

  defp create_session(record, root) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    with {:ok, _} <-
           Storage.request(record, :post, "/api/v1/sessions", %{workspace: root, request_id: id}),
         do: await_session(record, id, 120)
  end

  defp await_session(_, _, 0),
    do: {:error, "Session is still starting. Check Loom Desk; do not repeat creation."}

  defp await_session(record, id, n) do
    case Storage.request(record, :get, "/api/v1/session-starts/" <> id) do
      {:ok, %{"status" => "ready", "session_id" => session}} ->
        {:ok, session}

      {:ok, %{"status" => "starting"}} ->
        Process.sleep(250)
        await_session(record, id, n - 1)

      other ->
        {:error, {:session_start_failed, other}}
    end
  end

  defp open_browser(url) do
    executable = if :os.type() == {:unix, :darwin}, do: "open", else: "xdg-open"

    case System.cmd(executable, [url], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> IO.puts("Open this one-time link within 90 seconds:\n#{url}")
    end
  end

  defp macos,
    do:
      if(:os.type() == {:unix, :darwin},
        do: :ok,
        else:
          {:error,
           "Automatic service management currently supports macOS. Use loom service run in a dedicated process."}
      )

  defp label,
    do:
      "dev.loom.harness." <>
        (Storage.directory()
         |> then(&:crypto.hash(:sha256, &1))
         |> Base.encode16(case: :lower)
         |> String.slice(0, 12))

  defp domain, do: "gui/" <> (System.cmd("id", ["-u"]) |> elem(0) |> String.trim())
  defp target, do: domain() <> "/" <> label()
  defp login_path, do: Path.join(System.user_home!(), "Library/LaunchAgents/#{label()}.plist")

  defp xml(text),
    do:
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> String.replace("\"", "&quot;")

  defp finish(:ok), do: 0

  defp finish(error),
    do:
      (
        IO.puts(:stderr, "Loom: #{inspect(error)}")
        1
      )

  defp help,
    do:
      IO.puts(
        "loom service start|stop|status|logs|install|uninstall|run\nStart runs independently of terminals. Install opts into starting at login.\nStop interrupts active work but retains history. Uninstall removes only login registration.\nBrowser login expired? Run loom desk again. No backend restart needed."
      )
end
