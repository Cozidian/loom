defmodule BeamAgent.Tools.ListModels do
  @moduledoc false
  @behaviour BeamAgent.Tool

  @impl true
  def name, do: "list_models"

  @impl true
  def description do
    "List safe model endpoint identities and routing claims for model-aware delegation."
  end

  @impl true
  def input_schema, do: %{type: "object", properties: %{}}

  @impl true
  def access, do: :read

  @impl true
  def execute(_arguments, context) do
    case BeamAgent.models(context.project_id) do
      {:ok, endpoints} ->
        models =
          Enum.map(endpoints, fn endpoint ->
            %{
              endpoint_id: endpoint.id,
              provider: endpoint.provider,
              model: endpoint.model,
              health: endpoint.health.status,
              locality: endpoint.claims.locality,
              privacy: endpoint.claims.privacy,
              cost: endpoint.claims.cost_hint,
              capabilities: endpoint.claims.capabilities,
              modalities: endpoint.claims.modalities,
              measured_latency_ms:
                endpoint.measurements[:latency_ms] || endpoint.measurements["latency_ms"]
            }
          end)

        {:ok, JSON.encode!(models)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
