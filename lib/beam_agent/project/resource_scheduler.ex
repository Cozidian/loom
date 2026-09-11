defmodule BeamAgent.Project.ResourceScheduler do
  @moduledoc """
  Project-owned bounded pools for model, tool, MCP, browser, embedding, and CPU work.

  Calls wait through OTP backpressure. Queued owners are monitored so abandoned
  requests disappear, and every granted slot is reclaimed on release or owner
  death.
  """
  use GenServer

  alias BeamAgent.Names
  alias BeamAgent.Session.EventLog

  @default_limits %{
    model: 4,
    expensive_model: 1,
    shell: 2,
    test: 1,
    browser: 1,
    mcp: 4,
    embeddings: 2,
    cpu: 2
  }

  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)

    GenServer.start_link(__MODULE__, opts,
      name: Names.via(:project_resource_scheduler, project_id)
    )
  end

  def run(project_id, pool, opts \\ [], fun) when is_function(fun, 0) do
    with {:ok, lease} <- acquire(project_id, pool, self(), opts) do
      try do
        fun.()
      after
        _ = release(project_id, lease.id)
      end
    end
  end

  def acquire(project_id, pool, owner \\ self(), opts \\ []) when is_pid(owner) do
    call(project_id, {:acquire, pool, owner, opts}, :infinity)
  end

  def release(project_id, lease_id), do: call(project_id, {:release, lease_id})
  def snapshot(project_id), do: call(project_id, :snapshot)

  @impl true
  def init(opts) do
    configured = Keyword.get(opts, :resource_limits, %{})
    limits = Map.merge(@default_limits, normalize_limits(configured))

    pools =
      Map.new(limits, fn {kind, limit} ->
        {kind, %{limit: max(1, limit), active: %{}, queue: []}}
      end)

    {:ok, %{project_id: Keyword.fetch!(opts, :project_id), pools: pools, monitors: %{}}}
  end

  @impl true
  def handle_call({:acquire, kind, owner, opts}, from, state) do
    case state.pools[kind] do
      nil ->
        {:reply, {:error, {:unknown_resource_pool, kind}}, state}

      pool ->
        request = %{
          id: new_id("resource-request"),
          kind: kind,
          owner: owner,
          from: from,
          priority: Keyword.get(opts, :priority, 0),
          session_id: Keyword.get(opts, :session_id),
          parent_session_id: Keyword.get(opts, :parent_session_id),
          requested_at: System.monotonic_time(:millisecond)
        }

        state = monitor_owner(state, owner)

        case grant_disposition(pool, request) do
          {:grant, borrowed_from_session_id} ->
            request = Map.put(request, :borrowed_from_session_id, borrowed_from_session_id)
            {lease, state} = grant(state, request)
            {:reply, {:ok, lease}, state}

          :queue ->
            pool = %{pool | queue: insert_queued(pool.queue, request)}
            state = put_in(state, [:pools, kind], pool)

            record(request.session_id, :resource_queued, request, %{
              queue_depth: length(pool.queue)
            })

            {:noreply, state}
        end
    end
  end

  def handle_call({:release, lease_id}, _from, state) do
    case find_active(state.pools, lease_id) do
      nil ->
        {:reply, {:error, :unknown_resource_lease}, state}

      {kind, lease} ->
        state = remove_active(state, kind, lease_id)
        record(lease.session_id, :resource_released, lease, %{})
        {:reply, :ok, grant_next(state, kind)}
    end
  end

  def handle_call(:snapshot, _from, state) do
    snapshot =
      Map.new(state.pools, fn {kind, pool} ->
        {kind, %{limit: pool.limit, active: map_size(pool.active), queued: length(pool.queue)}}
      end)

    {:reply, {:ok, snapshot}, state}
  end

  @impl true
  def handle_info({:DOWN, reference, :process, owner, _reason}, state) do
    state = %{state | monitors: Map.delete(state.monitors, reference)}

    affected =
      for {kind, pool} <- state.pools,
          {_id, lease} <- pool.active,
          lease.owner == owner,
          do: {kind, lease}

    state =
      Enum.reduce(affected, state, fn {kind, lease}, acc ->
        record(lease.session_id, :resource_reclaimed, lease, %{reason: "owner_down"})
        acc |> remove_active(kind, lease.id) |> grant_next(kind)
      end)

    pools =
      Map.new(state.pools, fn {kind, pool} ->
        {kind, %{pool | queue: Enum.reject(pool.queue, &(&1.owner == owner))}}
      end)

    {:noreply, %{state | pools: pools}}
  end

  defp grant(state, request) do
    lease = %{
      id: new_id("resource-lease"),
      kind: request.kind,
      owner: request.owner,
      session_id: request.session_id,
      borrowed_from_session_id: request[:borrowed_from_session_id],
      wait_ms: System.monotonic_time(:millisecond) - request.requested_at,
      granted_at: DateTime.utc_now()
    }

    state = put_in(state, [:pools, request.kind, :active, lease.id], lease)
    extra = %{wait_ms: lease.wait_ms}

    extra =
      if lease.borrowed_from_session_id do
        Map.put(extra, :borrowed_from_session_id, lease.borrowed_from_session_id)
      else
        extra
      end

    record(request.session_id, :resource_granted, lease, extra)

    {lease, state}
  end

  defp grant_next(state, kind) do
    pool = state.pools[kind]

    case pop_grantable(pool) do
      :none ->
        state

      {request, borrowed_from_session_id, remaining} ->
        request = Map.put(request, :borrowed_from_session_id, borrowed_from_session_id)
        state = put_in(state, [:pools, kind, :queue], remaining)
        {lease, state} = grant(state, request)
        GenServer.reply(request.from, {:ok, lease})
        state
    end
  end

  # A provider invocation may synchronously execute delegate_tasks while holding
  # its model lease. Let one direct child borrow capacity from that parent lease
  # so the parent cannot deadlock waiting for work queued behind itself. The
  # single-borrow rule keeps the configured limit authoritative for unrelated
  # work and prevents a fan-out from growing the pool without bound.
  defp grant_disposition(pool, request) do
    parent_session_id = request.parent_session_id

    cond do
      map_size(pool.active) < pool.limit ->
        {:grant, nil}

      is_binary(parent_session_id) and parent_active?(pool, parent_session_id) and
          not parent_already_borrowed?(pool, parent_session_id) ->
        {:grant, parent_session_id}

      true ->
        :queue
    end
  end

  defp parent_active?(pool, parent_session_id) do
    Enum.any?(pool.active, fn {_id, lease} -> lease.session_id == parent_session_id end)
  end

  defp parent_already_borrowed?(pool, parent_session_id) do
    Enum.any?(pool.active, fn {_id, lease} ->
      lease.borrowed_from_session_id == parent_session_id
    end)
  end

  defp pop_grantable(pool) do
    Enum.reduce_while(Enum.with_index(pool.queue), :none, fn {request, index}, _acc ->
      case grant_disposition(pool, request) do
        {:grant, borrowed_from_session_id} ->
          {:halt, {request, borrowed_from_session_id, List.delete_at(pool.queue, index)}}

        :queue ->
          {:cont, :none}
      end
    end)
  end

  defp remove_active(state, kind, lease_id),
    do: update_in(state, [:pools, kind, :active], &Map.delete(&1, lease_id))

  defp find_active(pools, lease_id) do
    Enum.find_value(pools, fn {kind, pool} ->
      if lease = pool.active[lease_id], do: {kind, lease}
    end)
  end

  defp monitor_owner(state, owner) do
    if Enum.any?(state.monitors, fn {_reference, monitored} -> monitored == owner end) do
      state
    else
      reference = Process.monitor(owner)
      put_in(state, [:monitors, reference], owner)
    end
  end

  defp insert_queued(queue, request) do
    Enum.sort_by([request | queue], fn item -> {-item.priority, item.requested_at} end)
  end

  defp normalize_limits(limits) when is_map(limits) do
    Map.new(limits, fn {kind, limit} ->
      kind = if is_binary(kind), do: String.to_existing_atom(kind), else: kind
      {kind, limit}
    end)
  rescue
    ArgumentError -> %{}
  end

  defp normalize_limits(_limits), do: %{}

  defp record(nil, _type, _lease, _extra), do: :ok

  defp record(session_id, type, lease, extra) do
    data =
      Map.merge(
        %{
          "resource_pool" => to_string(lease.kind),
          "resource_lease_id" => lease.id
        },
        Map.new(extra, fn {key, value} -> {to_string(key), value} end)
      )

    _ = EventLog.append(session_id, type, data)
    :ok
  catch
    # Project capacity outlives a session. Its event log may stop between the
    # registry lookup and append during teardown; that must not crash the shared
    # scheduler and strand other sessions' waiters. Unexpected failures still exit.
    :exit, {reason, {GenServer, :call, _}} when reason in [:noproc, :normal, :shutdown] -> :ok
  end

  defp call(project_id, message, timeout \\ 5_000) do
    with {:ok, pid} <- Names.pid(:project_resource_scheduler, project_id),
         do: GenServer.call(pid, message, timeout)
  end

  defp new_id(prefix),
    do: prefix <> "-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
