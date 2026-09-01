defmodule BeamAgent.ProviderBid do
  @moduledoc """
  A content-free quote from one configured model endpoint for one bounded job.

  Bids are computed by runtime-owned bidder processes from endpoint claims,
  health measurements, and durable outcome evidence. Providers never receive
  another provider's bid and no prompt content is persisted in a bid.
  """

  alias BeamAgent.ModelEndpoint

  @enforce_keys [
    :id,
    :auction_id,
    :endpoint_id,
    :provider,
    :score,
    :confidence,
    :cost_tier,
    :submitted_at
  ]
  defstruct [
    :id,
    :auction_id,
    :endpoint_id,
    :provider,
    :model,
    :score,
    :confidence,
    :estimated_latency_ms,
    :cost_tier,
    :verified_samples,
    :score_components,
    :reason,
    :submitted_at,
    version: 1
  ]

  @type t :: %__MODULE__{}

  def quote(auction_id, %ModelEndpoint{} = endpoint, evidence, input)
      when is_binary(auction_id) and is_map(input) do
    endpoint_evidence = endpoint_evidence(evidence, endpoint.id)
    confidence = number(endpoint_evidence, :confidence, health_confidence(endpoint))
    verified_samples = integer(endpoint_evidence, :verified_samples, 0)
    latency = measured_latency(endpoint, endpoint_evidence)
    cost_tier = endpoint.claims.cost_hint || :unknown
    score_components = score_components(endpoint, endpoint_evidence, input, latency)

    %__MODULE__{
      id: bid_id(auction_id, endpoint.id),
      auction_id: auction_id,
      endpoint_id: endpoint.id,
      provider: endpoint.provider,
      model: endpoint.model,
      score: score_components |> Map.values() |> Enum.sum(),
      confidence: Float.round(confidence * 1.0, 3),
      estimated_latency_ms: latency,
      cost_tier: cost_tier,
      verified_samples: verified_samples,
      score_components: score_components,
      reason: reason(endpoint, endpoint_evidence, input),
      submitted_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  def public(%__MODULE__{} = bid) do
    bid
    |> Map.from_struct()
    |> Map.update!(:provider, &to_string/1)
    |> Map.update!(:cost_tier, &to_string/1)
  end

  defp score_components(endpoint, evidence, input, latency) do
    health = if endpoint.health.status == :available, do: 15, else: 5

    preferred =
      if endpoint.id == input[:preferred_endpoint_id] and authoritative_preference?(input),
        do: 20,
        else: 0

    # Cost is a tie-breaker after task and configured-provider fit. It must not
    # make an unverified local endpoint the default owner of feature work.
    cost = if endpoint.claims.cost_hint == :free, do: 5, else: 0
    locality = locality_score(endpoint, input)
    reasoning = reasoning_score(endpoint, input)
    latency_score = latency_score(latency)
    role_fit = role_score(endpoint, input)
    evidence_score = evidence_score(evidence, input)

    %{
      health: health,
      configured_preference: preferred,
      cost: cost,
      locality: locality,
      reasoning: reasoning,
      role_fit: role_fit,
      latency: latency_score,
      verified_evidence: evidence_score
    }
  end

  defp evidence_score(evidence, input) do
    mode = get_in(input, [:routing_evidence, :mode])

    if mode in [:enabled, "enabled"] do
      pass_rate = number(evidence, :recency_weighted_pass_rate, 0.0)
      lower_bound = number(evidence, :quality_lower_bound, 0.0)
      confidence = number(evidence, :confidence, 0.0)
      round(pass_rate * 45 + lower_bound * 25 + confidence * 20)
    else
      verified_samples = integer(evidence, :verified_samples, 0)

      if verified_samples > 0 do
        pass_rate = number(evidence, :recency_weighted_pass_rate, 0.0)
        confidence = number(evidence, :confidence, 0.0)
        round((pass_rate - 0.5) * 20 * confidence)
      else
        0
      end
    end
  end

  defp authoritative_preference?(input) do
    input[:preference_source] in [:manual, :user_pinned, :work_assignment] or
      input[:strategy] == :manual
  end

  defp latency_score(milliseconds) when is_number(milliseconds) do
    cond do
      milliseconds <= 2_000 -> 20
      milliseconds <= 5_000 -> 16
      milliseconds <= 10_000 -> 12
      milliseconds <= 20_000 -> 8
      milliseconds <= 40_000 -> 4
      true -> 0
    end
  end

  defp latency_score(_latency), do: 0

  defp role_score(endpoint, input) do
    role = input[:job_role] |> to_string() |> String.downcase()
    task_type = get_in(input, [:classification, :task_type])

    remote_reasoner? =
      endpoint.claims.locality == :remote and :reasoning in endpoint.claims.capabilities

    local? = endpoint.claims.locality == :local

    cond do
      task_type == :implementation and remote_reasoner? -> 20
      String.contains?(role, ["implement", "architect", "middleware"]) and remote_reasoner? -> 20
      String.contains?(role, ["review", "verify", "test"]) and remote_reasoner? -> 15
      String.contains?(role, ["scaffold", "inspect", "investigate"]) and local? -> 15
      true -> 0
    end
  end

  defp locality_score(endpoint, input) do
    task_type = get_in(input, [:classification, :task_type])

    cond do
      input[:locality_requirement] == :local and endpoint.claims.locality == :local -> 40
      task_type in [:simple, :deterministic] and endpoint.claims.locality == :local -> 35
      true -> 0
    end
  end

  defp reasoning_score(endpoint, input) do
    reasoning_required? =
      input[:reasoning_requirement] == :high or
        get_in(input, [:classification, :reasoning]) == :high

    if reasoning_required? and :reasoning in endpoint.claims.capabilities,
      do: 35,
      else: 0
  end

  defp reason(endpoint, evidence, input) do
    cond do
      get_in(input, [:routing_evidence, :recommended_endpoint_id]) == endpoint.id and
          get_in(input, [:routing_evidence, :mode]) in [:enabled, "enabled"] ->
        "strongest confidence-gated verified outcome evidence"

      endpoint.claims.locality == :local and endpoint.claims.cost_hint == :free ->
        "local, free, and eligible for this capability envelope"

      integer(evidence, :verified_samples, 0) > 0 ->
        "eligible with #{integer(evidence, :verified_samples, 0)} verified outcome samples"

      true ->
        "eligible endpoint with declared capability fit"
    end
  end

  defp endpoint_evidence(%{endpoints: endpoints}, endpoint_id) when is_list(endpoints),
    do: Enum.find(endpoints, %{}, &(value(&1, :endpoint_id) == endpoint_id))

  defp endpoint_evidence(_evidence, _endpoint_id), do: %{}

  defp measured_latency(endpoint, evidence) do
    value(endpoint.measurements, :latency_ms) || value(evidence, :average_latency_ms)
  end

  defp health_confidence(%{health: %{status: :available}}), do: 0.5
  defp health_confidence(_endpoint), do: 0.25

  defp number(map, key, default) do
    case value(map, key) do
      value when is_number(value) -> value
      _other -> default
    end
  end

  defp integer(map, key, default) do
    case value(map, key) do
      value when is_integer(value) -> value
      _other -> default
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp value(_map, _key), do: nil

  defp bid_id(auction_id, endpoint_id) do
    digest = :crypto.hash(:sha256, auction_id <> ":" <> endpoint_id)
    "bid-" <> Base.url_encode64(binary_part(digest, 0, 9), padding: false)
  end
end
