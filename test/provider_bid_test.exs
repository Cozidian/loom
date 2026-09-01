defmodule BeamAgent.ProviderBidTest do
  use ExUnit.Case, async: true

  alias BeamAgent.{ModelEndpoint, ProviderBid}

  test "free locality wins simple work but not unverified feature implementation" do
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
               claims: %{locality: :remote, privacy: :provider, cost_hint: :metered}
             })

    base = %{
      preferred_endpoint_id: "openai-chatgpt",
      routing_evidence: %{mode: :shadow},
      reasoning_requirement: :standard
    }

    implementation = Map.put(base, :classification, %{task_type: :implementation})
    local_implementation = ProviderBid.quote("implementation", local, %{}, implementation)
    remote_implementation = ProviderBid.quote("implementation", remote, %{}, implementation)

    assert remote_implementation.score > local_implementation.score
    assert remote_implementation.score_components.configured_preference == 15
    assert local_implementation.score_components.cost == 5

    simple = Map.put(base, :classification, %{task_type: :simple})
    local_simple = ProviderBid.quote("simple", local, %{}, simple)
    remote_simple = ProviderBid.quote("simple", remote, %{}, simple)

    assert local_simple.score > remote_simple.score
    assert local_simple.score_components.locality == 35
  end
end
