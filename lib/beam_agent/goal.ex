defmodule BeamAgent.Goal do
  @moduledoc "The identity and state boundary for one ephemeral project goal."
  use GenServer

  alias BeamAgent.{Agent, Names, WorkContract}
  alias BeamAgent.Goal.ContextPacket
  alias BeamAgent.Goal.WorkArtifact
  alias BeamAgent.Session.EventLog

  def start_link(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:goal, goal_id))
  end

  def snapshot(goal_id) do
    with {:ok, pid} <- Names.pid(:goal, goal_id) do
      GenServer.call(pid, :snapshot)
    end
  end

  def submit(goal_id, prompt, attachment_ids \\ [], timeout \\ :infinity)
      when is_binary(prompt) and is_list(attachment_ids) do
    with {:ok, pid} <- Names.pid(:goal, goal_id) do
      GenServer.call(pid, {:submit, prompt, attachment_ids}, timeout)
    end
  end

  def status(goal_id) do
    with {:ok, pid} <- Names.pid(:goal, goal_id) do
      GenServer.call(pid, :status)
    end
  end

  def cancel(goal_id) do
    with {:ok, pid} <- Names.pid(:goal, goal_id) do
      GenServer.call(pid, :cancel)
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       goal_id: Keyword.fetch!(opts, :goal_id),
       project_id: Keyword.fetch!(opts, :project_id),
       session_id: Keyword.fetch!(opts, :session_id),
       workspace_root: Keyword.fetch!(opts, :workspace_root),
       objective: Keyword.get(opts, :objective),
       agent_spec: Keyword.fetch!(opts, :agent_spec),
       capability_envelope: Keyword.fetch!(opts, :capability_envelope),
       phase: :idle,
       current_work: nil,
       last_work: nil
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, state}, state}

  def handle_call(:status, _from, state),
    do: {:reply, {:ok, goal_status(state)}, state}

  def handle_call({:submit, prompt, attachment_ids}, from, %{current_work: nil} = state) do
    contract_objective =
      if String.trim(prompt) == "", do: "Process the attached user input", else: prompt

    with {:ok, context_packet} <- ContextPacket.build(state.project_id, contract_objective),
         {:ok, contract} <-
           WorkContract.new(contract_objective, state.workspace_root,
             context_packet: context_packet
           ),
         {:ok, supervisor} <- Names.pid(:goal_resource_supervisor, state.goal_id),
         {:ok, event} <-
           EventLog.append(state.session_id, :goal_work_started, %{
             "work_contract" => WorkContract.to_map(contract),
             "phase" => "executing"
           }) do
      goal = self()
      ref = make_ref()

      task = fn ->
        result = Agent.ask_with_contract(state.session_id, prompt, attachment_ids, contract)
        send(goal, {:goal_work_result, ref, self(), result})
      end

      case DynamicSupervisor.start_child(supervisor, {Task, task}) do
        {:ok, pid} ->
          current = %{
            ref: ref,
            pid: pid,
            monitor: Process.monitor(pid),
            from: from,
            contract: contract,
            started_event_id: event_id(event),
            cancel_requested: false
          }

          {:noreply, %{state | phase: :executing, current_work: current}}

        {:error, reason} ->
          {:reply, {:error, {:goal_work_start_failed, reason}}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:submit, _prompt, _attachments}, _from, state),
    do: {:reply, {:error, :goal_busy}, state}

  def handle_call(:cancel, _from, %{current_work: nil} = state),
    do: {:reply, {:error, :not_running}, state}

  def handle_call(:cancel, _from, state) do
    result = Agent.cancel(state.session_id)
    current = %{state.current_work | cancel_requested: true}
    {:reply, result, %{state | phase: :cancelling, current_work: current}}
  end

  @impl true
  def handle_info(
        {:goal_work_result, ref, pid, result},
        %{current_work: %{ref: ref, pid: pid} = current} = state
      ) do
    Process.demonitor(current.monitor, [:flush])
    status = result_status(result)

    artifact =
      case WorkArtifact.build(state, current.contract, result, current.started_event_id) do
        {:ok, artifact} -> artifact
        {:error, _reason} -> nil
      end

    _ =
      EventLog.append(state.session_id, :goal_work_finished, %{
        "contract_id" => current.contract.id,
        "status" => to_string(status),
        "expected_artifact" => to_string(current.contract.expected_artifact),
        "artifact_id" => artifact && artifact.id,
        "changed_files" => (artifact && artifact.changed_files) || []
      })

    GenServer.reply(current.from, result)

    last_work = %{
      contract: current.contract,
      status: status,
      artifact: artifact,
      finished_at: DateTime.utc_now()
    }

    {:noreply, %{state | phase: status, current_work: nil, last_work: last_work}}
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, %{current_work: current} = state)
      when current.monitor == monitor and current.pid == pid do
    result = if current.cancel_requested, do: {:error, :cancelled}, else: {:error, reason}
    GenServer.reply(current.from, result)
    {:noreply, %{state | phase: :failed, current_work: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp goal_status(state) do
    %{
      goal_id: state.goal_id,
      phase: state.phase,
      current_contract: state.current_work && state.current_work.contract,
      last_work: state.last_work
    }
  end

  defp result_status({:ok, _result}), do: :completed
  defp result_status({:error, :cancelled}), do: :cancelled
  defp result_status({:error, _reason}), do: :failed

  defp event_id(event), do: "#{event["session_id"]}:#{event["seq"]}"
end
