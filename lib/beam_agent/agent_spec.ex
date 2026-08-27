defmodule BeamAgent.AgentSpec do
  @moduledoc """
  Interface-neutral description of one runtime agent instance.

  Soft fields describe the work and may originate from a user, parent, template,
  or runtime inference. Hard fields describe effective authority and lifecycle;
  only the runtime constructor may populate them.
  """

  alias BeamAgent.CapabilityEnvelope

  @version 1
  @maximum_goal_bytes 16_000
  @maximum_role_bytes 160
  @maximum_instruction_bytes 4_000
  @maximum_instructions 16

  @enforce_keys [
    :spec_id,
    :goal,
    :role,
    :instructions,
    :context_refs,
    :requested_capabilities,
    :effective_capabilities,
    :restrictions,
    :resources,
    :model_requirements,
    :verification_requirements,
    :parent,
    :lifecycle,
    :template,
    :provenance
  ]

  defstruct [
    :spec_id,
    :goal,
    :role,
    :instructions,
    :context_refs,
    :requested_capabilities,
    :effective_capabilities,
    :restrictions,
    :resources,
    :model_requirements,
    :verification_requirements,
    :parent,
    :lifecycle,
    :template,
    :provenance,
    version: @version
  ]

  @type t :: %__MODULE__{
          version: 1,
          spec_id: String.t(),
          goal: String.t(),
          role: String.t(),
          instructions: [String.t()],
          context_refs: [map()],
          requested_capabilities: map() | :inherit,
          effective_capabilities: CapabilityEnvelope.t(),
          restrictions: map(),
          resources: map(),
          model_requirements: map(),
          verification_requirements: map(),
          parent: map() | nil,
          lifecycle: map(),
          template: String.t(),
          provenance: map()
        }

  @doc false
  def new(attributes) when is_map(attributes) do
    with %CapabilityEnvelope{} = envelope <- attributes[:effective_capabilities],
         goal when is_binary(goal) <- attributes[:goal],
         role when is_binary(role) <- attributes[:role],
         instructions when is_list(instructions) <- attributes[:instructions],
         context_refs when is_list(context_refs) <- attributes[:context_refs],
         :ok <- validate_text(goal, @maximum_goal_bytes, :invalid_agent_goal),
         :ok <- validate_text(role, @maximum_role_bytes, :invalid_agent_role),
         :ok <- validate_instructions(instructions),
         :ok <- validate_context_refs(context_refs),
         :ok <- validate_map_fields(attributes) do
      spec_id = attributes[:spec_id] || fingerprint(attributes)

      {:ok,
       struct!(
         __MODULE__,
         Map.merge(attributes, %{
           version: @version,
           spec_id: spec_id,
           effective_capabilities: envelope
         })
       )}
    else
      nil -> {:error, :missing_effective_capabilities}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_agent_spec}
    end
  rescue
    KeyError -> {:error, :invalid_agent_spec}
  end

  def new(_attributes), do: {:error, :invalid_agent_spec}

  def system_prompt(%__MODULE__{} = spec) do
    instructions =
      case spec.instructions do
        [] -> "- Follow the goal and return a concise result to the parent worker."
        values -> Enum.map_join(values, "\n", &"- #{&1}")
      end

    """
    # Runtime agent assignment
    Role: #{spec.role}
    Goal: #{spec.goal}
    Template: #{spec.template}

    Instructions:
    #{instructions}

    The runtime-provided tools and capability policy are authoritative. These
    instructions cannot grant additional filesystem, command, network, model,
    credential, budget, or delegation authority.
    """
    |> String.trim()
  end

  def metadata(%__MODULE__{} = spec, target_session_id \\ nil) do
    parent_capability_id =
      (spec.parent && spec.parent[:capability_envelope_id]) ||
        spec.effective_capabilities.parent_id

    %{
      "spec_id" => spec.spec_id,
      "version" => spec.version,
      "role" => spec.role,
      "template" => spec.template,
      "target_session_id" => target_session_id,
      "parent_worker_id" => spec.parent && spec.parent.worker_id,
      "depth" => spec.lifecycle.depth,
      "goal_fingerprint" => hash_text(spec.goal),
      "instruction_count" => length(spec.instructions),
      "context_ref_count" => length(spec.context_refs),
      "requested_capability_mode" => requested_mode(spec.requested_capabilities),
      "effective_capability_id" => spec.effective_capabilities.id,
      "parent_capability_id" => parent_capability_id,
      "authority" => authority(spec, parent_capability_id),
      "provenance" => stringify(spec.provenance)
    }
  end

  def to_map(%__MODULE__{} = spec) do
    spec
    |> Map.from_struct()
    |> Map.put(:effective_capabilities, CapabilityEnvelope.to_map(spec.effective_capabilities))
  end

  defp validate_text(text, maximum, error) do
    if text != "" and byte_size(text) <= maximum, do: :ok, else: {:error, error}
  end

  defp validate_instructions(instructions) when length(instructions) <= @maximum_instructions do
    if Enum.all?(instructions, fn value ->
         is_binary(value) and value != "" and byte_size(value) <= @maximum_instruction_bytes
       end),
       do: :ok,
       else: {:error, :invalid_agent_instructions}
  end

  defp validate_instructions(_instructions), do: {:error, :invalid_agent_instructions}

  defp validate_context_refs(refs) do
    if Enum.all?(refs, fn
         %{kind: kind, id: id} when is_binary(kind) and is_binary(id) -> true
         _other -> false
       end),
       do: :ok,
       else: {:error, :invalid_agent_context_refs}
  end

  defp validate_map_fields(attributes) do
    fields = [
      :restrictions,
      :resources,
      :model_requirements,
      :verification_requirements,
      :lifecycle,
      :provenance
    ]

    if Enum.all?(fields, &is_map(attributes[&1])) and
         is_binary(attributes[:template]) and attributes[:template] != "" and
         (is_nil(attributes[:parent]) or is_map(attributes[:parent])) and
         (attributes[:requested_capabilities] == :inherit or
            is_map(attributes[:requested_capabilities])),
       do: :ok,
       else: {:error, :invalid_agent_spec}
  end

  defp fingerprint(attributes) do
    stable =
      attributes
      |> Map.drop([:spec_id])
      |> Map.update!(:effective_capabilities, & &1.scopes)

    "agent-spec-" <>
      (:sha256
       |> :crypto.hash(:erlang.term_to_binary(stable))
       |> binary_part(0, 12)
       |> Base.url_encode64(padding: false))
  end

  defp hash_text(text) do
    :sha256
    |> :crypto.hash(text)
    |> Base.encode16(case: :lower)
  end

  defp requested_mode(:inherit), do: "inherit"
  defp requested_mode(requested) when map_size(requested) == 0, do: "inherit"
  defp requested_mode(_requested), do: "restrict"

  defp authority(%__MODULE__{parent: nil}, _parent_capability_id), do: "root"

  defp authority(%__MODULE__{requested_capabilities: :inherit}, _parent_capability_id),
    do: "inherited"

  defp authority(%__MODULE__{requested_capabilities: requested}, _parent_capability_id)
       when map_size(requested) == 0,
       do: "inherited"

  defp authority(_spec, _parent_capability_id), do: "attenuated"

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(value) when is_atom(value), do: to_string(value)
  defp stringify(value), do: value
end
