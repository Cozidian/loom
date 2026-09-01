defmodule BeamAgent.Runtime do
  @moduledoc """
  Interface-neutral client API for a running goal.

  A connected client owns no conversation state. It attaches to the supervised
  runtime, receives replay plus live `BeamAgent.RuntimeEvent` values, and may be
  disconnected and recreated from its last durable cursor.

  Subscribers receive messages in this form:

      {:beam_agent_runtime, client, {:event, runtime_event}}
      {:beam_agent_runtime, client, {:approval_requested, request}}
      {:beam_agent_runtime, client, {:approval_resolved, approval_id, decision}}
      {:beam_agent_runtime, client, {:approvals_reconciled, pending_requests}}
      {:beam_agent_runtime, client, {:turn_started, prompt}}
      {:beam_agent_runtime, client, {:turn_finished, result}}
      {:beam_agent_runtime, client, :turn_cancelling}

  The public event view is the default. Trusted local interfaces must opt into
  `view: :internal` when they need model text or tool payloads.
  """

  alias BeamAgent.Runtime.Client

  def connect(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    opts =
      opts
      |> Keyword.put(:session_id, session_id)
      |> Keyword.put_new(:subscriber, self())

    Client.start(opts)
  end

  def disconnect(client) when is_pid(client) do
    if Process.alive?(client), do: GenServer.stop(client, :normal, 5_000)
    :ok
  catch
    :exit, _reason -> :ok
  end

  def bootstrap(client), do: Client.bootstrap(client)
  def snapshot(client), do: Client.snapshot(client)

  def submit(client, prompt, attachment_ids \\ []),
    do: Client.submit(client, prompt, attachment_ids)

  def import_attachment(client, attrs), do: Client.import_attachment(client, attrs)
  def attachments(client), do: Client.attachments(client)
  def draft_attachments(client), do: Client.draft_attachments(client)

  def delete_attachment(client, attachment_id),
    do: Client.delete_attachment(client, attachment_id)

  def cancel(client), do: Client.cancel(client)
  def steer(client, message), do: Client.steer(client, message)

  def respond_approval(client, approval_id, decision),
    do: Client.respond_approval(client, approval_id, decision)

  def approval_policy(client), do: Client.approval_policy(client)
  def set_approval_policy(client, policy), do: Client.set_approval_policy(client, policy)

  def reconnect(client, session_id, opts \\ []),
    do: Client.reconnect(client, session_id, opts)

  def status(client), do: Client.status(client)

  def inspect_events(client, query \\ "", opts \\ []),
    do: Client.inspect_events(client, query, opts)

  def goal_tree(client), do: Client.goal_tree(client)
  def work_blocks(client), do: Client.work_blocks(client)
  def progress(client), do: Client.progress(client)
  def budget(client), do: Client.budget(client)
  def repository(client), do: Client.repository(client)
  def project_context(client, request \\ %{}), do: Client.project_context(client, request)
  def resource_pools(client), do: Client.resource_pools(client)
  def path_leases(client), do: Client.path_leases(client)
  def delegations(client), do: Client.delegations(client)
  def organizations(client), do: Client.organizations(client)
  def capability_leases(client), do: Client.capability_leases(client)
  def worktrees(client), do: Client.worktrees(client)
  def diff_summary(client), do: Client.diff_summary(client)
  def diff(client, opts \\ []), do: Client.diff(client, opts)
  def sessions(client), do: Client.sessions(client)
  def session_detail(client, session_id), do: Client.session_detail(client, session_id)
  def project_preferences(client), do: Client.project_preferences(client)

  def set_project_preferences(client, preferences),
    do: Client.set_project_preferences(client, preferences)

  def verify(client, plan \\ :auto) do
    with {:ok, goal_id} <- Client.goal_id(client), do: BeamAgent.verify(goal_id, plan)
  end

  def cancel_verification(client) do
    with {:ok, goal_id} <- Client.goal_id(client), do: BeamAgent.cancel_verification(goal_id)
  end

  def models(client), do: Client.models(client)
  def refresh_models(client, endpoint_id \\ :all), do: Client.refresh_models(client, endpoint_id)
  def permissions(client), do: Client.permissions(client)

  def revoke_permission(client, permission_id),
    do: Client.revoke_permission(client, permission_id)

  def mcp_servers(client), do: Client.mcp_servers(client)
  def start_mcp_server(client, spec), do: Client.start_mcp_server(client, spec)
  def stop_mcp_server(client, name), do: Client.stop_mcp_server(client, name)
  def outcomes(client, opts \\ []), do: Client.outcomes(client, opts)
  def routing_evidence(client, opts \\ []), do: Client.routing_evidence(client, opts)

  def attach_verification(client, outcome_id, result),
    do: Client.attach_verification(client, outcome_id, result)

  def export_outcomes(client), do: Client.export_outcomes(client)

  def run(client, prompt, timeout, approval_fun, event_fun \\ fn _event -> :ok end)
      when is_pid(client) and is_function(approval_fun, 1) and is_function(event_fun, 1) do
    with :ok <- submit(client, prompt) do
      monitor = Process.monitor(client)
      deadline = deadline(timeout)
      meta = %{streamed_text?: false, live_tool_events?: false}

      try do
        await(client, monitor, deadline, approval_fun, event_fun, meta)
      after
        Process.demonitor(monitor, [:flush])
      end
    end
  end

  defp await(client, monitor, deadline, approval_fun, event_fun, meta) do
    receive do
      {:beam_agent_runtime, ^client, {:turn_finished, {:ok, answer}}} ->
        {:ok, answer, meta}

      {:beam_agent_runtime, ^client, {:turn_finished, {:error, reason}}} ->
        {:error, reason, meta}

      {:beam_agent_runtime, ^client, {:approval_requested, request}} ->
        decision = approval_decision(approval_fun, request)

        case respond_approval(client, request.approval_id, decision) do
          :ok -> await(client, monitor, deadline, approval_fun, event_fun, meta)
          {:error, reason} -> {:error, reason, meta}
        end

      {:beam_agent_runtime, ^client, {:event, event}} ->
        meta = render_runtime_event(event_fun, event, meta)
        await(client, monitor, deadline, approval_fun, event_fun, meta)

      {:beam_agent_runtime, ^client, _notification} ->
        await(client, monitor, deadline, approval_fun, event_fun, meta)

      {:DOWN, ^monitor, :process, ^client, reason} ->
        {:error, {:runtime_client_exit, reason}, meta}
    after
      remaining(deadline) ->
        _ = cancel(client)
        {:error, :turn_timeout, meta}
    end
  end

  defp render_runtime_event(event_fun, event, meta) do
    case line_event(event) do
      nil ->
        meta

      event ->
        safely_render(event_fun, event)
        update_meta(meta, event)
    end
  end

  defp line_event(%{
         durability: :ephemeral,
         scope: %{root?: true},
         payload: %{data: data}
       }),
       do: data

  defp line_event(%{
         durability: :durable,
         payload: %{type: type, data: data, seq: seq}
       }) do
    %{type: :durable_event, event: %{"type" => to_string(type), "data" => data, "seq" => seq}}
  end

  defp line_event(_event), do: nil

  defp approval_decision(approval_fun, request) do
    case approval_fun.(request) do
      :allow_once -> :allow_once
      :allow_always -> :allow_always
      _decision -> :deny
    end
  rescue
    _error -> :deny
  end

  defp safely_render(event_fun, event) do
    event_fun.(event)
    :ok
  rescue
    _error -> :ok
  end

  defp update_meta(meta, %{type: :text_delta, delta: delta}) when delta != "",
    do: %{meta | streamed_text?: true}

  defp update_meta(meta, %{type: :durable_event, event: %{"type" => type}})
       when type in ["tool_called", "tool_result"],
       do: %{meta | live_tool_events?: true}

  defp update_meta(meta, _event), do: meta

  defp deadline(:infinity), do: :infinity

  defp deadline(timeout) when is_integer(timeout) and timeout >= 0,
    do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
