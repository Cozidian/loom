defmodule BeamAgent.WorkContractTest do
  use ExUnit.Case, async: true

  alias BeamAgent.WorkContract

  test "implementation intent wins over test and failure vocabulary" do
    assert {:ok, contract} =
             WorkContract.new(
               "The tests are failing; implement a fix and add regression tests",
               File.cwd!()
             )

    assert contract.kind == :implementation
    assert contract.worker_kind == :implementer
    assert contract.expected_artifact == :workspace_patch
    assert contract.verification_required
    assert WorkContract.prompt(contract) =~ "OTP Goal process owns coordination"
  end

  test "short construction language cannot silently become simple answer work" do
    for objective <- [
          "we have a tui client, lets build a phoenix web version too",
          "yes, you should integrate it with the harness code",
          "Build a Phoenix web view that can do the same as the TUI",
          "Can you add regression tests for clipboard paste?"
        ] do
      assert {:ok, contract} = WorkContract.new(objective, File.cwd!())
      assert contract.kind == :implementation, objective
      assert contract.expected_artifact == :workspace_patch
      assert contract.verification_required
      assert contract.classification.change_intent
    end
  end

  test "deterministic arithmetic is not confused with an add request" do
    assert {:ok, contract} = WorkContract.new("Add 2 + 2", File.cwd!())
    assert contract.classification.task_type == :deterministic
    refute contract.classification.change_intent
  end

  test "requested orchestration cannot downgrade implementation authority" do
    assert {:ok, contract} =
             WorkContract.new(
               "Delegate implementation to Codex and tests to Grok",
               File.cwd!()
             )

    assert contract.classification.task_type == :orchestration
    assert contract.classification.change_intent
    assert contract.kind == :implementation
    assert contract.verification_required
  end
end
