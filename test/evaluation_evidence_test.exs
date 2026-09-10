defmodule BeamAgent.EvaluationEvidenceTest do
  use ExUnit.Case, async: true

  alias BeamAgent.Evaluation.{FileEvidence, Usage}

  test "unknown and partial usage never masquerade as a zero total" do
    unknown = Usage.summarize([event(:model_response_started), event(:model_response_finished)])
    assert unknown.total_tokens == nil
    assert unknown.usage_status == :unknown
    assert unknown.usage_missing_calls == 1

    partial =
      Usage.summarize([
        event(:model_response_started),
        event(:model_response_finished, %{"usage" => %{"total_tokens" => 12}}),
        event(:model_response_started),
        event(:model_response_failed)
      ])

    assert partial.total_tokens == nil
    assert partial.reported_tokens == 12
    assert partial.usage_status == :partial
    assert partial.usage_reported_calls == 1

    summary =
      Usage.aggregate([
        Map.put(unknown, :model_calls, 1),
        Map.put(partial, :model_calls, 2)
      ])

    assert summary.total_tokens == nil
    assert summary.reported_tokens == 12
    assert summary.usage_missing_calls == 2
  end

  test "an explicitly reported zero and a no-call run are distinguishable" do
    zero =
      Usage.summarize([
        event(:model_response_started),
        event(:model_response_finished, %{"usage" => %{"total_tokens" => 0}})
      ])

    assert zero.total_tokens == 0
    assert zero.usage_status == :complete
    assert Usage.summarize([]).usage_status == :not_applicable
  end

  test "canonical event log records have the same coverage as wrapped runtime events" do
    wrapped = [event(:model_response_started), event(:model_response_finished)]
    canonical = Enum.map(wrapped, & &1.payload)
    persisted = canonical |> JSON.encode!() |> JSON.decode!()
    assert Usage.summarize(canonical) == Usage.summarize(wrapped)
    assert Usage.summarize(persisted).usage_status == :unknown
    assert Usage.summarize(persisted).total_tokens == nil
  end

  test "a failed runner with unavailable event evidence is not reported as free" do
    result =
      Usage.aggregate([
        %{model_calls: 0, reported_tokens: 0, usage_reported_calls: 0, usage_unavailable_runs: 1}
      ])

    assert result.total_tokens == nil
    assert result.usage_status == :unknown
    assert result.usage_unavailable_runs == 1
  end

  test "binary originals are fingerprinted and missing or escaping paths fail closed" do
    root = Path.join(System.tmp_dir!(), "eval-evidence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root} = BeamAgent.Workspace.canonical_root(root)
    File.write!(Path.join(root, "original.bin"), <<0, 255, 1, 2>>)
    before = FileEvidence.capture(root, ["original.bin", "absent.bin", "../outside"])

    assert [%{passed: true}] =
             FileEvidence.compare(root, before, ["original.bin"], :file_preserved)

    File.write!(Path.join(root, "original.bin"), <<0, 255, 1, 3>>)

    assert [%{passed: false}] =
             FileEvidence.compare(root, before, ["original.bin"], :file_preserved)

    assert [%{passed: true}] = FileEvidence.compare(root, before, ["original.bin"], :file_changed)

    assert [%{passed: false}] =
             FileEvidence.compare(root, before, ["absent.bin"], :file_preserved)

    assert [%{passed: false}] = FileEvidence.compare(root, before, ["../outside"], :file_changed)

    File.ln_s!(Path.join(root, "../outside"), Path.join(root, "link"))
    baseline = FileEvidence.capture(root, ["link"])
    assert {:error, {:workspace_escape, _}} = baseline["link"]
  end

  defp event(type, data \\ %{}), do: %{payload: %{type: type, data: data}}
end
