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
end
