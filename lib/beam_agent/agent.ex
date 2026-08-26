defmodule BeamAgent.Agent do
  @moduledoc "A mailbox-owning agent process whose model-visible state lives in its event log."
  use GenServer

  alias BeamAgent.{CapabilityCatalog, Names}
  alias BeamAgent.Session.{Context, EventLog}

  def start_link(opts) do
    id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:agent, id))
  end

  def ask(session_id, prompt, timeout \\ 30_000) do
    with {:ok, pid} <- Names.pid(:agent, session_id) do
      GenServer.call(pid, {:ask, prompt}, timeout)
    end
  end

  def status(session_id) do
    with {:ok, pid} <- Names.pid(:agent, session_id) do
      GenServer.call(pid, :status)
    end
  end

  def cancel(session_id) do
    with {:ok, pid} <- Names.pid(:agent, session_id) do
      GenServer.call(pid, :cancel)
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    session_id = Keyword.fetch!(opts, :session_id)
    provider = Keyword.get(opts, :provider, Application.fetch_env!(:beam_agent, :provider))
    strategy = Keyword.get(opts, :strategy, Application.fetch_env!(:beam_agent, :strategy))
    data_dir = Keyword.get(opts, :data_dir, Application.fetch_env!(:beam_agent, :data_dir))
    max_steps = Keyword.get(opts, :max_steps, Application.fetch_env!(:beam_agent, :max_steps))

    with {:ok, provider_module} <- CapabilityCatalog.provider(provider),
         :ok <- validate_strategy(strategy),
         {:ok, _project_context} <- Context.snapshot(session_id) do
      {:ok, existing} = EventLog.events(session_id)

      state = %{
        session_id: session_id,
        parent_session_id: Keyword.get(opts, :parent_session_id),
        provider: provider,
        provider_module: provider_module,
        provider_options: Keyword.get(opts, :provider_options, []),
        strategy: strategy,
        data_dir: data_dir,
        workspace_root: Keyword.fetch!(opts, :workspace_root),
        approval_policy: Keyword.get(opts, :approval_policy, :ask),
        approval_handler: Keyword.get(opts, :approval_handler),
        max_steps: max_steps,
        status: :idle,
        current_turn: nil
      }

      {:ok, _} =
        EventLog.append(session_id, :agent_started, %{
          "pid" => inspect(self()),
          "recovered" => Enum.any?(existing, &(&1["type"] == "agent_started"))
        })

      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:ask, prompt}, from, %{current_turn: nil} = state)
      when is_binary(prompt) and prompt != "" do
    {:ok, supervisor} = Names.pid(:resource_supervisor, state.session_id)
    agent = self()
    turn_ref = make_ref()

    task = fn ->
      # The session resource supervisor owns the worker, while this extra link
      # ensures an in-flight turn cannot outlive the agent that accepted it.
      Process.link(agent)
      result = state.strategy.run(state, prompt)
      send(agent, {:turn_result, turn_ref, self(), result})
    end

    case DynamicSupervisor.start_child(supervisor, {Task, task}) do
      {:ok, task_pid} ->
        monitor = Process.monitor(task_pid)

        current = %{
          pid: task_pid,
          monitor: monitor,
          ref: turn_ref,
          from: from,
          cancel_requested: false
        }

        {:noreply, %{state | status: :running, current_turn: current}}

      {:error, reason} ->
        {:reply, {:error, {:turn_start_failed, reason}}, state}
    end
  end

  def handle_call({:ask, _prompt}, _from, %{current_turn: current} = state)
      when not is_nil(current),
      do: {:reply, {:error, :agent_busy}, state}

  def handle_call({:ask, _prompt}, _from, state), do: {:reply, {:error, :empty_prompt}, state}
  def handle_call(:status, _from, state), do: {:reply, {:ok, state.status}, state}

  def handle_call(:cancel, _from, %{current_turn: nil} = state),
    do: {:reply, {:error, :not_running}, state}

  def handle_call(:cancel, _from, state) do
    Process.exit(state.current_turn.pid, :shutdown)
    current = %{state.current_turn | cancel_requested: true}
    {:reply, :ok, %{state | status: :cancelling, current_turn: current}}
  end

  @impl true
  def handle_info(
        {:turn_result, ref, pid, result},
        %{current_turn: %{ref: ref, pid: pid} = current} = state
      ) do
    Process.demonitor(current.monitor, [:flush])
    GenServer.reply(current.from, result)
    {:noreply, %{state | status: :idle, current_turn: nil}}
  end

  def handle_info({:EXIT, pid, reason}, %{current_turn: %{pid: pid} = current} = state) do
    Process.demonitor(current.monitor, [:flush])

    result =
      if current.cancel_requested do
        _ =
          EventLog.append(state.session_id, :turn_cancelled, %{
            "reason" => inspect(reason)
          })

        {:error, :cancelled}
      else
        _ =
          EventLog.append(state.session_id, :turn_worker_failed, %{
            "reason" => inspect(reason)
          })

        {:error, {:turn_process_exit, reason}}
      end

    GenServer.reply(current.from, result)
    {:noreply, %{state | status: :idle, current_turn: nil}}
  end

  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:turn_result, _ref, _pid, _result}, state), do: {:noreply, state}

  defp validate_strategy(strategy) do
    case Code.ensure_loaded(strategy) do
      {:module, ^strategy} ->
        if function_exported?(strategy, :run, 2),
          do: :ok,
          else: {:error, {:invalid_strategy, strategy}}

      {:error, _reason} ->
        {:error, {:invalid_strategy, strategy}}
    end
  end
end
