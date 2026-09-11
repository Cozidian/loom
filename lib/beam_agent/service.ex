defmodule BeamAgent.Service do
  @moduledoc "Long-lived local owner. Desk is a restartable child; clients never own its sessions."
  use GenServer
  alias BeamAgent.Service.Storage

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def status, do: GenServer.call(__MODULE__, :status)
  def launch(session \\ nil), do: GenServer.call(__MODULE__, {:launch, session}, 10_000)

  def remember(id, config) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:remember, id, config}),
      else: :ok
  end

  def init(opts) do
    Process.flag(:trap_exit, true)
    token = random()
    config = Keyword.fetch!(opts, :config)
    config_path = Keyword.fetch!(opts, :config_path)

    with :ok <- Storage.prepare(),
         {:ok, server} <-
           BeamAgent.ControlPlane.HTTPServer.start_link(
             port: Storage.port(),
             token: token,
             catalog: [config: config, config_path: config_path, service: true]
           ),
         {:ok, url} <- BeamAgent.ControlPlane.HTTPServer.url(server) do
      saved =
        case Storage.read("sessions.json") do
          {:ok, sessions} when is_map(sessions) -> sessions
          _ -> %{}
        end

      record = %{
        "http_port" => URI.parse(url).port,
        "token" => token,
        "instance" => random(),
        "config_path" => Path.expand(config_path),
        "owner_pid" => System.pid()
      }

      :ok = Storage.write("runtime.json", record)
      if Keyword.get(opts, :desk, true), do: send(self(), :start_desk)
      send(self(), :recover)

      {:ok,
       %{
         server: server,
         record: record,
         config: config,
         config_path: config_path,
         port: nil,
         desk_port: nil,
         pending: %{},
         sessions: saved,
         recovery: %{},
         recovery_task: nil
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  def format_status(status) do
    Map.update(status, :state, %{}, fn state ->
      Map.take(state, [:desk_port, :recovery])
    end)
  end

  def handle_call(:status, _, state) do
    {:reply,
     {:ok,
      Map.merge(Map.drop(state.record, ["token"]), %{
        "desk_port" => state.desk_port,
        "sessions" => map_size(state.sessions),
        "recovery" => state.recovery
      })}, state}
  end

  def handle_call({:launch, session}, from, state) do
    cond do
      is_nil(state.desk_port) ->
        {:reply, {:error, :desk_starting}, state}

      session != nil and not BeamAgent.LocalDiscovery.valid_id?(session) ->
        {:reply, {:error, :invalid_session_id}, state}

      map_size(state.pending) >= 16 ->
        {:reply, {:error, :too_many_launches}, state}

      true ->
        id = random()
        ticket = random()
        Port.command(state.port, JSON.encode!(%{request_id: id, launch_ticket: ticket}) <> "\n")
        Process.send_after(self(), {:launch_timeout, id}, 5_000)
        suffix = if session, do: "/sessions/" <> session, else: "/"
        url = "http://localhost:#{state.desk_port}#{suffix}#launch=#{ticket}"
        {:noreply, %{state | pending: Map.put(state.pending, id, {from, url})}}
    end
  end

  def handle_call({:remember, id, config}, _, state) do
    metadata = Map.take(config, ["workspace_root", "data_dir", "profile"])
    sessions = Map.put(state.sessions, id, metadata)

    case Storage.write("sessions.json", sessions) do
      :ok -> {:reply, :ok, %{state | sessions: sessions}}
      error -> {:reply, error, state}
    end
  end

  def handle_info(:start_desk, %{port: nil} = state) do
    directory = BeamAgent.CLI.Desk.directory()
    mix = System.find_executable("mix")

    if directory && mix do
      port =
        Port.open({:spawn_executable, String.to_charlist(mix)}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:line, 4096},
          {:args, [~c"run", ~c"--no-start", ~c"scripts/managed.exs"]},
          {:cd, String.to_charlist(directory)},
          {:env,
           [
             {~c"BEAM_AGENT_RUNTIME_URL",
              String.to_charlist("http://127.0.0.1:#{state.record["http_port"]}")},
             {~c"BEAM_AGENT_RUNTIME_TOKEN", String.to_charlist(state.record["token"])},
             {~c"BEAM_AGENT_DESK_LAUNCH_TICKET", false},
             {~c"PORT", ~c"0"},
             {~c"MIX_ENV", ~c"dev"}
           ]}
        ])

      {:noreply, %{state | port: port}}
    else
      {:stop, :desk_not_built, state}
    end
  end

  def handle_info({port, {:data, {:eol, "BEAM_DESK_READY " <> number}}}, %{port: port} = state) do
    {number, ""} = Integer.parse(String.trim(number))
    IO.puts("Loom Desk ready on localhost:#{number}. Open it with loom desk.")
    {:noreply, %{state | desk_port: number}}
  end

  def handle_info({port, {:data, {:eol, "LOOM_TICKET_READY " <> id}}}, %{port: port} = state) do
    {item, pending} = Map.pop(state.pending, String.trim(id))

    if item do
      {from, url} = item
      GenServer.reply(from, {:ok, %{"url" => url}})
    end

    {:noreply, %{state | pending: pending}}
  end

  def handle_info({:launch_timeout, id}, state) do
    {item, pending} = Map.pop(state.pending, id)
    if item, do: GenServer.reply(elem(item, 0), {:error, :desk_unresponsive})
    {:noreply, %{state | pending: pending}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    IO.puts(
      "Loom Desk exited (#{status}); restarting the web client, keeping agent work running."
    )

    for {_, {from, _}} <- state.pending, do: GenServer.reply(from, {:error, :desk_restarting})
    Process.send_after(self(), :start_desk, 2_000)
    {:noreply, %{state | port: nil, desk_port: nil, pending: %{}}}
  end

  def handle_info(:recover, state) do
    task =
      Task.Supervisor.async_nolink(BeamAgent.LocalStartupTasks, fn ->
        Map.new(state.sessions, fn {id, saved} ->
          result = BeamAgent.CLI.restore_local_session(id, saved, state.config_path)

          {id,
           if(result == :ok, do: "restored_idle", else: "unavailable_check_workspace_or_profile")}
        end)
      end)

    {:noreply, %{state | recovery_task: task.ref}}
  end

  def handle_info({ref, recovery}, %{recovery_task: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | recovery: recovery, recovery_task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{recovery_task: ref} = state),
    do: {:noreply, %{state | recovery: %{"error" => "recovery_interrupted"}, recovery_task: nil}}

  def handle_info({:EXIT, server, reason}, %{server: server} = state), do: {:stop, reason, state}

  # Child logs may include provider/transport detail. Do not forward credentials or launch tickets.
  def handle_info(_, state), do: {:noreply, state}

  def terminate(_, state) do
    if state.port && Port.info(state.port), do: Port.close(state.port)
    if Process.alive?(state.server), do: GenServer.stop(state.server)
    for {id, _} <- state.sessions, do: BeamAgent.stop_session(id)

    instance = state.record["instance"]

    case Storage.read("runtime.json") do
      {:ok, %{"instance" => ^instance}} ->
        File.rm(Storage.path("runtime.json"))

      _ ->
        :ok
    end
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
