defmodule BeamAgent.AgentConstructionPolicy do
  @moduledoc """
  Deterministic boundary between agent proposals and runtime-owned authority.

  Intelligence may propose soft behavior and request an attenuation of its
  parent's capabilities. It may not populate effective authority, credentials,
  resources, budgets, lifetime, or approval state.
  """

  alias BeamAgent.CapabilityEnvelope

  @hard_fields ~w(
    effective_capabilities restrictions resources budget deadline lifecycle
    credentials secrets provider_options approval_policy capability_leases
  )

  def evaluate_root(%CapabilityEnvelope{} = envelope) do
    {:ok, decision(:root, :inherit, envelope, [], ["root authority supplied by runtime policy"])}
  end

  def evaluate_child(%CapabilityEnvelope{} = parent, proposal) when is_map(proposal) do
    rejected =
      proposal
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.filter(&(&1 in @hard_fields))
      |> Enum.uniq()
      |> Enum.sort()

    if rejected != [] do
      {:error, {:hard_authority_fields_rejected, rejected}}
    else
      requested = value(proposal, :capabilities) || :inherit

      with :ok <- validate_requested(requested),
           {:ok, effective} <- effective(parent, requested) do
        disposition =
          if requested == :inherit or map_size(requested) == 0, do: :inherited, else: :attenuated

        {:ok,
         decision(disposition, requested, effective, [], [
           "effective authority is bounded by the parent capability envelope"
         ])}
      end
    end
  end

  def evaluate_child(_parent, _proposal), do: {:error, :invalid_agent_proposal}

  def metadata(decision) do
    %{
      "decision_id" => decision.id,
      "disposition" => to_string(decision.disposition),
      "rejected_fields" => decision.rejected_fields,
      "reasons" => decision.reasons
    }
  end

  defp decision(disposition, requested, effective, rejected_fields, reasons) do
    stable = {disposition, requested, effective.scopes, rejected_fields, reasons}

    %{
      id:
        "authority-decision-" <>
          (:sha256
           |> :crypto.hash(:erlang.term_to_binary(stable))
           |> binary_part(0, 9)
           |> Base.url_encode64(padding: false)),
      disposition: disposition,
      requested: requested,
      effective: effective,
      rejected_fields: rejected_fields,
      reasons: reasons
    }
  end

  defp validate_requested(:inherit), do: :ok
  defp validate_requested(value) when is_map(value), do: :ok
  defp validate_requested(_value), do: {:error, :invalid_requested_capabilities}

  defp effective(parent, :inherit), do: {:ok, parent}
  defp effective(parent, requested), do: CapabilityEnvelope.restrict(parent, requested)

  defp value(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
end
