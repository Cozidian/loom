defmodule BeamAgent.ProviderBidTest do
  use ExUnit.Case, async: true

  alias BeamAgent.{ModelEndpoint, ProviderBid}

  test "session defaults do not masquerade as explicit assignment preferences" do
    assert {:ok, local} =
             ModelEndpoint.new(%{
               id: "ollama",
               provider: :ollama,
               claims: %{locality: :local, privacy: :local, cost_hint: :free}
             })

    assert {:ok, remote} =
             ModelEndpoint.new(%{
               id: "openai-chatgpt",
               provider: :openai,
               claims: %{
                 locality: :remote,
                 privacy: :provider,
                 cost_hint: :metered,
                 capabilities: [:reasoning]
               }
             })

    base = %{
      preferred_endpoint_id: "openai-chatgpt",
      preference_source: :session_default,
      routing_evidence: %{mode: :shadow},
      reasoning_requirement: :high,
      job_role: "coherent implementation owner"
    }

    implementation = Map.put(base, :classification, %{task_type: :implementation})
    local_implementation = ProviderBid.quote("implementation", local, %{}, implementation)
    remote_implementation = ProviderBid.quote("implementation", remote, %{}, implementation)

    assert remote_implementation.score > local_implementation.score
    assert remote_implementation.score_components.configured_preference == 0
    assert remote_implementation.score_components.role_fit == 20
    assert local_implementation.score_components.cost == 5

    simple =
      base
      |> Map.put(:classification, %{task_type: :simple})
      |> Map.put(:reasoning_requirement, :standard)
      |> Map.put(:job_role, "answer a simple question")

    local_simple = ProviderBid.quote("simple", local, %{}, simple)
    remote_simple = ProviderBid.quote("simple", remote, %{}, simple)

    assert local_simple.score > remote_simple.score
    assert local_simple.score_components.locality == 35
  end

  test "explicit worker assignments remain authoritative" do
    endpoint = endpoint("grok", :remote, 8_000)

    bid =
      ProviderBid.quote("assigned", endpoint, %{}, %{
        preferred_endpoint_id: "grok",
        preference_source: :work_assignment,
        routing_evidence: %{mode: :shadow},
        classification: %{task_type: :implementation},
        reasoning_requirement: :standard
      })

    assert bid.score_components.configured_preference == 20
  end

  test "realistic provider latency remains differentiating beyond five seconds" do
    fast = ProviderBid.quote("latency", endpoint("fast", :remote, 7_000), %{}, base_input())
    slow = ProviderBid.quote("latency", endpoint("slow", :remote, 52_000), %{}, base_input())

    assert fast.score_components.latency == 12
    assert slow.score_components.latency == 0
    assert fast.score > slow.score
  end

  test "verified failures are a bounded negative signal even in shadow mode" do
    failed_evidence = %{
      endpoints: [
        %{
          endpoint_id: "failed",
          verified_samples: 6,
          recency_weighted_pass_rate: 0.0,
          confidence: 1.0
        }
      ]
    }

    bid =
      ProviderBid.quote(
        "evidence",
        endpoint("failed", :remote, 7_000),
        failed_evidence,
        base_input()
      )

    assert bid.score_components.verified_evidence == -10
  end

  defp base_input do
    %{
      preference_source: :session_default,
      routing_evidence: %{mode: :shadow},
      classification: %{task_type: :implementation},
      reasoning_requirement: :standard
    }
  end

  defp endpoint(id, locality, latency) do
    {:ok, endpoint} =
      ModelEndpoint.new(%{
        id: id,
        provider: :echo,
        claims: %{locality: locality, privacy: :provider, cost_hint: :metered},
        measurements: %{latency_ms: latency}
      })

    endpoint
  end
end
