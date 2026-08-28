defmodule BeamAgent.Session.ToolPolicy do
  @moduledoc "Session-owned auto/ask/deny policy and cancellation-driven approval lifecycle."
  use GenServer

  alias BeamAgent.Names
  alias BeamAgent.Session.EventLog

  @type decision :: :allow | :allow_once | :allow_always | :deny

  def start_link(opts) do
    id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:tool_policy, id))
  end

  def authorize(session_id, tool, arguments, access, resource \\ %{}, timeout \\ :infinity) do
    with {:ok, pid} <- Names.pid(:tool_policy, session_id) do
      GenServer.call(pid, {:authorize, tool, arguments, access, resource}, timeout)
    end
  end

  def respond(session_id, approval_id, decision)
      when decision in [:allow_once, :allow_always, :deny] do
    with {:ok, pid} <- Names.pid(:tool_policy, session_id) do
      GenServer.call(pid, {:respond, approval_id, decision})
    end
  end

  def set_handler(session_id, handler) when is_pid(handler) do
    with {:ok, pid} <- Names.pid(:tool_policy, session_id) do
      GenServer.call(pid, {:set_handler, handler})
    end
  end

  def policy(session_id) do
    with {:ok, pid} <- Names.pid(:tool_policy, session_id) do
      GenServer.call(pid, :policy)
    end
  end

  def handler(session_id) do
    with {:ok, pid} <- Names.pid(:tool_policy, session_id) do
      GenServer.call(pid, :handler)
    end
  end

  def permissions(session_id) do
    with {:ok, pid} <- Names.pid(:tool_policy, session_id), do: GenServer.call(pid, :permissions)
  end

  def revoke(session_id, permission_id) do
    with {:ok, pid} <- Names.pid(:tool_policy, session_id),
         do: GenServer.call(pid, {:revoke, permission_id})
  end

  def set_policy(session_id, policy) when policy in [:auto, :allow, :ask, :deny] do
    with {:ok, pid} <- Names.pid(:tool_policy, session_id) do
      GenServer.call(pid, {:set_policy, normalize_policy(policy)})
    end
  end

  @impl true
  def init(opts) do
    handler = Keyword.get(opts, :approval_handler)
    monitor = if is_pid(handler), do: Process.monitor(handler)
    session_id = Keyword.fetch!(opts, :session_id)

    approval_policy =
      opts
      |> Keyword.get(:approval_policy, :ask)
      |> normalize_policy()
      |> then(&recovered_policy(session_id, &1))

    {:ok,
     %{
       session_id: session_id,
       handler: handler,
       handler_monitor: monitor,
       approval_policy: approval_policy,
       tool_permissions: Map.new(Keyword.get(opts, :tool_permissions, %{})),
       permissions: recovered_permissions(session_id),
       pending: %{}
     }}
  end

  @impl true
  def handle_call({:authorize, tool, arguments, access, resource}, from, state) do
    case effective_decision(state, tool, access, resource) do
      :allow ->
        {:reply, :ok, state}

      :deny ->
        record(state, :tool_denied, tool, arguments, %{"reason" => "policy"})
        {:reply, {:error, {:tool_denied, tool}}, state}

      :ask ->
        approval_id = approval_id()

        request = %{
          approval_id: approval_id,
          session_id: state.session_id,
          tool: tool,
          arguments: arguments,
          access: access,
          resource: resource
        }

        record(state, :tool_approval_requested, tool, arguments, %{
          "approval_id" => approval_id,
          "access" => to_string(access)
        })

        if is_pid(state.handler), do: send(state.handler, {:beam_agent_approval, request})
        {caller, _tag} = from

        pending =
          Map.put(state.pending, approval_id, %{
            from: from,
            caller_monitor: Process.monitor(caller),
            request: request
          })

        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_call({:respond, approval_id, decision}, _from, state) do
    case Map.pop(state.pending, approval_id) do
      {nil, _pending} ->
        {:reply, {:error, :unknown_approval}, state}

      {%{from: waiting, caller_monitor: caller_monitor, request: request}, pending} ->
        Process.demonitor(caller_monitor, [:flush])

        event =
          if decision in [:allow_once, :allow_always],
            do: :tool_approval_granted,
            else: :tool_denied

        {state, permission_id} = maybe_grant_permission(state, request, decision)

        record(state, event, request.tool, request.arguments, %{
          "approval_id" => approval_id,
          "reason" => approval_reason(decision),
          "permission_id" => permission_id
        })

        reply =
          if decision in [:allow_once, :allow_always],
            do: :ok,
            else: {:error, {:tool_denied, request.tool}}

        GenServer.reply(waiting, reply)
        {:reply, :ok, %{state | pending: pending}}
    end
  end

  def handle_call({:set_handler, handler}, _from, state) do
    if state.handler_monitor, do: Process.demonitor(state.handler_monitor, [:flush])

    Enum.each(state.pending, fn {_approval_id, pending} ->
      send(handler, {:beam_agent_approval, pending.request})
    end)

    {:reply, :ok, %{state | handler: handler, handler_monitor: Process.monitor(handler)}}
  end

  def handle_call(:policy, _from, state), do: {:reply, {:ok, state.approval_policy}, state}
  def handle_call(:handler, _from, state), do: {:reply, {:ok, state.handler}, state}

  def handle_call(:permissions, _from, state),
    do: {:reply, {:ok, state.permissions |> Map.values() |> Enum.sort_by(& &1["id"])}, state}

  def handle_call({:revoke, permission_id}, _from, state) do
    case Map.pop(state.permissions, permission_id) do
      {nil, _} ->
        {:reply, {:error, :unknown_permission}, state}

      {permission, permissions} ->
        case EventLog.append(state.session_id, :permission_revoked, %{
               "permission_id" => permission_id,
               "resource" => permission["resource"]
             }) do
          {:ok, _} -> {:reply, :ok, %{state | permissions: permissions}}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:set_policy, policy}, _from, state) do
    previous = state.approval_policy

    case record_policy_change(state, previous, policy) do
      :ok ->
        state = %{state | approval_policy: policy}
        state = if policy == :auto, do: approve_pending(state), else: state
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, {:approval_policy_change_failed, reason}}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, handler, _reason}, state)
      when monitor == state.handler_monitor and handler == state.handler do
    {:noreply, %{state | handler: nil, handler_monitor: nil}}
  end

  def handle_info({:DOWN, monitor, :process, _caller, _reason}, state) do
    case Enum.find(state.pending, fn {_id, pending} -> pending.caller_monitor == monitor end) do
      nil ->
        {:noreply, state}

      {approval_id, pending} ->
        record(
          state,
          :tool_approval_cancelled,
          pending.request.tool,
          pending.request.arguments,
          %{
            "approval_id" => approval_id,
            "reason" => "caller_exited"
          }
        )

        {:noreply, %{state | pending: Map.delete(state.pending, approval_id)}}
    end
  end

  defp effective_decision(state, tool, access, resource) do
    cond do
      Enum.any?(state.permissions, fn {_id, permission} ->
        permission["resource"] == stringify(resource)
      end) ->
        :allow

      true ->
        Map.get_lazy(state.tool_permissions, tool, fn ->
          default_decision(state.approval_policy, access)
        end)
    end
  end

  defp default_decision(_policy, access) when access in [:read, :trusted, :delegate], do: :allow
  defp default_decision(policy, _access) when policy in [:auto, :allow], do: :allow
  defp default_decision(:deny, _access), do: :deny
  defp default_decision(:ask, _access), do: :ask

  defp record(state, type, tool, arguments, extra) do
    data = Map.merge(%{"tool" => tool, "arguments" => arguments}, extra)
    _ = EventLog.append(state.session_id, type, data)
    :ok
  end

  defp approve_pending(state) do
    Enum.each(state.pending, fn {approval_id,
                                 %{
                                   from: waiting,
                                   caller_monitor: caller_monitor,
                                   request: request
                                 }} ->
      Process.demonitor(caller_monitor, [:flush])

      record(state, :tool_approval_granted, request.tool, request.arguments, %{
        "approval_id" => approval_id,
        "reason" => "auto_mode_enabled"
      })

      GenServer.reply(waiting, :ok)
    end)

    %{state | pending: %{}}
  end

  defp record_policy_change(_state, policy, policy), do: :ok

  defp record_policy_change(state, previous, policy) do
    case EventLog.append(state.session_id, :approval_policy_changed, %{
           "from" => to_string(previous),
           "to" => to_string(policy)
         }) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_policy(:allow), do: :auto
  defp normalize_policy(policy), do: policy

  defp recovered_policy(session_id, configured) do
    case EventLog.events(session_id) do
      {:ok, events} ->
        Enum.reduce(events, configured, fn
          %{"type" => "approval_policy_changed", "data" => %{"to" => policy}}, _current
          when policy in ["auto", "ask", "deny"] ->
            String.to_existing_atom(policy)

          _event, current ->
            current
        end)

      {:error, _reason} ->
        configured
    end
  end

  defp approval_id do
    "approval-" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
  end

  defp maybe_grant_permission(state, _request, decision) when decision != :allow_always,
    do: {state, nil}

  defp maybe_grant_permission(state, request, :allow_always) do
    permission_id =
      "permission-" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))

    permission = %{
      "id" => permission_id,
      "resource" => stringify(request.resource),
      "tool" => request.tool,
      "granted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:ok, _} = EventLog.append(state.session_id, :permission_granted, permission)
    {%{state | permissions: Map.put(state.permissions, permission_id, permission)}, permission_id}
  end

  defp approval_reason(:allow_once), do: "approved_once"
  defp approval_reason(:allow_always), do: "approved_always"
  defp approval_reason(:deny), do: "user_denied"

  defp recovered_permissions(session_id) do
    case EventLog.events(session_id) do
      {:ok, events} ->
        Enum.reduce(events, %{}, fn
          %{"type" => "permission_granted", "data" => %{"id" => id} = permission}, acc ->
            Map.put(acc, id, permission)

          %{"type" => "permission_revoked", "data" => %{"permission_id" => id}}, acc ->
            Map.delete(acc, id)

          _, acc ->
            acc
        end)

      _ ->
        %{}
    end
  end

  defp stringify(resource), do: Map.new(resource, fn {key, value} -> {to_string(key), value} end)
end
