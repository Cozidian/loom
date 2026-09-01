defmodule BeamAgent.Goal.DelegationManager do
  @moduledoc "Goal-owned protocol for delegated work and its result lifecycle."
  use GenServer

  alias BeamAgent.{Names, WorkerResult}
  alias BeamAgent.Session.EventLog

  def start_link(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:goal_delegation_manager, goal_id))
  end

  def request(goal_id, parent_id, worker_id, goal, completion_criteria) do
    call(goal_id, {:request, parent_id, worker_id, goal, completion_criteria})
  end

  def accept(goal_id, delegation_id, spec_id),
    do: call(goal_id, {:accept, delegation_id, spec_id})

  def reject(goal_id, delegation_id, reason), do: call(goal_id, {:reject, delegation_id, reason})

  def progress(goal_id, delegation_id, progress),
    do: call(goal_id, {:progress, delegation_id, progress})

  def start(goal_id, handle, prompt) when is_binary(prompt) and prompt != "",
    do: call(goal_id, {:start, handle, prompt})

  def await(goal_id, delegation_id, timeout_ms \\ 120_000)
      when is_binary(delegation_id) and is_integer(timeout_ms) and timeout_ms >= 0,
      do: call(goal_id, {:await, delegation_id, timeout_ms}, :infinity)

  def status(goal_id, delegation_id) when is_binary(delegation_id),
    do: call(goal_id, {:status, delegation_id})

  def complete(
        goal_id,
        delegation_id,
        worker_id,
        content,
        verification \\ %{status: :unverified}
      ),
      do: call(goal_id, {:complete, delegation_id, worker_id, content, verification})

  def cancel(goal_id, delegation_id, reason \\ :cancelled),
    do: call(goal_id, {:cancel, delegation_id, reason})

  def list(goal_id), do: call(goal_id, :list)

  @impl true
  def init(opts) do
    {:ok,
     %{
       goal_id: Keyword.fetch!(opts, :goal_id),
       root_session_id: Keyword.fetch!(opts, :session_id),
       delegations: %{},
       runs: %{},
       awaiters: %{}
     }}
  end

  @impl true
  def handle_call({:request, parent_id, worker_id, goal, criteria}, _from, state) do
    if is_binary(goal) and goal != "" and is_binary(criteria) and criteria != "" do
      id = "delegation-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

      delegation = %{
        id: id,
        goal_id: state.goal_id,
        parent_worker_id: parent_id,
        worker_id: worker_id,
        goal_fingerprint: hash(goal),
        completion_criteria_fingerprint: hash(criteria),
        status: :requested,
        spec_id: nil,
        result: nil,
        requested_at: DateTime.utc_now()
      }

      state = put_in(state, [:delegations, id], delegation)
      record(state, :delegation_requested, delegation, %{})
      {:reply, {:ok, delegation}, state}
    else
      {:reply, {:error, :invalid_delegation}, state}
    end
  end

  def handle_call({:accept, id, spec_id}, _from, state),
    do: transition(state, id, :accepted, :delegation_accepted, %{spec_id: spec_id})

  def handle_call({:reject, id, reason}, _from, state),
    do: transition(state, id, :rejected, :delegation_rejected, %{reason: error_code(reason)})

  def handle_call({:progress, id, progress}, _from, state) do
    fingerprint = hash(inspect(progress, limit: 100))
    transition(state, id, :running, :delegation_progressed, %{progress_fingerprint: fingerprint})
  end

  def handle_call({:start, handle, prompt}, _from, state) do
    id = handle.delegation_id

    case {state.delegations[id], state.runs[id]} do
      {%{worker_id: worker_id, status: status} = delegation, nil}
      when worker_id == handle.worker_id and status in [:accepted, :requested] ->
        with {:ok, supervisor} <- Names.pid(:goal_resource_supervisor, state.goal_id) do
          manager = self()

          task = fn ->
            result = BeamAgent.Agent.ask(worker_id, prompt)
            send(manager, {:delegation_runner_result, id, self(), result})
          end

          case DynamicSupervisor.start_child(supervisor, {Task, task}) do
            {:ok, pid} ->
              delegation = %{delegation | status: :running}

              state =
                state
                |> put_in([:delegations, id], delegation)
                |> put_in([:runs, id], %{pid: pid, monitor: Process.monitor(pid)})

              record(state, :delegation_started, delegation, %{})
              {:reply, :ok, state}

            {:error, reason} ->
              {:reply, {:error, {:delegation_start_failed, reason}}, state}
          end
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {%{status: :running}, _run} ->
        {:reply, {:error, :delegation_already_running}, state}

      {%{status: :completed, result: result}, _run} ->
        {:reply, {:ok, result}, state}

      {nil, _run} ->
        {:reply, {:error, :unknown_delegation}, state}

      {_delegation, _run} ->
        {:reply, {:error, :delegation_not_startable}, state}
    end
  end

  def handle_call({:await, id, timeout_ms}, from, state) do
    case state.delegations[id] do
      %{status: :completed, result: result} ->
        {:reply, {:ok, result}, state}

      %{status: :failed, result: result} ->
        {:reply, {:error, result}, state}

      %{status: :cancelled} ->
        {:reply, {:error, :cancelled}, state}

      %{status: status} when status in [:running, :accepted, :requested] and timeout_ms == 0 ->
        {:reply, {:error, :not_ready}, state}

      %{status: status} when status in [:running, :accepted, :requested] ->
        token = make_ref()
        timer = Process.send_after(self(), {:delegation_await_timeout, id, token}, timeout_ms)
        awaiter = %{from: from, timer: timer, token: token}
        {:noreply, update_in(state, [:awaiters, id], &[awaiter | &1 || []])}

      nil ->
        {:reply, {:error, :unknown_delegation}, state}

      %{status: status} ->
        {:reply, {:error, {:delegation_not_awaitable, status}}, state}
    end
  end

  def handle_call({:status, id}, _from, state) do
    case state.delegations[id] do
      nil -> {:reply, {:error, :unknown_delegation}, state}
      delegation -> {:reply, {:ok, public_delegation(delegation)}, state}
    end
  end

  def handle_call({:complete, id, worker_id, content, verification}, _from, state) do
    case state.delegations[id] do
      %{worker_id: ^worker_id} = delegation ->
        result = WorkerResult.new(worker_id, id, :completed, content, verification)
        delegation = %{delegation | status: :completed, result: result}
        state = put_in(state, [:delegations, id], delegation)

        record(state, :delegation_completed, delegation, %{
          result_fingerprint: hash(content),
          verification_status: verification[:status] || verification["status"] || :unverified
        })

        {:reply, {:ok, result}, state}

      nil ->
        {:reply, {:error, :unknown_delegation}, state}

      _other ->
        {:reply, {:error, :delegation_worker_mismatch}, state}
    end
  end

  def handle_call({:cancel, id, reason}, _from, state) do
    case state.delegations[id] do
      nil ->
        {:reply, {:error, :unknown_delegation}, state}

      %{status: status} when status in [:completed, :failed, :cancelled, :rejected] ->
        {:reply, {:error, {:delegation_terminal, status}}, state}

      delegation ->
        state = stop_run(state, id)
        delegation = %{delegation | status: :cancelled}
        state = put_in(state, [:delegations, id], delegation)
        record(state, :delegation_cancelled, delegation, %{reason: error_code(reason)})
        state = reply_awaiters(state, id, {:error, :cancelled})
        send(self(), {:stop_delegated_session, delegation.worker_id})
        {:reply, :ok, state}
    end
  end

  def handle_call(:list, _from, state) do
    values =
      state.delegations
      |> Map.values()
      |> Enum.map(&public_delegation/1)
      |> Enum.sort_by(& &1.requested_at, DateTime)

    {:reply, {:ok, values}, state}
  end

  @impl true
  def handle_info({:delegation_runner_result, id, pid, result}, state) do
    case state.runs[id] do
      %{pid: ^pid, monitor: monitor} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | runs: Map.delete(state.runs, id)}
        {reply, state} = finish_async(state, id, result)
        state = reply_awaiters(state, id, reply)
        send(self(), {:stop_delegated_session, state.delegations[id].worker_id})
        {:noreply, state}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Enum.find(state.runs, fn {_id, run} -> run.monitor == monitor end) do
      {id, _run} ->
        state = %{state | runs: Map.delete(state.runs, id)}
        {reply, state} = finish_async(state, id, {:error, {:runner_exit, reason}})
        state = reply_awaiters(state, id, reply)
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:delegation_await_timeout, id, token}, state) do
    {expired, retained} =
      state.awaiters
      |> Map.get(id, [])
      |> Enum.split_with(&(&1.token == token))

    Enum.each(expired, &GenServer.reply(&1.from, {:error, :await_timeout}))
    {:noreply, put_awaiters(state, id, retained)}
  end

  def handle_info({:stop_delegated_session, worker_id}, state) do
    _ = BeamAgent.stop_session(worker_id)
    {:noreply, state}
  end

  defp transition(state, id, status, event, extra) do
    case state.delegations[id] do
      nil ->
        {:reply, {:error, :unknown_delegation}, state}

      delegation ->
        delegation = Map.merge(delegation, extra) |> Map.put(:status, status)
        state = put_in(state, [:delegations, id], delegation)
        record(state, event, delegation, extra)
        {:reply, :ok, state}
    end
  end

  defp record(state, type, delegation, extra) do
    data =
      Map.merge(
        %{
          "delegation_id" => delegation.id,
          "parent_worker_id" => delegation.parent_worker_id,
          "worker_id" => delegation.worker_id,
          "status" => to_string(delegation.status),
          "goal_fingerprint" => delegation.goal_fingerprint,
          "completion_criteria_fingerprint" => delegation.completion_criteria_fingerprint
        },
        Map.new(extra, fn {key, value} -> {to_string(key), stringify(value)} end)
      )

    _ = EventLog.append(state.root_session_id, type, data)
    :ok
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp stringify(value) when is_atom(value), do: to_string(value)
  defp stringify(value), do: value
  defp error_code(reason) when is_atom(reason), do: to_string(reason)
  defp error_code(reason) when is_tuple(reason), do: reason |> elem(0) |> error_code()
  defp error_code(_reason), do: "delegation_failed"

  defp finish_async(state, id, {:ok, content}) do
    delegation = state.delegations[id]
    result = WorkerResult.new(delegation.worker_id, id, :completed, content)
    delegation = %{delegation | status: :completed, result: result}
    state = put_in(state, [:delegations, id], delegation)

    record(state, :delegation_completed, delegation, %{
      result_fingerprint: hash(content),
      verification_status: :unverified
    })

    {{:ok, result}, state}
  end

  defp finish_async(state, id, {:error, reason}) do
    delegation = state.delegations[id]
    result = WorkerResult.new(delegation.worker_id, id, :failed, inspect(reason))
    delegation = %{delegation | status: :failed, result: result}
    state = put_in(state, [:delegations, id], delegation)
    record(state, :delegation_failed, delegation, %{reason: error_code(reason)})
    {{:error, result}, state}
  end

  defp stop_run(state, id) do
    case state.runs[id] do
      nil ->
        state

      %{pid: pid, monitor: monitor} ->
        Process.demonitor(monitor, [:flush])
        Process.exit(pid, :shutdown)
        %{state | runs: Map.delete(state.runs, id)}
    end
  end

  defp reply_awaiters(state, id, reply) do
    Enum.each(Map.get(state.awaiters, id, []), fn awaiter ->
      Process.cancel_timer(awaiter.timer)
      GenServer.reply(awaiter.from, reply)
    end)

    put_awaiters(state, id, [])
  end

  defp put_awaiters(state, id, []), do: %{state | awaiters: Map.delete(state.awaiters, id)}
  defp put_awaiters(state, id, awaiters), do: put_in(state, [:awaiters, id], awaiters)

  defp public_delegation(delegation), do: Map.take(delegation, Map.keys(delegation))

  defp call(goal_id, message, timeout \\ 5_000) do
    with {:ok, pid} <- Names.pid(:goal_delegation_manager, goal_id),
         do: GenServer.call(pid, message, timeout)
  end
end
