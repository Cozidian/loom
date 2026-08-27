defmodule BeamAgent.Agent do
  @moduledoc "A mailbox-owning agent process whose model-visible state lives in its event log."
  use GenServer

  alias BeamAgent.{CapabilityCatalog, Names, RuntimeCommand}
  alias BeamAgent.Session.{Context, EventLog}

  def start_link(opts) do
    id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:agent, id))
  end

  def ask(session_id, prompt, timeout \\ :infinity) do
    with {:ok, pid} <- Names.pid(:agent, session_id) do
      GenServer.call(pid, {:ask, prompt}, timeout)
    end
  end

  def status(session_id) do
    with {:ok, pid} <- Names.pid(:agent, session_id) do
      GenServer.call(pid, :status)
    end
  end

  def context_options(session_id) do
    with {:ok, pid} <- Names.pid(:agent, session_id) do
      GenServer.call(pid, :context_options)
    end
  end

  def runtime_identity(session_id) do
    with {:ok, pid} <- Names.pid(:agent, session_id) do
      GenServer.call(pid, :runtime_identity)
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

    with {:ok, provider_module} <- CapabilityCatalog.provider(provider),
         :ok <- validate_strategy(strategy),
         {:ok, _project_context} <- Context.snapshot(session_id) do
      {:ok, existing} = EventLog.events(session_id)

      state = %{
        session_id: session_id,
        parent_session_id: Keyword.get(opts, :parent_session_id),
        inherited_correlation_id: Keyword.get(opts, :correlation_id),
        inherited_causation_id: Keyword.get(opts, :causation_id),
        project_id: Keyword.fetch!(opts, :project_id),
        goal_id: Keyword.fetch!(opts, :goal_id),
        provider: provider,
        provider_profile: Keyword.get(opts, :provider_profile),
        provider_module: provider_module,
        provider_options: Keyword.get(opts, :provider_options, []),
        model_strategy: Keyword.get(opts, :model_strategy, :manual),
        strategy: strategy,
        data_dir: data_dir,
        workspace_root: Keyword.fetch!(opts, :workspace_root),
        approval_policy: Keyword.get(opts, :approval_policy, :ask),
        approval_handler: Keyword.get(opts, :approval_handler),
        capability_envelope: Keyword.fetch!(opts, :capability_envelope),
        context_window_tokens: Keyword.get(opts, :context_window_tokens, 32_000),
        compaction_threshold_percent: Keyword.get(opts, :compaction_threshold_percent, 75),
        status: :idle,
        current_turn: nil
      }

      {:ok, _} =
        EventLog.append(session_id, :agent_started, %{
          "pid" => inspect(self()),
          "recovered" => Enum.any?(existing, &(&1["type"] == "agent_started")),
          "provider" => to_string(provider),
          "provider_profile" => Keyword.get(opts, :provider_profile),
          "model" => state.provider_options[:model],
          "project_id" => state.project_id,
          "goal_id" => state.goal_id
        })

      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:ask, prompt}, from, %{current_turn: nil} = state)
      when is_binary(prompt) and prompt != "" do
    command =
      RuntimeCommand.new(
        :submit_prompt,
        %{
          project_id: state.project_id,
          goal_id: state.goal_id,
          session_id: state.session_id,
          worker_id: state.session_id
        },
        correlation_id: state.inherited_correlation_id,
        causation_id: state.inherited_causation_id
      )

    metadata = [
      correlation_id: command.correlation_id,
      causation_id: command.causation_id
    ]

    with {:ok, command_event} <-
           EventLog.append(
             state.session_id,
             :command_received,
             %{
               "command_id" => command.command_id,
               "name" => command.name,
               "version" => command.version
             },
             metadata
           ),
         {:ok, supervisor} <- Names.pid(:resource_supervisor, state.session_id) do
      start_turn(supervisor, state, from, prompt, command, command_event)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:ask, _prompt}, _from, %{current_turn: current} = state)
      when not is_nil(current),
      do: {:reply, {:error, :agent_busy}, state}

  def handle_call({:ask, _prompt}, _from, state), do: {:reply, {:error, :empty_prompt}, state}
  def handle_call(:status, _from, state), do: {:reply, {:ok, state.status}, state}

  def handle_call(:runtime_identity, _from, state) do
    identity =
      Map.take(state, [
        :session_id,
        :project_id,
        :goal_id,
        :workspace_root,
        :data_dir,
        :capability_envelope
      ])

    {:reply, {:ok, identity}, state}
  end

  def handle_call(:context_options, _from, %{current_turn: nil} = state) do
    options =
      Map.take(state, [
        :provider_module,
        :provider_options,
        :context_window_tokens,
        :compaction_threshold_percent,
        :capability_envelope,
        :model_strategy
      ])

    {:reply, {:ok, options}, state}
  end

  def handle_call(:context_options, _from, state),
    do: {:reply, {:error, :agent_busy}, state}

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
          EventLog.append(
            state.session_id,
            :turn_cancelled,
            %{
              "reason" => inspect(reason),
              "command_id" => current.command.command_id
            },
            correlation_id: current.command.correlation_id
          )

        _ = record_task_outcome(state, current, :cancelled, reason, true)

        {:error, :cancelled}
      else
        _ =
          EventLog.append(
            state.session_id,
            :turn_worker_failed,
            %{
              "reason" => inspect(reason),
              "command_id" => current.command.command_id
            },
            correlation_id: current.command.correlation_id
          )

        _ = record_task_outcome(state, current, :failed, reason, false)

        {:error, {:turn_process_exit, reason}}
      end

    GenServer.reply(current.from, result)
    {:noreply, %{state | status: :idle, current_turn: nil}}
  end

  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:turn_result, _ref, _pid, _result}, state), do: {:noreply, state}

  defp start_turn(supervisor, state, from, prompt, command, command_event) do
    agent = self()
    turn_ref = make_ref()
    command = Map.put(command, :event_id, event_id(command_event))
    turn_context = Map.put(state, :runtime_command, command)

    task = fn ->
      # The session resource supervisor owns the worker, while this extra link
      # ensures an in-flight turn cannot outlive the agent that accepted it.
      Process.link(agent)
      result = state.strategy.run(turn_context, prompt)
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
          prompt: prompt,
          command: command,
          cancel_requested: false
        }

        {:noreply, %{state | status: :running, current_turn: current}}

      {:error, reason} ->
        _ =
          EventLog.append(
            state.session_id,
            :command_failed,
            %{"command_id" => command.command_id, "error" => inspect(reason)},
            correlation_id: command.correlation_id,
            causation_id: command.event_id
          )

        {:reply, {:error, {:turn_start_failed, reason}}, state}
    end
  end

  defp event_id(event), do: "#{event["session_id"]}:#{event["seq"]}"

  defp record_task_outcome(state, current, status, reason, cancelled) do
    classification = BeamAgent.TaskClassifier.classify(current.prompt, state.workspace_root)

    BeamAgent.OutcomeStore.record(state.project_id, %{
      kind: :task,
      goal_id: state.goal_id,
      session_id: state.session_id,
      task_type: classification.task_type,
      language: classification.language,
      status: status,
      cancelled: cancelled,
      failure: reason
    })
  end

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
