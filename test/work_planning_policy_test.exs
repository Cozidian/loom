defmodule BeamAgent.WorkPlanningPolicyTest do
  use ExUnit.Case, async: true

  alias BeamAgent.{ModelEndpoint, WorkPlanningPolicy}

  test "team mode and owner model routing are independent" do
    pinned =
      WorkPlanningPolicy.decide("Build a Phoenix frontend", endpoints(),
        model_strategy: :manual,
        team_mode: :auto
      )

    assert pinned.mode == :advisory
    assert pinned.team_mode == :auto

    solo =
      WorkPlanningPolicy.decide("Build a Phoenix frontend", endpoints(),
        model_strategy: :auto,
        team_mode: :solo
      )

    assert solo.mode == :direct
    assert solo.reason =~ "solo team mode"
  end

  test "explicit multi-model implementation requires a validated decomposition" do
    decision =
      WorkPlanningPolicy.decide(
        "Build the Phoenix view with Ollama for scaffolding, Codex for middleware, and Grok for tests",
        endpoints(),
        model_strategy: :auto
      )

    assert decision.mode == :required
    assert decision.explicit_multi_provider_intent
    assert decision.suggested_endpoints.scaffold == "local"
    assert decision.suggested_endpoints.implementation == "strong"
    assert decision.suggested_endpoints.verification == "review"
  end

  test "configured provider wording is still explicit multi-provider intent" do
    decision =
      WorkPlanningPolicy.decide(
        "Implement the feature. Use different configured providers for investigation and review.",
        endpoints(),
        model_strategy: :auto
      )

    assert decision.mode == :required
    assert decision.explicit_multi_provider_intent
  end

  test "substantial automatic work can use specialists without requiring them" do
    assert WorkPlanningPolicy.decide(
             "Build an end-to-end Phoenix web version and integrate it with the runtime",
             endpoints(),
             model_strategy: :auto
           ).mode == :advisory

    decision =
      WorkPlanningPolicy.decide(
        "Build a Phoenix frontend that can do the same as the TUI",
        endpoints(),
        model_strategy: :auto
      )

    assert decision.mode == :advisory
    refute decision.explicit_multi_provider_intent

    assert WorkPlanningPolicy.decide("Explain the actor model", endpoints(),
             model_strategy: :auto
           ).mode == :direct
  end

  test "small automatic edits are advisory rather than forced into a team" do
    assert WorkPlanningPolicy.decide("Fix a typo in README", endpoints(), model_strategy: :auto).mode ==
             :advisory
  end

  test "product comparisons do not require a provider organization" do
    decision =
      WorkPlanningPolicy.decide(
        "Implement a Phoenix frontend for this harness with a chat like Codex or Claude",
        endpoints(),
        model_strategy: :auto
      )

    assert decision.mode == :advisory
    refute decision.explicit_multi_provider_intent
  end

  test "the policy does not pretend unavailable providers can form a team" do
    assert WorkPlanningPolicy.decide(
             "Use different providers to implement this feature",
             [hd(endpoints())],
             model_strategy: :auto
           ).mode == :direct
  end

  defp endpoints do
    [
      endpoint("local", :local, :free, []),
      endpoint("strong", :remote, :metered, [:reasoning]),
      endpoint("review", :remote, :metered, [:reasoning])
    ]
  end

  defp endpoint(id, locality, cost, capabilities) do
    {:ok, endpoint} =
      ModelEndpoint.new(%{
        id: id,
        provider: :echo,
        claims: %{locality: locality, cost_hint: cost, capabilities: capabilities}
      })

    endpoint
  end
end
