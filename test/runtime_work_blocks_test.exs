defmodule BeamAgent.RuntimeWorkBlocksTest do
  use ExUnit.Case, async: true

  alias BeamAgent.RuntimeWorkBlocks

  test "assignment and routing metadata survive pre-turn events and public replay" do
    events = [
      event(1, "agent_spec_applied", %{"role" => "Research specialist"}),
      event(2, "worker_assignment", %{
        "worker_id" => "root",
        "role" => "Repository investigator",
        "parent_worker_id" => "owner",
        "selected_endpoint_id" => "local-helper",
        "policy_reason" => "Bounded free-cost assistance",
        "execution_node" => "local"
      }),
      event(3, "turn_started", %{"turn" => 1}),
      event(4, "model_route_selected", %{
        "selected_endpoint_id" => "local-helper",
        "policy_reason" => "eligible capability fit"
      }),
      event(5, "model_response_started", %{
        "provider_profile" => "local-helper",
        "provider" => "ollama",
        "model" => "small"
      }),
      event(6, "turn_finished", %{"reason" => "completed"}),
      event(7, "turn_started", %{"turn" => 2})
    ]

    public = Enum.map(events, &BeamAgent.RuntimeEventView.project(&1, :public))
    assert [first, second] = RuntimeWorkBlocks.project(public)
    assert first.role == "Repository investigator"
    assert first.owner_worker_id == "owner"
    assert first.assignment_reason == "Bounded free-cost assistance"
    assert first.routing_reason == "eligible capability fit"
    assert first.execution_node == "local"
    assert first.model == "small"
    assert second.role == first.role
    assert second.endpoint_id == first.endpoint_id
    assert second.state == :active
  end

  test "groups low-level activity into one semantic worker block" do
    events = [
      event(1, "goal_work_started", %{}),
      event(2, "turn_started", %{"turn" => 1}),
      event(3, "model_response_started", %{}),
      event(4, "tool_called", %{"name" => "read_file", "arguments" => %{"path" => "lib/a.ex"}}),
      event(5, "tool_result", %{"name" => "read_file"}),
      event(6, "tool_called", %{"name" => "apply_patch", "arguments" => %{"path" => "lib/a.ex"}}),
      event(7, "tool_result", %{"name" => "apply_patch"}),
      event(8, "verification_started", %{}),
      event(9, "verification_check_finished", %{"status" => "passed"}),
      event(10, "turn_finished", %{"reason" => "completed"})
    ]

    assert [block] = RuntimeWorkBlocks.project(events)
    assert block.worker_id == "root"
    assert block.state == :completed
    assert block.label == "Implemented changes"
    assert block.files == ["lib/a.ex"]
    assert block.counts.reads == 1
    assert block.counts.writes == 1
    assert block.counts.model_calls == 1
    assert block.counts.verification_checks == 1
    assert block.duration_ms == 9_000
    assert block.summary =~ "1 read"
    assert block.summary =~ "1 write"
  end

  test "keeps stalls and warnings prominent inside the block summary" do
    events = [
      event(1, "turn_started", %{"turn" => 1}),
      event(2, "worker_stall_suspected", %{"worker_id" => "root"}),
      event(3, "worker_progress_resumed", %{"worker_id" => "root"}),
      event(4, "tool_loop_stalled", %{}),
      event(5, "turn_finished", %{"reason" => "error"})
    ]

    assert [block] = RuntimeWorkBlocks.project(events)
    assert block.state == :failed
    assert block.counts.warnings == 2
    assert block.summary =~ "2 warnings"
  end

  test "waiting and blocked states remain interface-neutral projection data" do
    waiting = [
      event(1, "turn_started", %{"turn" => 1}),
      event(2, "tool_approval_requested", %{"tool" => "run_command"})
    ]

    assert [%{state: :waiting, phase: :awaiting_approval, blocking_reason: "run_command"}] =
             RuntimeWorkBlocks.project(waiting)

    blocked =
      waiting ++ [event(3, "tool_approval_granted", %{}), event(4, "budget_exhausted", %{})]

    assert [%{state: :blocked, phase: :blocked, blocking_reason: "budget"}] =
             RuntimeWorkBlocks.project(blocked)
  end

  defp event(seq, type, data) do
    %{
      durability: :durable,
      event_id: "root:#{seq}",
      goal_seq: seq,
      at: "2026-09-01T10:00:#{String.pad_leading(Integer.to_string(seq), 2, "0")}Z",
      scope: %{worker_id: "root"},
      payload: %{type: type, data: data}
    }
  end
end
