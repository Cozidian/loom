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
       delegations: %{}
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

  def handle_call({:cancel, id, reason}, _from, state),
    do: transition(state, id, :cancelled, :delegation_cancelled, %{reason: error_code(reason)})

  def handle_call(:list, _from, state) do
    values = state.delegations |> Map.values() |> Enum.sort_by(& &1.requested_at, DateTime)
    {:reply, {:ok, values}, state}
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

  defp call(goal_id, message) do
    with {:ok, pid} <- Names.pid(:goal_delegation_manager, goal_id),
         do: GenServer.call(pid, message)
  end
end
