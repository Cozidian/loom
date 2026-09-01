defmodule BeamAgent.WorkPlanningPolicy do
  @moduledoc """
  Runtime-owned decision about whether one turn should remain direct or invite a
  validated multi-provider decomposition.

  The policy never constructs authority. A model may propose task semantics,
  but `DecompositionPlan`, `AgentConstructor`, provider auctions, leases, and
  verification remain authoritative.
  """

  alias BeamAgent.TaskClassifier

  @explicit_multi_provider ~r/\b(?:multiple|different|several)\s+(?:configured\s+)?(?:models?|providers?)\b|\b(?:models?|providers?)\s+(?:for|across)\s+(?:different|separate)\b|\b(?:ollama|codex|grok|claude|openai|anthropic|xai)\b.{0,100}\b(?:ollama|codex|grok|claude|openai|anthropic|xai)\b/iu

  def decide(prompt, endpoints, opts \\ []) when is_binary(prompt) and is_list(endpoints) do
    classification = TaskClassifier.classify(prompt, Keyword.get(opts, :workspace_root))
    strategy = Keyword.get(opts, :model_strategy, :manual)
    eligible = Enum.reject(endpoints, &(&1.health.status == :unavailable))
    explicit? = Regex.match?(@explicit_multi_provider, prompt)
    implementation? = classification.change_intent or classification.task_type == :implementation
    multi_endpoint? = length(eligible) >= 2
    substantial? = implementation? and substantial_implementation?(prompt, classification)

    mode =
      cond do
        implementation? and explicit? and multi_endpoint? ->
          :required

        implementation? and strategy == :auto and multi_endpoint? and substantial? ->
          :required

        implementation? and strategy == :auto and multi_endpoint? ->
          :advisory

        true ->
          :direct
      end

    %{
      version: 1,
      mode: mode,
      source: :runtime_policy,
      classification: classification,
      endpoint_count: length(eligible),
      explicit_multi_provider_intent: explicit?,
      suggested_endpoints: suggested_endpoints(eligible),
      reason: reason(mode, explicit?, multi_endpoint?, substantial?)
    }
  end

  defp suggested_endpoints(endpoints) do
    local =
      Enum.find(endpoints, fn endpoint ->
        endpoint.claims.locality == :local or endpoint.claims.cost_hint == :free
      end)

    strong =
      Enum.find(endpoints, fn endpoint ->
        endpoint.claims.locality == :remote and :reasoning in endpoint.claims.capabilities
      end) || Enum.find(endpoints, &(&1 != local))

    review = Enum.find(endpoints, &(&1 != local and &1 != strong)) || strong

    %{
      scaffold: local && local.id,
      implementation: strong && strong.id,
      verification: review && review.id
    }
  end

  defp substantial_implementation?(prompt, classification) do
    classification.reasoning == :high or
      Regex.match?(
        ~r/\b(?:application|frontend|backend|middleware|service|feature|migration|integration|phoenix|liveview)\b/iu,
        prompt
      )
  end

  defp reason(:required, true, _multi?, _substantial?),
    do: "the user explicitly requested a multi-model implementation"

  defp reason(:required, false, _multi?, true),
    do: "substantial automatic implementation requires bounded provider specialization"

  defp reason(:advisory, _explicit?, _multi?, _substantial?),
    do: "implementation can benefit from bounded provider specialization"

  defp reason(:direct, true, false, _substantial?),
    do: "multi-model work was requested but fewer than two eligible endpoints are available"

  defp reason(:direct, _explicit?, _multi?, _substantial?),
    do: "one coherent worker is the lowest-overhead execution shape"
end
