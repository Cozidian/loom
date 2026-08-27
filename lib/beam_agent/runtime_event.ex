defmodule BeamAgent.RuntimeEvent do
  @moduledoc """
  Versioned, interface-neutral envelope for observable runtime activity.

  Durable session events remain canonical. This envelope adds goal-tree scope
  and presentation metadata without rewriting the append-only session logs.
  """

  @version 1

  def durable(project_id, goal_id, session_id, event) when is_map(event) do
    type = event["type"] || event[:type] || "unknown"
    data = event["data"] || event[:data] || %{}
    seq = event["seq"] || event[:seq]

    envelope(
      project_id,
      goal_id,
      session_id,
      :durable,
      "#{session_id}:#{seq}",
      event["at"] || event[:at],
      type,
      data,
      seq,
      event["goal_seq"] || event[:goal_seq],
      event["correlation_id"] || event[:correlation_id],
      event["causation_id"] || event[:causation_id]
    )
  end

  def ephemeral(project_id, goal_id, session_id, event) when is_map(event) do
    type = event[:type] || event["type"] || :unknown
    event_id = "live-#{System.unique_integer([:positive, :monotonic])}"

    envelope(
      project_id,
      goal_id,
      session_id,
      :ephemeral,
      event_id,
      DateTime.utc_now() |> DateTime.to_iso8601(),
      type,
      event,
      nil,
      nil,
      value(event, :correlation_id),
      value(event, :causation_id)
    )
  end

  defp envelope(
         project_id,
         goal_id,
         session_id,
         durability,
         event_id,
         at,
         type,
         data,
         seq,
         goal_seq,
         explicit_correlation_id,
         causation_id
       ) do
    %{
      type: :runtime_event,
      version: @version,
      event_id: event_id,
      goal_seq: goal_seq,
      at: at,
      category: category(to_string(type)),
      durability: durability,
      correlation_id: explicit_correlation_id || correlation_id(session_id, data),
      causation_id: causation_id,
      scope: %{
        project_id: project_id,
        goal_id: goal_id,
        session_id: session_id,
        worker_id: session_id,
        root?: session_id == goal_id
      },
      payload: %{
        type: type,
        data: data,
        seq: seq
      }
    }
  end

  defp category(type)
       when type in [
              "session_started",
              "agent_started",
              "turn_started",
              "turn_finished",
              "subagent_spawned",
              "agent_construction_requested",
              "agent_constructed",
              "agent_spec_applied",
              "agent_construction_failed"
            ],
       do: :lifecycle

  defp category(type) when type in ["command_received", "command_failed", "user_message"],
    do: :command

  defp category(type) when type in ["tool_called", "tool_result", "tool_loop_stalled"],
    do: :tool

  defp category(type)
       when type in [
              "model_response_started",
              "model_response_checkpoint",
              "model_response_finished",
              "model_response_failed",
              "assistant_message",
              "text_delta",
              "tool_call_delta",
              "usage",
              "response_finished",
              "response_failed"
            ],
       do: :model

  defp category(type) when type in ["context_loaded", "context_compaction_started"],
    do: :context

  defp category(type)
       when type in [
              "context_compaction_completed",
              "context_compaction_failed",
              "workspace_bound",
              "goal_bound"
            ],
       do: :context

  defp category(type)
       when type in [
              "tool_approval_requested",
              "tool_approval_granted",
              "tool_approval_cancelled",
              "tool_denied",
              "approval_policy_changed",
              "permission_granted",
              "permission_revoked",
              "capability_denied"
            ],
       do: :policy

  defp category(type)
       when type in [
              "mcp_server_started",
              "mcp_server_restarted",
              "mcp_server_stopped",
              "mcp_server_failed",
              "mcp_server_unavailable",
              "mcp_call_cancelled"
            ],
       do: :resource

  defp category("model_route_selected"), do: :routing

  defp category(type)
       when type in [
              "model_outcome_recorded",
              "task_outcome_recorded",
              "verification_attached",
              "verification_started",
              "verification_check_started",
              "verification_check_finished",
              "verification_finished",
              "verification_cancelled"
            ],
       do: :outcome

  defp category(_type), do: :runtime

  defp correlation_id(session_id, data) do
    value(data, :response_id) ||
      value(data, :tool_call_id) ||
      value(data, :approval_id) ||
      turn_correlation(session_id, value(data, :turn)) ||
      session_id
  end

  defp turn_correlation(_session_id, nil), do: nil
  defp turn_correlation(session_id, turn), do: "#{session_id}:turn:#{turn}"

  defp value(map, key) when is_map(map), do: map[key] || map[to_string(key)]
end
