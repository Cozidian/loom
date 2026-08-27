defmodule BeamAgent.RoutingEvidenceTest do
  use ExUnit.Case, async: true

  alias BeamAgent.RoutingEvidence

  @now ~U[2026-08-27 18:00:00Z]

  test "attributes verified task outcomes to one endpoint and recommends from sufficient evidence" do
    records =
      Enum.flat_map(1..5, fn index ->
        remote = model("remote-#{index}", "remote", 1_000, index)
        remote_task = task("remote-#{index}", "passed", index)
        local = model("local-#{index}", "local", 100, index)
        local_status = if index == 5, do: "failed", else: "passed"
        local_task = task("local-#{index}", local_status, index)
        [remote, remote_task, local, local_task]
      end)

    evidence =
      RoutingEvidence.summarize(records,
        now: @now,
        task_type: :simple,
        language: :elixir,
        endpoint_ids: ["local", "remote"],
        minimum_verified_samples: 5
      )

    assert evidence.state == "ready"
    assert evidence.recommended_endpoint_id == "remote"

    remote = Enum.find(evidence.endpoints, &(&1.endpoint_id == "remote"))
    local = Enum.find(evidence.endpoints, &(&1.endpoint_id == "local"))
    assert remote.verified_samples == 5
    assert remote.verified_pass_rate == 1.0
    assert remote.average_latency_ms == 1_000
    assert local.verified_pass_rate == 0.8
    assert local.average_latency_ms == 100
  end

  test "operational success without verification cannot produce a recommendation" do
    records = [model("session-a", "local", 100, 1), model("session-b", "remote", 200, 1)]

    evidence =
      RoutingEvidence.summarize(records,
        now: @now,
        endpoint_ids: ["local", "remote"],
        minimum_verified_samples: 1
      )

    assert evidence.state == "insufficient_evidence"
    assert evidence.recommended_endpoint_id == nil
    assert evidence.best_verified_samples == 0
    assert Enum.all?(evidence.endpoints, &(&1.operational_success_rate == 1.0))
  end

  test "task verification is not attributed when a turn used multiple endpoints" do
    records = [
      model("session-shared", "local", 100, 1),
      model("session-shared", "remote", 200, 1),
      task("session-shared", "passed", 1)
    ]

    evidence =
      RoutingEvidence.summarize(records,
        now: @now,
        endpoint_ids: ["local", "remote"],
        minimum_verified_samples: 1
      )

    assert evidence.state == "insufficient_evidence"
    assert Enum.all?(evidence.endpoints, &(&1.verified_samples == 0))
  end

  defp model(session_id, endpoint_id, latency_ms, age_days) do
    %{
      id: "model-#{session_id}-#{endpoint_id}",
      kind: "model",
      session_id: session_id,
      turn: 1,
      endpoint_id: endpoint_id,
      task_type: "simple",
      language: "elixir",
      latency_ms: latency_ms,
      status: "succeeded",
      verification: %{"status" => "unverified"},
      recorded_at: @now |> DateTime.add(-age_days, :day) |> DateTime.to_iso8601()
    }
  end

  defp task(session_id, status, age_days) do
    %{
      id: "task-#{session_id}",
      kind: "task",
      session_id: session_id,
      turn: 1,
      task_type: "simple",
      language: "elixir",
      status: "succeeded",
      verification: %{"status" => status},
      recorded_at: @now |> DateTime.add(-age_days, :day) |> DateTime.to_iso8601()
    }
  end
end
