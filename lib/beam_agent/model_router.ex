defmodule BeamAgent.ModelRouter do
  @moduledoc "Project-owned deterministic router for individual intelligence requests."
  use GenServer

  alias BeamAgent.{CapabilityEnvelope, ModelEndpoint, ModelRegistry, Names, TaskClassifier}

  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:model_router, project_id))
  end

  def route(project_id, input) do
    with {:ok, pid} <- Names.pid(:model_router, project_id),
         do: GenServer.call(pid, {:route, input})
  end

  @impl true
  def init(opts), do: {:ok, %{project_id: Keyword.fetch!(opts, :project_id)}}

  @impl true
  def handle_call({:route, input}, _from, state) do
    {:ok, endpoints} = ModelRegistry.list(state.project_id)
    {:reply, choose(endpoints, input), state}
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
        tools_required: input.tools != []
      })

    strategy = Map.get(input, :strategy, :manual)
    candidates = candidates(endpoints, input, strategy)

    cond do
      strategy == :auto and classification.deterministic_answer != nil ->
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
        select_fallback(strategy, input, classification)

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
      Map.get(input, :privacy_requirement) != :local or endpoint.claims.privacy == :local
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
    available = if endpoint.health.status == :available, do: 15, else: 5

    local_simple =
      if classification.task_type == :simple and endpoint.claims.locality == :local,
        do: 70,
        else: 0

    free = if endpoint.claims.cost_hint == :free, do: 15, else: 0

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
      case endpoint.measurements[:latency_ms] || endpoint.measurements["latency_ms"] do
        milliseconds when is_number(milliseconds) -> max(0, 20 - trunc(milliseconds / 250))
        _unknown -> 0
      end

    preferred + available + local_simple + free + strong + context_fit + latency
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
    if CapabilityEnvelope.authorize(Map.get(input, :capability_envelope), %{
         model_classes: model_class(endpoint)
       }) == :ok,
       do: endpoint,
       else: nil
  end

  defp eligible_fallback(_input), do: nil
end
