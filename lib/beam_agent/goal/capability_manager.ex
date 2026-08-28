defmodule BeamAgent.Goal.CapabilityManager do
  @moduledoc "Goal-owned temporary capability leases and escalation requests."
  use GenServer

  alias BeamAgent.{Agent, CapabilityEnvelope, Names}
  alias BeamAgent.Session.{EventLog, ToolPolicy}

  @maximum_duration_ms 3_600_000

  def start_link(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:goal_capability_manager, goal_id))
  end

  def issue(goal_id, parent_worker_id, worker_id, requested, opts \\ []) do
    call(goal_id, {:issue, parent_worker_id, worker_id, requested, opts})
  end

  def request(worker_id, request) when is_map(request) do
    with {:ok, context} <- Agent.construction_context(worker_id),
         parent_id when is_binary(parent_id) <- context.parent_session_id do
      call(context.goal_id, {:request, parent_id, worker_id, request})
    else
      nil -> {:error, :root_worker_cannot_escalate_to_itself}
      {:error, reason} -> {:error, reason}
    end
  end

  def permits?(goal_id, worker_id, resource),
    do: call(goal_id, {:permits, worker_id, resource})

  def authorize(goal_id, worker_id, resource),
    do: call(goal_id, {:authorize, worker_id, resource})

  def revoke(goal_id, lease_id, reason \\ :revoked),
    do: call(goal_id, {:revoke, lease_id, reason})

  def leases(goal_id), do: call(goal_id, :leases)

  @impl true
  def init(opts) do
    {:ok,
     %{
       goal_id: Keyword.fetch!(opts, :goal_id),
       root_session_id: Keyword.fetch!(opts, :session_id),
       leases: %{},
       worker_leases: %{},
       monitors: %{}
     }}
  end

  @impl true
  def handle_call({:issue, parent_id, worker_id, requested, opts}, _from, state) do
    case build_lease(parent_id, worker_id, requested, opts) do
      {:ok, lease, owner} ->
        state = store_lease(state, lease, owner)
        record(state, :capability_lease_issued, lease, %{})
        {:reply, {:ok, public(lease)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:request, parent_id, worker_id, request}, _from, state) do
    with {:ok, normalized} <- normalize_request(request),
         :ok <- record_request(state, worker_id, normalized),
         :ok <- approve_escalation(parent_id, normalized),
         {:ok, lease, owner} <-
           build_lease(parent_id, worker_id, normalized.capabilities,
             duration_ms: normalized.duration_ms,
             operations: normalized.operations,
             purpose: normalized.purpose,
             source: :approved_escalation
           ) do
      state = store_lease(state, lease, owner)
      record(state, :capability_request_approved, lease, %{})
      record(state, :capability_lease_issued, lease, %{})
      {:reply, {:ok, public(lease)}, state}
    else
      {:error, reason} = error ->
        record_denial(state, worker_id, reason)
        {:reply, error, state}
    end
  end

  def handle_call({:permits, worker_id, resource}, _from, state) do
    {permitted?, state} = find_permitting_lease(state, worker_id, resource, false)
    {:reply, permitted?, state}
  end

  def handle_call({:authorize, worker_id, resource}, _from, state) do
    case find_permitting_lease(state, worker_id, resource, true) do
      {{:ok, lease_id}, state} ->
        {:reply, {:ok, lease_id}, state}

      {false, state} ->
        {:reply, {:error, :capability_lease_denied}, state}
    end
  end

  def handle_call({:revoke, lease_id, reason}, _from, state) do
    {reply, state} = revoke_lease(state, lease_id, reason)
    {:reply, reply, state}
  end

  def handle_call(:leases, _from, state) do
    leases = state.leases |> Map.values() |> Enum.map(&public/1) |> Enum.sort_by(& &1.id)
    {:reply, {:ok, leases}, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {worker_id, monitors} ->
        state = %{state | monitors: monitors}

        state =
          state.worker_leases
          |> Map.get(worker_id, MapSet.new())
          |> Enum.reduce(state, fn lease_id, acc ->
            {_reply, acc} = revoke_lease(acc, lease_id, {:owner_down, reason})
            acc
          end)

        {:noreply, state}
    end
  end

  def handle_info({:expire_lease, lease_id}, state) do
    case state.leases[lease_id] do
      %{status: :active} ->
        {_reply, state} = revoke_lease(state, lease_id, :expired)
        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  defp build_lease(parent_id, worker_id, requested, opts) do
    with true <- is_map(requested) or {:error, :invalid_capability_request},
         {:ok, parent} <- Agent.construction_context(parent_id),
         {:ok, worker} <- Agent.construction_context(worker_id),
         true <- parent.goal_id == worker.goal_id or {:error, :cross_goal_capability_request},
         true <-
           worker.parent_session_id == parent_id or {:error, :capability_issuer_not_parent},
         {:ok, _bounded} <- CapabilityEnvelope.restrict(parent.capability_envelope, requested),
         {:ok, owner} <- Names.pid(:agent, worker_id) do
      duration_ms = normalize_duration(Keyword.get(opts, :duration_ms, 300_000))
      operations = normalize_operations(Keyword.get(opts, :operations, :infinity))
      now = System.monotonic_time(:millisecond)

      {:ok,
       %{
         id: lease_id(),
         goal_id: parent.goal_id,
         parent_worker_id: parent_id,
         worker_id: worker_id,
         envelope: CapabilityEnvelope.root(requested),
         operations_remaining: operations,
         expires_monotonic_ms: now + duration_ms,
         expires_at: DateTime.add(DateTime.utc_now(), duration_ms, :millisecond),
         purpose: Keyword.get(opts, :purpose, "temporary delegated authority"),
         source: Keyword.get(opts, :source, :runtime_policy),
         status: :active
       }, owner}
    else
      false -> {:error, :invalid_capability_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_request(request) do
    capabilities = value(request, :capabilities)
    purpose = value(request, :purpose)

    if is_map(capabilities) and is_binary(purpose) and purpose != "" do
      {:ok,
       %{
         capabilities: capabilities,
         purpose: purpose,
         duration_ms: normalize_duration(value(request, :duration_ms) || 300_000),
         operations: normalize_operations(value(request, :operations) || 1),
         fallback: value(request, :fallback) || "continue_without_capability"
       }}
    else
      {:error, :invalid_capability_request}
    end
  end

  defp approve_escalation(parent_id, request) do
    resource = %{
      capability_request: request.capabilities,
      duration_ms: request.duration_ms,
      operations: request.operations
    }

    ToolPolicy.authorize(
      parent_id,
      "capability_escalation",
      %{"purpose" => request.purpose, "fallback" => request.fallback},
      :write,
      resource
    )
  end

  defp store_lease(state, lease, owner) do
    monitor =
      case Enum.find(state.monitors, fn {_monitor, worker_id} -> worker_id == lease.worker_id end) do
        {monitor, _worker_id} -> monitor
        nil -> Process.monitor(owner)
      end

    _ =
      Process.send_after(
        self(),
        {:expire_lease, lease.id},
        max(lease.expires_monotonic_ms - System.monotonic_time(:millisecond), 1)
      )

    state
    |> put_in([:leases, lease.id], lease)
    |> update_in(
      [:worker_leases, lease.worker_id],
      &MapSet.put(&1 || MapSet.new(), lease.id)
    )
    |> put_in([:monitors, monitor], lease.worker_id)
  end

  defp find_permitting_lease(state, worker_id, resource, consume?) do
    ids = Map.get(state.worker_leases, worker_id, MapSet.new())
    now = System.monotonic_time(:millisecond)

    Enum.reduce_while(ids, {false, state}, fn lease_id, {_result, acc} ->
      lease = acc.leases[lease_id]

      cond do
        lease.status != :active ->
          {:cont, {false, acc}}

        lease.expires_monotonic_ms <= now ->
          {_reply, acc} = revoke_lease(acc, lease_id, :expired)
          {:cont, {false, acc}}

        lease.operations_remaining == 0 ->
          {_reply, acc} = revoke_lease(acc, lease_id, :operations_exhausted)
          {:cont, {false, acc}}

        CapabilityEnvelope.authorize(lease.envelope, resource) == :ok ->
          if consume? do
            lease = consume_operation(lease)
            acc = put_in(acc, [:leases, lease_id], lease)

            record(acc, :capability_lease_consumed, lease, %{
              "operations_remaining" => public_operations(lease.operations_remaining)
            })

            {:halt, {{:ok, lease_id}, acc}}
          else
            {:halt, {true, acc}}
          end

        true ->
          {:cont, {false, acc}}
      end
    end)
  end

  defp revoke_lease(state, lease_id, reason) do
    case state.leases[lease_id] do
      nil ->
        {{:error, :unknown_capability_lease}, state}

      %{status: :revoked} ->
        {:ok, state}

      lease ->
        lease = %{lease | status: :revoked}
        state = put_in(state, [:leases, lease_id], lease)
        record(state, :capability_lease_revoked, lease, %{"reason" => inspect(reason)})
        {:ok, state}
    end
  end

  defp record_request(_state, worker_id, request) do
    EventLog.append(worker_id, :capability_requested, %{
      "purpose_fingerprint" => hash(request.purpose),
      "duration_ms" => request.duration_ms,
      "operations" => public_operations(request.operations),
      "fallback" => request.fallback,
      "requested_scopes" => request.capabilities |> Map.keys() |> Enum.map(&to_string/1)
    })
    |> case do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_denial(_state, worker_id, reason) do
    _ =
      EventLog.append(worker_id, :capability_request_denied, %{
        "reason" => error_code(reason)
      })

    :ok
  end

  defp record(state, type, lease, extra) do
    data =
      Map.merge(
        %{
          "lease_id" => lease.id,
          "worker_id" => lease.worker_id,
          "parent_worker_id" => lease.parent_worker_id,
          "expires_at" => DateTime.to_iso8601(lease.expires_at),
          "operations_remaining" => public_operations(lease.operations_remaining),
          "source" => to_string(lease.source)
        },
        extra
      )

    _ = EventLog.append(state.root_session_id, type, data)
    :ok
  end

  defp public(lease) do
    %{
      id: lease.id,
      goal_id: lease.goal_id,
      parent_worker_id: lease.parent_worker_id,
      worker_id: lease.worker_id,
      scopes: lease.envelope.scopes,
      operations_remaining: lease.operations_remaining,
      expires_at: lease.expires_at,
      purpose_fingerprint: hash(lease.purpose),
      source: lease.source,
      status: lease.status
    }
  end

  defp consume_operation(%{operations_remaining: :infinity} = lease), do: lease

  defp consume_operation(%{operations_remaining: remaining} = lease),
    do: %{lease | operations_remaining: max(remaining - 1, 0)}

  defp normalize_duration(value) when is_integer(value) and value > 0,
    do: min(value, @maximum_duration_ms)

  defp normalize_duration(_value), do: 300_000
  defp normalize_operations(:infinity), do: :infinity
  defp normalize_operations("infinity"), do: :infinity
  defp normalize_operations(value) when is_integer(value) and value > 0, do: value
  defp normalize_operations(_value), do: 1
  defp public_operations(:infinity), do: "infinity"
  defp public_operations(value), do: value
  defp value(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp lease_id, do: "lease-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
  defp error_code(reason) when is_atom(reason), do: to_string(reason)
  defp error_code(reason) when is_tuple(reason), do: reason |> elem(0) |> error_code()
  defp error_code(_reason), do: "capability_request_denied"

  defp call(goal_id, message) do
    with {:ok, pid} <- Names.pid(:goal_capability_manager, goal_id),
         do: GenServer.call(pid, message, :infinity)
  end
end
