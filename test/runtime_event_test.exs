defmodule BeamAgent.RuntimeEventTest do
  use ExUnit.Case, async: true

  alias BeamAgent.RuntimeEvent

  defp category(type) do
    RuntimeEvent.durable("project", "goal", "session", %{"type" => type, "seq" => 0}).category
  end

  test "mcp lifecycle events form their own category" do
    for type <- [
          "mcp_server_started",
          "mcp_server_restarted",
          "mcp_server_stopped",
          "mcp_server_failed",
          "mcp_server_unavailable",
          "mcp_call_cancelled"
        ] do
      assert category(type) == :mcp
    end
  end

  test "verification events form their own category" do
    for type <- [
          "verification_attached",
          "verification_started",
          "verification_check_started",
          "verification_check_finished",
          "verification_finished",
          "verification_cancelled",
          "verification_recovery_started",
          "verification_feedback",
          "implementation_review_started",
          "implementation_review_finished",
          "implementation_review_recovery_started",
          "review_feedback"
        ] do
      assert category(type) == :verification
    end
  end

  test "outcome recording stays in the outcome category" do
    assert category("model_outcome_recorded") == :outcome
    assert category("task_outcome_recorded") == :outcome
    assert category("completion_report_generated") == :outcome
  end

  test "semantic completion guard events stay with model activity" do
    assert category("model_completion_deferred") == :model
    assert category("model_completion_rejected") == :model
    assert category("completion_feedback") == :model
  end

  test "resource governance events stay in the resource category" do
    assert category("budget_allocated") == :resource
    assert category("capability_lease_issued") == :resource
    assert category("worktree_created") == :resource
  end

  test "the query vocabulary exposes every category it accepts" do
    categories = BeamAgent.RuntimeEventQuery.categories()

    assert :mcp in categories
    assert :verification in categories

    assert {:ok, %{categories: [:mcp, :verification]}} =
             BeamAgent.RuntimeEventQuery.parse("category=mcp,verification")
  end
end
