defmodule BeamAgent.ModelRouter do
  @moduledoc "Project-owned deterministic router for individual intelligence requests."
  use GenServer

  alias BeamAgent.{
    CapabilityEnvelope,
    ModelEndpoint,
    ModelRegistry,
    Names,
    OutcomeStore,
    Project.ContextStore,
    TaskClassifier
  }

  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:model_router, project_id))
  end

  def route(project_id, input) do
    call(project_id, {:route, input})
  end

  def preferences(project_id) do
    call(project_id, :preferences)
  end

  def update_preferences(project_id, preferences) when is_map(preferences) do
    call(project_id, {:update_preferences, preferences})
  end

  @impl true
  def init(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    persisted = persisted_preferences(project_id)

    {:ok,
     %{
       project_id: project_id,
       evidence_mode:
         normalize_evidence_mode(
           Keyword.get(
             opts,
             :routing_evidence_mode,
             persisted_value(persisted, :evidence_mode, :shadow)
           )
         ),
       exploration_percent:
         normalize_exploration(
           Keyword.get(
             opts,
             :routing_exploration_percent,
             persisted_value(persisted, :exploration_percent, 5)
           )
         ),
       excluded_endpoint_ids:
         MapSet.new(
           Keyword.get(
             opts,
             :routing_excluded_endpoints,
             persisted_value(persisted, :excluded_endpoint_ids, [])
           )
         ),
       preferred_endpoint_ids:
         Keyword.get(
           opts,
           :routing_preferred_endpoints,
           persisted_value(persisted, :preferred_endpoint_ids, [])
         )
     }}
  end

  @impl true
  def handle_call({:route, input}, _from, state) do
    {:ok, endpoints} = ModelRegistry.list(state.project_id)

    endpoints = Enum.reject(endpoints, &MapSet.member?(state.excluded_endpoint_ids, &1.id))
    input = Map.put_new(input, :project_preferred_endpoint_ids, state.preferred_endpoint_ids)

    result =
      case choose(endpoints, input) do
        {:ok, decision} ->
          decision = add_routing_evidence(state.project_id, decision, input)
          {:ok, apply_evidence_policy(state, decision, endpoints)}

        {:error, _reason} = error ->
          error
      end

    {:reply, result, state}
  end

  def handle_call(:preferences, _from, state),
    do: {:reply, {:ok, public_preferences(state)}, state}

  def handle_call({:update_preferences, preferences}, _from, state) do
    case normalize_preferences(preferences, state) do
      {:ok, state} -> {:reply, {:ok, public_preferences(state)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp normalize_preferences(preferences, state) do
    evidence_mode = value(preferences, :evidence_mode, state.evidence_mode)
    exploration = value(preferences, :exploration_percent, state.exploration_percent)

    excluded =
      value(preferences, :excluded_endpoint_ids, MapSet.to_list(state.excluded_endpoint_ids))

    preferred = value(preferences, :preferred_endpoint_ids, state.preferred_endpoint_ids)

    if evidence_mode in [:shadow, :enabled, "shadow", "enabled"] and
         is_integer(exploration) and exploration in 0..10 and is_list(excluded) and
         is_list(preferred) and Enum.all?(excluded ++ preferred, &is_binary/1) do
      {:ok,
       %{
         state
         | evidence_mode: normalize_evidence_mode(evidence_mode),
           exploration_percent: exploration,
           excluded_endpoint_ids: MapSet.new(excluded),
           preferred_endpoint_ids: preferred
       }}
    else
      {:error, :invalid_routing_preferences}
    end
  end

  defp public_preferences(state) do
    %{
      evidence_mode: state.evidence_mode,
      exploration_percent: state.exploration_percent,
      excluded_endpoint_ids: state.excluded_endpoint_ids |> MapSet.to_list() |> Enum.sort(),
      preferred_endpoint_ids: state.preferred_endpoint_ids
    }
  end

  defp persisted_preferences(project_id) do
    case ContextStore.preferences(project_id) do
      {:ok, preferences} -> preferences
      _other -> %{}
    end
  end

  defp persisted_value(preferences, key, default),
    do: Map.get(preferences, to_string(key), Map.get(preferences, key, default))

  defp value(map, key, default), do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp call(project_id, message) do
    with {:ok, pid} <- Names.pid(:model_router, project_id) do
      GenServer.call(pid, message)
    end
  catch
    :exit, {:noproc, _details} -> {:error, :not_found}
    :exit, {:normal, _details} -> {:error, :not_found}
  end

  defp choose(endpoints, input) do
    classification =
      input.prompt
      |> TaskClassifier.classify(input.workspace_root)
      |> Map.merge(%{
        context_tokens: Map.get(input, :context_tokens, 0),
        latency_preference: Map.get(input, :latency_preference, :interactive),
        cost_preference: Map.get(input, :cost_preference, :prefer_low),
        privacy_requirement: Map.get(input, :privacy_requirement, :provider_allowed),
        modalities_required: Map.get(input, :modalities_required, [:text]),
        tools_required: input.tools != []
      })
      |> apply_reasoning_requirement(Map.get(input, :reasoning_requirement))

    strategy = Map.get(input, :strategy, :manual)
    candidates = candidates(endpoints, input, strategy)
    modalities_required = Map.get(input, :modalities_required, [:text])

    cond do
      strategy == :auto and classification.deterministic_answer != nil and
          modalities_required == [:text] ->
        {:ok,
         decision(
           nil,
           candidates,
           classification,
           "deterministic computation requires no model",
           classification.deterministic_answer
         )}

      match?({:custom, _}, strategy) ->
        custom(strategy, candidates, input, classification)

      candidates == [] ->
        case select_fallback(strategy, input, classification) do
          {:error, _reason} when modalities_required != [:text] ->
            {:error, {:no_eligible_model_for_modalities, modalities_required}}

          result ->
            result
        end

      strategy == :manual ->
        select_manual(candidates, input, classification)

      true ->
        select_auto(candidates, input, classification)
    end
  end

  defp candidates(endpoints, input, strategy) do
    endpoints
    |> Enum.reject(&(&1.health.status == :unavailable))
    |> Enum.filter(fn endpoint ->
      strategy != :local_only or endpoint.claims.locality == :local
    end)
    |> Enum.filter(fn endpoint ->
      locality = Map.get(input, :locality_requirement, :any)
      locality == :any or endpoint.claims.locality == locality
    end)
    |> Enum.filter(fn endpoint ->
      Map.get(input, :privacy_requirement) != :local or endpoint.claims.privacy == :local
    end)
    |> Enum.filter(fn endpoint ->
      Enum.all?(
        Map.get(input, :modalities_required, [:text]),
        &(&1 in endpoint.claims.modalities)
      )
    end)
    |> Enum.filter(fn endpoint ->
      CapabilityEnvelope.authorize(Map.get(input, :capability_envelope), %{
        model_classes: model_class(endpoint)
      }) == :ok
    end)
  end

  defp select_manual(candidates, input, classification) do
    selected =
      Enum.find(candidates, &(&1.id == input.preferred_endpoint_id)) ||
        Enum.find(candidates, &(&1.provider == input.preferred_provider))

    selected = selected || eligible_fallback(input)

    if selected,
      do:
        {:ok,
         decision(
           selected,
           Enum.uniq_by([selected | candidates], & &1.id),
           classification,
           "manual endpoint override"
         )},
      else: {:error, {:manual_model_unavailable, input.preferred_endpoint_id}}
  end

  defp select_fallback(
         :manual,
         input,
         classification
       ) do
    case eligible_fallback(input) do
      nil -> {:error, :no_eligible_model}
      endpoint -> {:ok, decision(endpoint, [endpoint], classification, "manual session endpoint")}
    end
  end

  defp select_fallback(_strategy, _input, _classification), do: {:error, :no_eligible_model}

  defp select_auto(candidates, input, classification) do
    selected = Enum.max_by(candidates, &score(&1, input, classification))

    reason =
      if classification.task_type in [:simple, :deterministic] and
           selected.claims.locality == :local,
         do: "local free endpoint preferred for simple work",
         else: "highest deterministic capability and policy score"

    {:ok, decision(selected, candidates, classification, reason)}
  end

  defp custom({:custom, module}, candidates, input, classification) when is_atom(module) do
    case module.route(input, candidates) do
      %ModelEndpoint{} = endpoint ->
        if Enum.any?(candidates, &(&1.id == endpoint.id)) do
          {:ok,
           decision(endpoint, candidates, classification, "custom strategy #{inspect(module)}")}
        else
          {:error, {:custom_model_outside_candidates, endpoint.id}}
        end

      nil ->
        {:ok,
         decision(
           nil,
           candidates,
           classification,
           "custom strategy selected deterministic execution"
         )}

      other ->
        {:error, {:invalid_custom_model_route, other}}
    end
  end

  defp score(endpoint, input, classification) do
    preferred = if endpoint.id == input.preferred_endpoint_id, do: 30, else: 0

    project_preferred =
      if endpoint.id in Map.get(input, :project_preferred_endpoint_ids, []), do: 20, else: 0

    available = if endpoint.health.status == :available, do: 15, else: 5

    local_simple =
      if classification.task_type == :simple and endpoint.claims.locality == :local,
        do: 70,
        else: 0

    free =
      if Map.get(input, :cost_preference, :prefer_low) == :prefer_low and
           endpoint.claims.cost_hint == :free,
         do: 15,
         else: 0

    strong =
      if classification.reasoning == :high and :reasoning in endpoint.claims.capabilities,
        do: 50,
        else: 0

    context_fit =
      case endpoint.claims.context_window_tokens do
        limit when is_integer(limit) and limit >= classification.context_tokens -> 10
        limit when is_integer(limit) -> -100
        _unknown -> 0
      end

    latency =
      if Map.get(input, :latency_preference, :interactive) == :interactive do
        case endpoint.measurements[:latency_ms] || endpoint.measurements["latency_ms"] do
          milliseconds when is_number(milliseconds) -> max(0, 20 - trunc(milliseconds / 250))
          _unknown -> 0
        end
      else
        0
      end

    preferred + project_preferred + available + local_simple + free + strong + context_fit +
      latency
  end

  defp decision(endpoint, candidates, classification, reason, deterministic_answer \\ nil) do
    %{
      decision_id:
        "route-" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)),
      endpoint: endpoint,
      selected_endpoint_id: endpoint && endpoint.id,
      candidate_endpoint_ids: Enum.map(candidates, & &1.id),
      candidates: Enum.map(candidates, &candidate_summary/1),
      inputs: Map.drop(classification, [:deterministic_answer]),
      reason: reason,
      deterministic_answer: deterministic_answer
    }
  end

  defp add_routing_evidence(project_id, decision, input) do
    if Map.get(input, :strategy, :manual) == :auto and decision.endpoint do
      opts = [
        task_type: decision.inputs.task_type,
        language: decision.inputs.language,
        endpoint_ids: decision.candidate_endpoint_ids
      ]

      evidence =
        case OutcomeStore.routing_evidence(project_id, opts) do
          {:ok, evidence} -> evidence
          {:error, _reason} -> unavailable_evidence()
        end

      Map.put(decision, :evidence, evidence)
    else
      decision
    end
  end

  defp unavailable_evidence do
    %{
      mode: "shadow",
      state: "unavailable",
      recommended_endpoint_id: nil,
      reason: "outcome evidence is unavailable; deterministic policy remains authoritative",
      endpoints: []
    }
  end

  defp apply_evidence_policy(%{evidence_mode: :shadow}, decision, _endpoints), do: decision
  defp apply_evidence_policy(_state, %{endpoint: nil} = decision, _endpoints), do: decision

  defp apply_evidence_policy(state, %{evidence: evidence} = decision, endpoints) do
    recommended_id = evidence.recommended_endpoint_id

    cond do
      evidence.state != "ready" or is_nil(recommended_id) ->
        put_in(decision, [:evidence, :mode], "enabled")

      explore?(decision.decision_id, state.exploration_percent) ->
        decision
        |> put_in([:evidence, :mode], "enabled")
        |> put_in([:evidence, :selection], "bounded_exploration")

      endpoint = Enum.find(endpoints, &(&1.id == recommended_id)) ->
        %{
          decision
          | endpoint: endpoint,
            selected_endpoint_id: endpoint.id,
            reason: "confidence-gated recommendation from recent verified outcomes",
            evidence:
              evidence
              |> Map.put(:mode, "enabled")
              |> Map.put(:selection, "verified_evidence")
        }

      true ->
        decision
    end
  end

  defp apply_evidence_policy(_state, decision, _endpoints), do: decision

  defp explore?(decision_id, percentage) do
    <<bucket::unsigned-integer-size(16), _rest::binary>> = :crypto.hash(:sha256, decision_id)
    rem(bucket, 100) < percentage
  end

  defp normalize_evidence_mode(value) when value in [:shadow, :enabled], do: value
  defp normalize_evidence_mode("enabled"), do: :enabled
  defp normalize_evidence_mode(_value), do: :shadow

  defp normalize_exploration(value) when is_integer(value), do: min(max(value, 0), 10)
  defp normalize_exploration(_value), do: 5

  defp model_class(endpoint),
    do: Enum.join([endpoint.claims.locality, endpoint.claims.cost_hint], ":")

  defp candidate_summary(endpoint) do
    %{
      id: endpoint.id,
      health: endpoint.health.status,
      locality: endpoint.claims.locality,
      privacy: endpoint.claims.privacy,
      cost_hint: endpoint.claims.cost_hint,
      context_window_tokens: endpoint.claims.context_window_tokens,
      measured_latency_ms:
        endpoint.measurements[:latency_ms] || endpoint.measurements["latency_ms"]
    }
  end

  defp eligible_fallback(%{fallback_endpoint: %ModelEndpoint{} = endpoint} = input) do
    if fallback_eligible?(endpoint, input),
      do: endpoint,
      else: nil
  end

  defp eligible_fallback(_input), do: nil

  defp fallback_eligible?(endpoint, input) do
    strategy = Map.get(input, :strategy, :manual)
    locality = Map.get(input, :locality_requirement, :any)
    privacy = Map.get(input, :privacy_requirement, :provider_allowed)

    (strategy != :local_only or endpoint.claims.locality == :local) and
      (locality == :any or endpoint.claims.locality == locality) and
      (privacy != :local or endpoint.claims.privacy == :local) and
      Enum.all?(
        Map.get(input, :modalities_required, [:text]),
        &(&1 in endpoint.claims.modalities)
      ) and
      CapabilityEnvelope.authorize(Map.get(input, :capability_envelope), %{
        model_classes: model_class(endpoint)
      }) == :ok
  end

  defp apply_reasoning_requirement(classification, :high),
    do: %{classification | reasoning: :high}

  defp apply_reasoning_requirement(classification, _requirement), do: classification
end
