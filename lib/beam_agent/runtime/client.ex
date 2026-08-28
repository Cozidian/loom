defmodule BeamAgent.Runtime.Client do
  @moduledoc false
  use GenServer

  alias BeamAgent.Agent

  def start(opts), do: GenServer.start(__MODULE__, opts)
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def bootstrap(client), do: GenServer.call(client, :bootstrap)
  def snapshot(client), do: GenServer.call(client, :snapshot)
  def submit(client, prompt), do: GenServer.call(client, {:submit, prompt})
  def cancel(client), do: GenServer.call(client, :cancel)

  def respond_approval(client, approval_id, decision),
    do: GenServer.call(client, {:respond_approval, approval_id, decision})

  def approval_policy(client), do: GenServer.call(client, :approval_policy)

  def set_approval_policy(client, policy),
    do: GenServer.call(client, {:set_approval_policy, policy})

  def reconnect(client, session_id, opts),
    do: GenServer.call(client, {:reconnect, session_id, opts})

  def status(client), do: GenServer.call(client, :status)

  def inspect_events(client, query, opts),
    do: GenServer.call(client, {:inspect_events, query, opts})

  def goal_tree(client), do: GenServer.call(client, :goal_tree)
  def budget(client), do: GenServer.call(client, :budget)
  def repository(client), do: GenServer.call(client, :repository)
  def project_context(client, request), do: GenServer.call(client, {:project_context, request})
  def resource_pools(client), do: GenServer.call(client, :resource_pools)
  def delegations(client), do: GenServer.call(client, :delegations)
  def organizations(client), do: GenServer.call(client, :organizations)
  def capability_leases(client), do: GenServer.call(client, :capability_leases)
  def worktrees(client), do: GenServer.call(client, :worktrees)
  def diff_summary(client), do: GenServer.call(client, :diff_summary)
  def diff(client, opts \\ []), do: GenServer.call(client, {:diff, opts})
  def sessions(client), do: GenServer.call(client, :sessions)

  def session_detail(client, session_id),
    do: GenServer.call(client, {:session_detail, session_id})

  def project_preferences(client), do: GenServer.call(client, :project_preferences)

  def set_project_preferences(client, preferences),
    do: GenServer.call(client, {:set_project_preferences, preferences})

  def goal_id(client), do: GenServer.call(client, :goal_id)

  def models(client), do: GenServer.call(client, :models)

  def refresh_models(client, endpoint_id),
    do: GenServer.call(client, {:refresh_models, endpoint_id})

  def permissions(client), do: GenServer.call(client, :permissions)

  def revoke_permission(client, permission_id),
    do: GenServer.call(client, {:revoke_permission, permission_id})

  def mcp_servers(client), do: GenServer.call(client, :mcp_servers)

  def start_mcp_server(client, spec),
    do: GenServer.call(client, {:start_mcp_server, spec}, 31_000)

  def stop_mcp_server(client, name), do: GenServer.call(client, {:stop_mcp_server, name})
  def outcomes(client, opts), do: GenServer.call(client, {:outcomes, opts})
  def routing_evidence(client, opts), do: GenServer.call(client, {:routing_evidence, opts})

  def attach_verification(client, outcome_id, result),
    do: GenServer.call(client, {:attach_verification, outcome_id, result})

  def export_outcomes(client), do: GenServer.call(client, :export_outcomes)

  @impl true
  def init(opts) do
    subscriber = Keyword.fetch!(opts, :subscriber)

    state = %{
      subscriber: subscriber,
      subscriber_monitor: Process.monitor(subscriber),
      session_id: nil,
      project_id: nil,
      goal_id: nil,
      workspace_root: nil,
      data_dir: nil,
      view: Keyword.get(opts, :view, :public),
      cursor: 0,
      bootstrap_events: [],
      approval_policy: :ask,
      agent_status: :idle,
      previous_approval_handler: nil,
      pending_approvals: %{},
      current: nil
    }

    case bind(state, Keyword.fetch!(opts, :session_id), opts) do
      {:ok, state, _snapshot} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:bootstrap, _from, state) do
    state = refresh_agent_status(state)
    snapshot = Map.put(connection_snapshot(state), :events, state.bootstrap_events)
    {:reply, {:ok, snapshot}, %{state | bootstrap_events: []}}
  end

  def handle_call(:snapshot, _from, state) do
    state = refresh_agent_status(state)
    {:reply, {:ok, connection_snapshot(state)}, state}
  end

  def handle_call({:submit, prompt}, _from, %{current: nil} = state)
      when is_binary(prompt) and prompt != "" do
    case Agent.status(state.session_id) do
      {:ok, :idle} ->
        start_turn(state, prompt)

      {:ok, _running} ->
        {:reply, {:error, :turn_running}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:submit, ""}, _from, state), do: {:reply, {:error, :empty_prompt}, state}

  def handle_call({:submit, _prompt}, _from, %{current: nil} = state),
    do: {:reply, {:error, :invalid_prompt}, state}

  def handle_call({:submit, _prompt}, _from, state),
    do: {:reply, {:error, :turn_running}, state}

  def handle_call(:cancel, _from, state) do
    with {:ok, status} when status != :idle <- Agent.status(state.session_id),
         :ok <- BeamAgent.cancel(state.session_id) do
      notify(state, :turn_cancelling)
      {:reply, :ok, %{state | agent_status: :cancelling}}
    else
      {:ok, :idle} -> {:reply, {:error, :not_running}, %{state | agent_status: :idle}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:respond_approval, approval_id, decision}, _from, state)
      when decision in [:allow_once, :allow_always, :deny] do
    session_id = Map.get(state.pending_approvals, approval_id, state.session_id)

    case BeamAgent.respond_approval(session_id, approval_id, decision) do
      :ok ->
        notify(state, {:approval_resolved, approval_id, decision})

        {:reply, :ok,
         %{state | pending_approvals: Map.delete(state.pending_approvals, approval_id)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:respond_approval, _approval_id, _decision}, _from, state),
    do: {:reply, {:error, :invalid_approval_decision}, state}

  def handle_call(:approval_policy, _from, state),
    do: {:reply, {:ok, state.approval_policy}, state}

  def handle_call({:set_approval_policy, policy}, _from, state) do
    case BeamAgent.set_approval_policy(state.session_id, policy) do
      :ok ->
        {:ok, policy} = BeamAgent.approval_policy(state.session_id)
        notify(state, {:approval_policy_changed, policy})
        {:reply, :ok, %{state | approval_policy: policy}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reconnect, _session_id, _opts}, _from, %{current: current} = state)
      when not is_nil(current),
      do: {:reply, {:error, :turn_running}, state}

  def handle_call({:reconnect, session_id, opts}, _from, state)
      when is_binary(session_id) and is_list(opts) do
    opts = Keyword.put_new(opts, :view, state.view)

    case bind(state, session_id, opts) do
      {:ok, state, snapshot} ->
        {:reply, {:ok, snapshot}, %{state | bootstrap_events: []}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state) do
    result =
      with {:ok, path} <- BeamAgent.event_log_path(state.session_id),
           {:ok, context} <- BeamAgent.context_snapshot(state.session_id),
           {:ok, context_stats} <- BeamAgent.conversation_context_stats(state.session_id),
           {:ok, events} <- BeamAgent.goal_events(state.goal_id),
           {:ok, agent_status} <- Agent.status(state.session_id) do
        current_state = %{state | agent_status: agent_status}

        {:ok,
         connection_snapshot(current_state)
         |> Map.merge(%{
           event_log_path: path,
           context: context,
           context_stats: context_stats,
           event_count: length(events),
           agent_status: agent_status
         })}
      end

    {:reply, result, state}
  end

  def handle_call({:inspect_events, query, opts}, _from, state)
      when is_binary(query) and is_list(opts) do
    {:reply, BeamAgent.inspect_goal_events(state.goal_id, query, opts), state}
  end

  def handle_call(:goal_tree, _from, state) do
    {:reply, BeamAgent.goal_tree(state.goal_id), state}
  end

  def handle_call(:budget, _from, state), do: {:reply, BeamAgent.budget(state.goal_id), state}

  def handle_call(:repository, _from, state),
    do: {:reply, BeamAgent.repository(state.project_id), state}

  def handle_call({:project_context, request}, _from, state),
    do: {:reply, BeamAgent.project_context(state.project_id, request), state}

  def handle_call(:resource_pools, _from, state),
    do: {:reply, BeamAgent.resource_pools(state.project_id), state}

  def handle_call(:delegations, _from, state),
    do: {:reply, BeamAgent.worker_delegations(state.goal_id), state}

  def handle_call(:organizations, _from, state),
    do: {:reply, BeamAgent.worker_organizations(state.goal_id), state}

  def handle_call(:capability_leases, _from, state),
    do: {:reply, BeamAgent.capability_leases(state.goal_id), state}

  def handle_call(:worktrees, _from, state),
    do: {:reply, BeamAgent.worktrees(state.project_id), state}

  def handle_call(:diff_summary, _from, state),
    do: {:reply, BeamAgent.diff_summary(state.workspace_root), state}

  def handle_call({:diff, opts}, _from, state),
    do: {:reply, BeamAgent.diff(state.workspace_root, opts), state}

  def handle_call(:sessions, _from, state),
    do: {:reply, BeamAgent.sessions(state.data_dir), state}

  def handle_call({:session_detail, session_id}, _from, state),
    do: {:reply, BeamAgent.session_detail(state.data_dir, session_id), state}

  def handle_call(:project_preferences, _from, state),
    do: {:reply, BeamAgent.project_preferences(state.project_id), state}

  def handle_call({:set_project_preferences, preferences}, _from, state),
    do: {:reply, BeamAgent.set_project_preferences(state.project_id, preferences), state}

  def handle_call(:goal_id, _from, state), do: {:reply, {:ok, state.goal_id}, state}

  def handle_call(:models, _from, state),
    do: {:reply, BeamAgent.models(state.project_id), state}

  def handle_call({:refresh_models, endpoint_id}, _from, state),
    do: {:reply, BeamAgent.refresh_models(state.project_id, endpoint_id), state}

  def handle_call(:permissions, _from, state),
    do: {:reply, BeamAgent.permissions(state.session_id), state}

  def handle_call({:revoke_permission, id}, _from, state),
    do: {:reply, BeamAgent.revoke_permission(state.session_id, id), state}

  def handle_call(:mcp_servers, _from, state),
    do: {:reply, BeamAgent.mcp_servers(state.goal_id), state}

  def handle_call({:start_mcp_server, spec}, _from, state),
    do: {:reply, BeamAgent.start_mcp_server(state.goal_id, spec), state}

  def handle_call({:stop_mcp_server, name}, _from, state),
    do: {:reply, BeamAgent.stop_mcp_server(state.goal_id, name), state}

  def handle_call({:outcomes, opts}, _from, state),
    do: {:reply, BeamAgent.outcomes(state.project_id, opts), state}

  def handle_call({:routing_evidence, opts}, _from, state),
    do: {:reply, BeamAgent.routing_evidence(state.project_id, opts), state}

  def handle_call({:attach_verification, id, result}, _from, state),
    do: {:reply, BeamAgent.attach_verification(state.project_id, id, result), state}

  def handle_call(:export_outcomes, _from, state),
    do: {:reply, BeamAgent.export_outcomes(state.project_id), state}

  @impl true
  def handle_info({:beam_agent_runtime_event, event}, state) do
    cursor =
      case event do
        %{durability: :durable, goal_seq: goal_seq} when is_integer(goal_seq) ->
          max(state.cursor, goal_seq)

        _event ->
          state.cursor
      end

    notify(state, {:event, event})

    {:noreply,
     %{state | cursor: cursor, agent_status: event_agent_status(event, state.agent_status)}}
  end

  def handle_info({:beam_agent_approval, request}, state) do
    pending = Map.put(state.pending_approvals, request.approval_id, request.session_id)
    notify(state, {:approval_requested, request})
    {:noreply, %{state | pending_approvals: pending}}
  end

  def handle_info({result_ref, result}, %{current: %{result_ref: result_ref} = current} = state) do
    Process.demonitor(current.monitor, [:flush])
    _ = BeamAgent.sync_stream(state.session_id)
    _ = BeamAgent.sync_goal(state.goal_id)
    send(self(), {:deliver_turn_result, result_ref, result})
    {:noreply, state}
  end

  def handle_info(
        {:deliver_turn_result, result_ref, result},
        %{current: %{result_ref: result_ref}} = state
      ) do
    notify(state, {:turn_finished, result})
    {:noreply, %{state | current: nil, agent_status: :idle}}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{current: %{monitor: monitor}} = state
      ) do
    notify(state, {:turn_finished, {:error, {:turn_task_exit, reason}}})
    {:noreply, %{state | current: nil, agent_status: :idle}}
  end

  def handle_info(
        {:DOWN, monitor, :process, subscriber, _reason},
        %{subscriber_monitor: monitor, subscriber: subscriber} = state
      ),
      do: {:stop, :normal, state}

  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({_result_ref, _result}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    restore_approval_handler(state)
    if state.goal_id, do: BeamAgent.unsubscribe_goal(state.goal_id, self())
    :ok
  end

  defp bind(state, session_id, opts) do
    view = Keyword.get(opts, :view, state.view)
    after_cursor = Keyword.get(opts, :after)

    with :ok <- validate_view(view),
         :ok <- validate_after(after_cursor),
         {:ok, identity} <- Agent.runtime_identity(session_id),
         {:ok, subscription} <-
           BeamAgent.subscribe_goal_from(identity.goal_id, after_value(after_cursor), view: view),
         {:ok, observed_handler} <- BeamAgent.approval_handler(session_id),
         :ok <- BeamAgent.set_approval_handler(session_id, self()),
         {:ok, approval_policy} <- BeamAgent.approval_policy(session_id),
         {:ok, agent_status} <- Agent.status(session_id) do
      previous_handler =
        if state.session_id == session_id and observed_handler == self(),
          do: state.previous_approval_handler,
          else: observed_handler

      if state.goal_id && state.goal_id != identity.goal_id do
        restore_approval_handler(state)
        _ = BeamAgent.unsubscribe_goal(state.goal_id, self())
      end

      events = if after_cursor == :latest, do: [], else: subscription.events

      state = %{
        state
        | session_id: session_id,
          project_id: identity.project_id,
          goal_id: identity.goal_id,
          workspace_root: identity.workspace_root,
          data_dir: identity.data_dir,
          view: view,
          cursor: subscription.cursor,
          bootstrap_events: events,
          approval_policy: approval_policy,
          agent_status: agent_status,
          previous_approval_handler: previous_handler,
          pending_approvals: %{}
      }

      {:ok, state, Map.put(connection_snapshot(state), :events, events)}
    end
  end

  defp connection_snapshot(state) do
    %{
      session_id: state.session_id,
      project_id: state.project_id,
      goal_id: state.goal_id,
      workspace_root: state.workspace_root,
      data_dir: state.data_dir,
      view: state.view,
      cursor: state.cursor,
      approval_policy: state.approval_policy,
      running?: state.agent_status != :idle
    }
  end

  defp notify(state, message) do
    send(state.subscriber, {:beam_agent_runtime, self(), message})
    :ok
  end

  defp validate_view(view) when view in [:public, :internal], do: :ok
  defp validate_view(_view), do: {:error, :invalid_event_view}

  defp validate_after(after_cursor)
       when is_nil(after_cursor) or after_cursor == :latest or
              (is_integer(after_cursor) and after_cursor >= 0),
       do: :ok

  defp validate_after(_after_cursor), do: {:error, :invalid_cursor}

  defp after_value(:latest), do: nil
  defp after_value(after_cursor), do: after_cursor

  defp start_turn(state, prompt) do
    owner = self()
    result_ref = make_ref()

    case Task.start(fn -> send(owner, {result_ref, BeamAgent.ask(state.session_id, prompt)}) end) do
      {:ok, pid} ->
        current = %{pid: pid, monitor: Process.monitor(pid), result_ref: result_ref}
        notify(state, {:turn_started, prompt})
        {:reply, :ok, %{state | current: current, agent_status: :running}}

      {:error, reason} ->
        {:reply, {:error, {:turn_start_failed, reason}}, state}
    end
  end

  defp event_agent_status(
         %{scope: %{root?: true}, payload: %{type: type}},
         _current
       )
       when type in ["turn_started", :turn_started],
       do: :running

  defp event_agent_status(
         %{scope: %{root?: true}, payload: %{type: type}},
         _current
       )
       when type in [
              "turn_finished",
              :turn_finished,
              "turn_cancelled",
              :turn_cancelled,
              "turn_worker_failed",
              :turn_worker_failed,
              "command_failed",
              :command_failed
            ],
       do: :idle

  defp event_agent_status(_event, current), do: current

  defp refresh_agent_status(state) do
    case Agent.status(state.session_id) do
      {:ok, status} -> %{state | agent_status: status}
      {:error, _reason} -> state
    end
  end

  defp restore_approval_handler(%{session_id: nil}), do: :ok

  defp restore_approval_handler(state) do
    case BeamAgent.approval_handler(state.session_id) do
      {:ok, current} when current == self() and is_pid(state.previous_approval_handler) ->
        if Process.alive?(state.previous_approval_handler) do
          BeamAgent.set_approval_handler(state.session_id, state.previous_approval_handler)
        else
          :ok
        end

      _other ->
        :ok
    end
  end
end
