defmodule BeamAgent.Runtime.Client do
  @moduledoc false
  use GenServer

  alias BeamAgent.Agent
  alias BeamAgent.Session.AttachmentStore

  def start(opts), do: GenServer.start(__MODULE__, opts)
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def bootstrap(client), do: GenServer.call(client, :bootstrap)
  def snapshot(client), do: GenServer.call(client, :snapshot)

  def configure_provider(client, settings, endpoints, removed_ids),
    do: GenServer.call(client, {:configure_provider, settings, endpoints, removed_ids})

  def submit(client, prompt, attachment_ids \\ []),
    do: GenServer.call(client, {:submit, prompt, attachment_ids})

  def import_attachment(client, attrs),
    do: GenServer.call(client, {:import_attachment, attrs}, 30_000)

  def attachments(client), do: GenServer.call(client, :attachments)
  def draft_attachments(client), do: GenServer.call(client, :draft_attachments)

  def delete_attachment(client, attachment_id),
    do: GenServer.call(client, {:delete_attachment, attachment_id})

  def cancel(client), do: GenServer.call(client, :cancel)
  def steer(client, message), do: GenServer.call(client, {:steer, message})

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
  def work_blocks(client), do: GenServer.call(client, :work_blocks)
  def progress(client), do: GenServer.call(client, :progress)
  def budget(client), do: GenServer.call(client, :budget)
  def repository(client), do: GenServer.call(client, :repository)
  def project_context(client, request), do: GenServer.call(client, {:project_context, request})
  def resource_pools(client), do: GenServer.call(client, :resource_pools)
  def path_leases(client), do: GenServer.call(client, :path_leases)
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

  def model_catalog(client), do: GenServer.call(client, :model_catalog)
  def refresh_model_catalog(client), do: GenServer.call(client, :refresh_model_catalog)

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
      previous_approval_handlers: %{},
      pending_approvals: %{},
      current: nil
    }

    case bind(state, Keyword.fetch!(opts, :session_id), opts) do
      {:ok, state, _snapshot} ->
        schedule_approval_reconciliation()
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:bootstrap, _from, state) do
    state = state |> refresh_agent_status() |> reconcile_approvals()
    snapshot = Map.put(connection_snapshot(state), :events, state.bootstrap_events)
    {:reply, {:ok, snapshot}, %{state | bootstrap_events: []}}
  end

  def handle_call(:snapshot, _from, state) do
    state = state |> refresh_agent_status() |> reconcile_approvals()
    {:reply, {:ok, connection_snapshot(state)}, state}
  end

  def handle_call({:submit, prompt, attachment_ids}, _from, %{current: nil} = state)
      when is_binary(prompt) and is_list(attachment_ids) do
    prompt = String.trim(prompt)

    if prompt == "" and attachment_ids == [] do
      {:reply, {:error, :empty_message}, state}
    else
      case Agent.status(state.session_id) do
        {:ok, :idle} ->
          start_turn(state, prompt, attachment_ids)

        {:ok, _running} ->
          {:reply, {:error, :turn_running}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:submit, _prompt, _attachment_ids}, _from, %{current: nil} = state),
    do: {:reply, {:error, :invalid_message}, state}

  def handle_call({:submit, _prompt, _attachment_ids}, _from, state),
    do: {:reply, {:error, :turn_running}, state}

  def handle_call({:import_attachment, attrs}, _from, state) when is_map(attrs),
    do: {:reply, AttachmentStore.import(state.session_id, attrs), state}

  def handle_call(:attachments, _from, state),
    do: {:reply, AttachmentStore.list(state.session_id), state}

  def handle_call(:draft_attachments, _from, state),
    do: {:reply, AttachmentStore.drafts(state.session_id), state}

  def handle_call({:delete_attachment, attachment_id}, _from, state)
      when is_binary(attachment_id),
      do: {:reply, AttachmentStore.delete(state.session_id, attachment_id), state}

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

  def handle_call({:steer, message}, _from, state) when is_binary(message) do
    case BeamAgent.steer(state.goal_id, message) do
      :ok ->
        notify(state, {:turn_steered, message})
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:respond_approval, approval_id, decision}, _from, state)
      when decision in [:allow_once, :allow_always, :deny] do
    state = reconcile_approvals(state, notify_new: true)

    case Map.fetch(state.pending_approvals, approval_id) do
      {:ok, %{session_id: session_id}} ->
        case BeamAgent.respond_approval(session_id, approval_id, decision) do
          :ok ->
            notify(state, {:approval_resolved, approval_id, decision})

            state =
              state
              |> Map.update!(:pending_approvals, &Map.delete(&1, approval_id))
              |> reconcile_approvals(notify_new: true)

            notify_approval_snapshot(state)
            {:reply, :ok, state}

          {:error, reason} ->
            state = reconcile_approvals(state, notify_new: true)
            notify_approval_snapshot(state)
            {:reply, {:error, reason}, state}
        end

      :error ->
        notify_approval_snapshot(state)
        {:reply, {:error, :unknown_approval}, state}
    end
  end

  def handle_call({:respond_approval, _approval_id, _decision}, _from, state),
    do: {:reply, {:error, :invalid_approval_decision}, state}

  def handle_call(:approval_policy, _from, state),
    do: {:reply, {:ok, state.approval_policy}, state}

  def handle_call(
        {:configure_provider, settings, endpoints, removed_ids},
        _from,
        %{current: nil} = state
      ) do
    {:reply, BeamAgent.Goal.configure_provider(state.goal_id, settings, endpoints, removed_ids),
     state}
  end

  def handle_call({:configure_provider, _, _, _}, _from, state),
    do: {:reply, {:error, :goal_busy}, state}

  def handle_call({:set_approval_policy, policy}, _from, state) do
    case BeamAgent.set_goal_approval_policy(state.goal_id, policy) do
      :ok ->
        {:ok, policy} = BeamAgent.approval_policy(state.session_id)
        notify(state, {:approval_policy_changed, policy})

        state =
          state
          |> Map.put(:approval_policy, policy)
          |> reconcile_approvals(notify_new: policy != :auto)

        notify_approval_snapshot(state)
        {:reply, :ok, state}

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

  def handle_call(:work_blocks, _from, state),
    do: {:reply, BeamAgent.work_blocks(state.goal_id), state}

  def handle_call(:progress, _from, state),
    do: {:reply, BeamAgent.progress(state.goal_id), state}

  def handle_call(:budget, _from, state), do: {:reply, BeamAgent.budget(state.goal_id), state}

  def handle_call(:repository, _from, state),
    do: {:reply, BeamAgent.repository(state.project_id), state}

  def handle_call({:project_context, request}, _from, state),
    do: {:reply, BeamAgent.project_context(state.project_id, request), state}

  def handle_call(:resource_pools, _from, state),
    do: {:reply, BeamAgent.resource_pools(state.project_id), state}

  def handle_call(:path_leases, _from, state),
    do: {:reply, BeamAgent.path_leases(state.project_id), state}

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

  def handle_call(:model_catalog, _from, state),
    do: {:reply, BeamAgent.ModelRegistry.catalog(state.project_id), state}

  def handle_call(:refresh_model_catalog, _from, state),
    do: {:reply, BeamAgent.ModelRegistry.refresh_catalog(state.project_id), state}

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

    state =
      if worker_lifecycle_event?(event) do
        state = reconcile_approvals(state, notify_new: true)
        notify_approval_snapshot(state)
        state
      else
        state
      end

    {:noreply,
     %{state | cursor: cursor, agent_status: event_agent_status(event, state.agent_status)}}
  end

  def handle_info({:beam_agent_approval, request}, state) do
    existing? = Map.has_key?(state.pending_approvals, request.approval_id)
    pending = Map.put(state.pending_approvals, request.approval_id, request)
    unless existing?, do: notify(state, {:approval_requested, request})
    {:noreply, %{state | pending_approvals: pending}}
  end

  def handle_info(:reconcile_approvals, state) do
    previous = state.pending_approvals
    state = reconcile_approvals(state, notify_new: true)

    if state.pending_approvals != previous do
      notify_approval_snapshot(state)
    end

    schedule_approval_reconciliation()
    {:noreply, state}
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
    restore_approval_handlers(state)
    if state.goal_id, do: BeamAgent.unsubscribe_goal(state.goal_id, self())
    :ok
  end

  defp bind(state, session_id, opts) do
    view = Keyword.get(opts, :view, state.view)
    after_cursor = Keyword.get(opts, :after)

    restore_approval_handlers(state)

    with :ok <- validate_view(view),
         :ok <- validate_after(after_cursor),
         {:ok, identity} <- Agent.runtime_identity(session_id),
         {:ok, subscription} <-
           BeamAgent.subscribe_goal_from(identity.goal_id, after_value(after_cursor), view: view),
         {:ok, session_ids} <- BeamAgent.goal_sessions(identity.goal_id),
         {:ok, previous_handlers, pending_approvals} <-
           attach_approval_handlers(session_ids, self()),
         {:ok, approval_policy} <- BeamAgent.approval_policy(session_id),
         {:ok, agent_status} <- Agent.status(session_id) do
      if state.goal_id && state.goal_id != identity.goal_id do
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
          previous_approval_handlers: previous_handlers,
          pending_approvals: pending_approvals
      }

      {:ok, state, Map.put(connection_snapshot(state), :events, events)}
    end
  end

  defp connection_snapshot(state) do
    goal_status = goal_status(state.goal_id)

    %{
      session_id: state.session_id,
      project_id: state.project_id,
      goal_id: state.goal_id,
      workspace_root: state.workspace_root,
      data_dir: state.data_dir,
      view: state.view,
      cursor: state.cursor,
      approval_policy: state.approval_policy,
      attachments: list_draft_attachments(state.session_id),
      pending_approvals:
        state.pending_approvals |> Map.values() |> Enum.sort_by(& &1.approval_id),
      goal_phase: goal_status.phase,
      work_contract: contract_summary(goal_status.current_contract),
      last_work: last_work_summary(goal_status.last_work),
      running?:
        goal_status.phase in [:executing, :verifying, :repairing, :reviewing, :cancelling] or
          state.agent_status != :idle
    }
  end

  defp goal_status(goal_id) when is_binary(goal_id) do
    case BeamAgent.Goal.status(goal_id) do
      {:ok, status} -> status
      {:error, _reason} -> %{phase: :unknown, current_contract: nil, last_work: nil}
    end
  end

  defp goal_status(_goal_id),
    do: %{phase: :unknown, current_contract: nil, last_work: nil}

  defp contract_summary(nil), do: nil

  defp contract_summary(contract) do
    Map.take(contract, [:id, :kind, :worker_kind, :expected_artifact, :verification_required])
  end

  defp last_work_summary(nil), do: nil

  defp last_work_summary(work) do
    %{
      status: work.status,
      contract: contract_summary(work.contract),
      artifact: work.artifact,
      finished_at: DateTime.to_iso8601(work.finished_at)
    }
  end

  defp list_draft_attachments(session_id) do
    case AttachmentStore.drafts(session_id) do
      {:ok, attachments} -> attachments
      {:error, _reason} -> []
    end
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

  defp start_turn(state, prompt, attachment_ids) do
    owner = self()
    result_ref = make_ref()

    case Task.start(fn ->
           send(owner, {result_ref, BeamAgent.ask(state.session_id, prompt, attachment_ids)})
         end) do
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

  defp reconcile_approvals(state, opts \\ [])

  defp reconcile_approvals(%{goal_id: nil} = state, _opts), do: state

  defp reconcile_approvals(state, opts) do
    notify_new? = Keyword.get(opts, :notify_new, false)
    {:ok, session_ids} = Agent.goal_sessions(state.goal_id)

    {handlers, approvals} =
      Enum.reduce(session_ids, {state.previous_approval_handlers, %{}}, fn
        session_id, {handlers, approvals} ->
          with {:ok, current_handler} <- BeamAgent.approval_handler(session_id),
               {:ok, pending} <- BeamAgent.pending_approvals(session_id) do
            handlers = remember_previous_handler(handlers, session_id, current_handler)

            if current_handler != self() do
              _ = BeamAgent.set_approval_handler(session_id, self())
            end

            approvals =
              Enum.reduce(pending, approvals, fn request, acc ->
                Map.put(acc, request.approval_id, request)
              end)

            {handlers, approvals}
          else
            {:error, :not_found} -> {handlers, approvals}
            {:error, _reason} -> {handlers, approvals}
          end
      end)

    if notify_new? do
      approvals
      |> Map.drop(Map.keys(state.pending_approvals))
      |> Map.values()
      |> Enum.sort_by(& &1.approval_id)
      |> Enum.each(&notify(state, {:approval_requested, &1}))
    end

    %{
      state
      | previous_approval_handlers: handlers,
        pending_approvals: approvals
    }
  end

  defp remember_previous_handler(handlers, session_id, handler)
       when is_pid(handler) and handler != self() do
    Map.put_new(handlers, session_id, handler)
  end

  defp remember_previous_handler(handlers, _session_id, _handler), do: handlers

  defp notify_approval_snapshot(state) do
    approvals =
      state.pending_approvals
      |> Map.values()
      |> Enum.sort_by(& &1.approval_id)

    notify(state, {:approvals_reconciled, approvals})
  end

  defp schedule_approval_reconciliation do
    Process.send_after(self(), :reconcile_approvals, 1_000)
    :ok
  end

  defp worker_lifecycle_event?(%{payload: %{type: type}})
       when type in [
              "agent_constructed",
              :agent_constructed,
              "agent_ready",
              :agent_ready,
              "agent_started",
              :agent_started,
              "subagent_spawned",
              :subagent_spawned,
              "tool_approval_orphaned",
              :tool_approval_orphaned
            ],
       do: true

  defp worker_lifecycle_event?(_event), do: false

  defp attach_approval_handlers(session_ids, handler) do
    Enum.reduce_while(session_ids, {:ok, %{}, %{}}, fn session_id, {:ok, handlers, approvals} ->
      with {:ok, previous} <- BeamAgent.approval_handler(session_id),
           {:ok, pending} <- BeamAgent.pending_approvals(session_id),
           :ok <- BeamAgent.set_approval_handler(session_id, handler) do
        handlers =
          if is_pid(previous), do: Map.put(handlers, session_id, previous), else: handlers

        approvals =
          Enum.reduce(pending, approvals, fn request, acc ->
            Map.put(acc, request.approval_id, request)
          end)

        {:cont, {:ok, handlers, approvals}}
      else
        {:error, :not_found} -> {:cont, {:ok, handlers, approvals}}
        {:error, reason} -> {:halt, {:error, {session_id, reason}}}
      end
    end)
  end

  defp restore_approval_handlers(%{
         previous_approval_handlers: handlers,
         goal_id: goal_id,
         session_id: root_session_id
       }) do
    fallback =
      case Map.get(handlers, root_session_id) do
        handler when is_pid(handler) ->
          handler

        _other ->
          handlers
          |> Map.values()
          |> Enum.find(&(is_pid(&1) and Process.alive?(&1)))
      end

    session_ids =
      case goal_id && Agent.goal_sessions(goal_id) do
        {:ok, sessions} -> Enum.uniq(Map.keys(handlers) ++ sessions)
        _other -> Map.keys(handlers)
      end

    Enum.each(session_ids, fn session_id ->
      previous = Map.get(handlers, session_id, fallback)

      with true <- is_pid(previous) and Process.alive?(previous),
           {:ok, current} <- BeamAgent.approval_handler(session_id),
           true <- current == self() do
        _ = BeamAgent.set_approval_handler(session_id, previous)
      else
        _other -> :ok
      end
    end)

    :ok
  end
end
