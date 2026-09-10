defmodule BeamAgent.CLI.Desk do
  @moduledoc "One foreground owner for a real runtime API and its separate Phoenix client."
  @checkout Path.expand("../../..", __DIR__)

  def directory do
    sibling =
      try do
        :escript.script_name() |> List.to_string() |> Path.expand() |> Path.dirname()
      rescue
        _ -> @checkout
      end

    [Path.join(sibling, "cmd/beam_agent_web")]
    |> Enum.find(&File.regular?(Path.join(&1, "mix.exs")))
  end

  def run(session, opts) do
    with dir when is_binary(dir) <- directory(),
         mix when is_binary(mix) <- System.find_executable("mix"),
         true <- File.dir?(Path.join(dir, "deps/phoenix")) do
      launch(session, opts, dir, mix)
    else
      false ->
        {:error, "Desk needs its one-time build: mix beam_agent.build --frontend web"}

      nil ->
        {:error,
         "Desk source and Elixir/Mix are required beside this CLI. Run from the harness checkout."}
    end
  end

  defp launch(session, opts, dir, mix) do
    token = random_token()
    ticket = random_token()

    server_opts =
      if opts[:catalog_config],
        do: [
          token: token,
          catalog: [config: opts[:catalog_config], config_path: opts[:config_path]]
        ],
        else: [session_id: session, token: token, conversation: true]

    with {:ok, server} <- BeamAgent.ControlPlane.HTTPServer.start_link(server_opts) do
      try do
        {:ok, runtime_url} = BeamAgent.ControlPlane.HTTPServer.url(server)
        runtime_url = "http://127.0.0.1:#{URI.parse(runtime_url).port}"

        env = [
          {~c"BEAM_AGENT_RUNTIME_URL", String.to_charlist(runtime_url)},
          {~c"BEAM_AGENT_RUNTIME_TOKEN", String.to_charlist(token)},
          {~c"BEAM_AGENT_DESK_LAUNCH_TICKET", String.to_charlist(ticket)},
          {~c"PORT", String.to_charlist(Integer.to_string(opts[:port] || 0))},
          {~c"MIX_ENV", ~c"dev"}
        ]

        port =
          Port.open({:spawn_executable, String.to_charlist(mix)}, [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            {:line, 4_096},
            {:args, [~c"run", ~c"--no-start", ~c"scripts/managed.exs"]},
            {:cd, String.to_charlist(dir)},
            {:env, env}
          ])

        try do
          IO.puts("Starting Desk · local session control center…")
          await_ready(port, ticket, opts, System.monotonic_time(:millisecond) + 120_000)
        after
          close(port)
        end
      after
        if Process.alive?(server), do: GenServer.stop(server)
      end
    end
  end

  defp await_ready(port, ticket, opts, deadline) do
    receive do
      {^port, {:data, {:eol, "BEAM_DESK_READY " <> number}}} ->
        case Integer.parse(String.trim(number)) do
          {port_number, ""} when port_number in 1..65535 ->
            path = if opts[:initial_session], do: "/sessions/#{opts[:initial_session]}", else: "/"
            url = "http://localhost:#{port_number}#{path}#launch=#{ticket}"

            IO.puts(
              "Desk is ready: #{url}\nLaunch link expires in 90 seconds and works once.\nKeep this terminal open; Ctrl+C stops this runtime and Desk. Session history is retained."
            )

            if opts[:open] != false, do: open_browser(url)

            case opts[:on_ready] do
              callback when is_function(callback, 0) -> wait_shared(port, Task.async(callback))
              _ -> wait(port)
            end

          _ ->
            {:error, :invalid_desk_ready_message}
        end

      {^port, {:data, {_kind, line}}} ->
        IO.puts(line)
        await_ready(port, ticket, opts, deadline)

      {^port, {:exit_status, status}} ->
        {:error, {:desk_start_failed, status}}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> {:error, :desk_start_timeout}
    end
  end

  defp wait(port) do
    receive do
      :shutdown ->
        :ok

      {^port, {:data, {_kind, line}}} ->
        IO.puts(line)
        wait(port)

      {^port, {:exit_status, status}} ->
        {:error, {:desk_stopped, status}}
    end
  end

  defp wait_shared(port, task) do
    receive do
      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ref, :process, _, reason} when ref == task.ref ->
        {:error, {:shared_tui_stopped, reason}}

      {^port, {:data, _line}} ->
        # Drain Phoenix logs without writing over the terminal UI or growing
        # an unbounded mailbox while the shared session is open.
        wait_shared(port, task)

      {^port, {:exit_status, status}} ->
        send(task.pid, {:desk_disconnected, status})
        wait_shared(nil, task)
    end
  end

  defp close(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp open_browser(url) do
    command = if :os.type() == {:unix, :darwin}, do: "open", else: "xdg-open"

    if executable = System.find_executable(command),
      do: System.cmd(executable, [url], stderr_to_stdout: true)

    :ok
  end

  defp random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
