defmodule BeamAgent.Goal.SecretBroker do
  @moduledoc "Goal-owned broker for opaque, worker-bound secret handles."
  use GenServer

  alias BeamAgent.{Agent, CapabilityEnvelope, Names, Session.EventLog}

  def start_link(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:goal_secret_broker, goal_id))
  end

  def issue(goal_id, worker_id, kind, secret, opts \\ []) when is_binary(secret) do
    call(goal_id, {:issue, worker_id, kind, secret, opts})
  end

  def invoke(goal_id, worker_id, handle_id, resource, fun) when is_function(fun, 1) do
    call(goal_id, {:invoke, worker_id, handle_id, resource, fun})
  end

  def revoke(goal_id, handle_id), do: call(goal_id, {:revoke, handle_id})
  def handles(goal_id), do: call(goal_id, :handles)

  @impl true
  def init(opts) do
    {:ok,
     %{
       goal_id: Keyword.fetch!(opts, :goal_id),
       root_session_id: Keyword.fetch!(opts, :session_id),
       handles: %{},
       monitors: %{}
     }}
  end

  @impl true
  def handle_call({:issue, worker_id, kind, secret, opts}, _from, state) do
    with {:ok, owner} <- Names.pid(:agent, worker_id),
         {:ok, worker} <- Agent.construction_context(worker_id),
         true <- worker.goal_id == state.goal_id or {:error, :cross_goal_secret_handle},
         :ok <-
           CapabilityEnvelope.authorize(worker.capability_envelope, %{
             secret_kinds: to_string(kind)
           }) do
      id = "secret-handle-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      duration_ms = normalize_duration(Keyword.get(opts, :duration_ms, 300_000))

      handle = %{
        id: id,
        worker_id: worker_id,
        kind: to_string(kind),
        secret: secret,
        scopes: Keyword.get(opts, :scopes, %{}),
        expires_monotonic_ms: System.monotonic_time(:millisecond) + duration_ms,
        expires_at: DateTime.add(DateTime.utc_now(), duration_ms, :millisecond),
        status: :active
      }

      monitor = Process.monitor(owner)
      state = state |> put_in([:handles, id], handle) |> put_in([:monitors, monitor], id)
      record(state, :secret_handle_issued, handle)
      {:reply, {:ok, public(handle)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:invoke, worker_id, id, resource, fun}, _from, state) do
    case authorized_handle(state.handles[id], worker_id, resource) do
      {:ok, handle} ->
        result = safely_invoke(fun, handle.secret)
        record(state, :secret_handle_used, handle)
        {:reply, result, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:revoke, id}, _from, state) do
    case state.handles[id] do
      nil ->
        {:reply, {:error, :unknown_secret_handle}, state}

      handle ->
        handle = %{handle | status: :revoked, secret: nil}
        state = put_in(state, [:handles, id], handle)
        record(state, :secret_handle_revoked, handle)
        {:reply, :ok, state}
    end
  end

  def handle_call(:handles, _from, state) do
    handles = state.handles |> Map.values() |> Enum.map(&public/1) |> Enum.sort_by(& &1.id)
    {:reply, {:ok, handles}, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {id, monitors} ->
        handle = %{state.handles[id] | status: :revoked, secret: nil}
        state = %{state | monitors: monitors} |> put_in([:handles, id], handle)
        record(state, :secret_handle_revoked, handle)
        {:noreply, state}
    end
  end

  defp authorized_handle(nil, _worker_id, _resource), do: {:error, :unknown_secret_handle}

  defp authorized_handle(handle, worker_id, resource) do
    cond do
      handle.status != :active ->
        {:error, :secret_handle_revoked}

      handle.worker_id != worker_id ->
        {:error, :secret_handle_wrong_owner}

      handle.expires_monotonic_ms <= System.monotonic_time(:millisecond) ->
        {:error, :secret_handle_expired}

      not scope_match?(handle.scopes, resource) ->
        {:error, :secret_handle_scope_denied}

      true ->
        {:ok, handle}
    end
  end

  defp scope_match?(scopes, resource) when map_size(scopes) == 0, do: map_size(resource) == 0

  defp scope_match?(scopes, resource) do
    Enum.all?(resource, fn {key, value} ->
      allowed = Map.get(scopes, key, Map.get(scopes, to_string(key), []))
      allowed == :all or allowed == "all" or value in List.wrap(allowed)
    end)
  end

  defp safely_invoke(fun, secret) do
    fun.(secret)
  rescue
    error -> {:error, {:secret_provider_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:secret_provider_throw, kind, reason}}
  end

  defp public(handle) do
    %{
      id: handle.id,
      worker_id: handle.worker_id,
      kind: handle.kind,
      scopes: handle.scopes,
      expires_at: handle.expires_at,
      status: handle.status
    }
  end

  defp record(state, type, handle) do
    _ =
      EventLog.append(state.root_session_id, type, %{
        "handle_id" => handle.id,
        "worker_id" => handle.worker_id,
        "kind" => handle.kind,
        "expires_at" => DateTime.to_iso8601(handle.expires_at),
        "status" => to_string(handle.status)
      })

    :ok
  end

  defp normalize_duration(value) when is_integer(value) and value > 0,
    do: min(value, 3_600_000)

  defp normalize_duration(_value), do: 300_000

  defp call(goal_id, message) do
    with {:ok, pid} <- Names.pid(:goal_secret_broker, goal_id),
         do: GenServer.call(pid, message, 300_000)
  end
end
