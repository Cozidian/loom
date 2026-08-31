defmodule BeamAgent.AgentTemplate do
  @moduledoc """
  Versioned starting points used while dynamically constructing agents.

  Unknown template identifiers produce a safe runtime-generated template, so
  the catalog is not a closed population of personas.
  """

  alias BeamAgent.ExecutionStrategy

  @enforce_keys [
    :id,
    :version,
    :source,
    :role,
    :instructions,
    :model_requirements,
    :verification_requirements,
    :execution_strategy
  ]
  defstruct @enforce_keys

  @templates %{
    "goal-worker" => %{
      role: "Primary goal worker",
      instructions: [
        "Execute the runtime work contract directly with the granted tools.",
        "Treat investigation and delegation as intermediate evidence, not completion of implementation work.",
        "Return a completed artifact or a concrete blocker that requires user input."
      ],
      execution_strategy: "focused"
    },
    "coordinator" => %{
      role: "Goal coordinator",
      instructions: [
        "Decompose only when independent work or expertise justifies it.",
        "Use one primary implementer for a coherent change; use additional workers for independent research, verification, or review rather than duplicate ownership.",
        "Preserve the user's complete acceptance contract through delegation. Never silently reduce requested roadmap scope to a bounded MVP.",
        "For implementation requests, perform work with granted tools or delegate it; read-only investigation is not a terminal result."
      ],
      execution_strategy: "coordinate"
    },
    "researcher" => %{
      role: "Research specialist",
      instructions: ["Separate observed evidence from inference."],
      execution_strategy: "investigate"
    },
    "debugger" => %{
      role: "Debugging specialist",
      instructions: ["Test the smallest falsifiable hypothesis first."],
      execution_strategy: "investigate"
    },
    "implementer" => %{
      role: "Implementation specialist",
      instructions: [
        "Keep changes bounded to the delegated goal without narrowing its acceptance criteria.",
        "Remain the single owner of the coherent implementation; request research or review help only for independently bounded work."
      ],
      execution_strategy: "implement"
    },
    "reviewer" => %{
      role: "Review specialist",
      instructions: ["Prioritize correctness, security, and missing verification."],
      execution_strategy: "review",
      verification_requirements: %{required: true}
    },
    "verifier" => %{
      role: "Verification specialist",
      instructions: ["Report only checks supported by recorded execution evidence."],
      execution_strategy: "verify",
      verification_requirements: %{required: true}
    }
  }

  def resolve(nil, classification), do: resolve(default_id(classification), classification)

  def resolve(id, classification) when is_binary(id) do
    id = canonical_id(id)

    case Map.fetch(@templates, id) do
      {:ok, attributes} -> build(id, 1, :builtin, attributes)
      :error -> generated(id, classification)
    end
  end

  def resolve(_id, classification), do: resolve(nil, classification)

  def canonical_id("implement"), do: "implementer"
  def canonical_id("investigate"), do: "researcher"
  def canonical_id("verify"), do: "verifier"
  def canonical_id("review"), do: "reviewer"
  def canonical_id("coordinate"), do: "coordinator"
  def canonical_id(id), do: id

  defp generated(id, classification) do
    role = inferred_role(classification)

    build(id, 1, :runtime_generated, %{
      role: role,
      instructions: [],
      execution_strategy: strategy_id(classification.task_type)
    })
  end

  defp build(id, version, source, attributes) do
    %__MODULE__{
      id: id,
      version: version,
      source: source,
      role: attributes.role,
      instructions: Map.get(attributes, :instructions, []),
      model_requirements: Map.get(attributes, :model_requirements, %{}),
      verification_requirements: Map.get(attributes, :verification_requirements, %{}),
      execution_strategy: ExecutionStrategy.resolve(attributes.execution_strategy)
    }
  end

  defp default_id(%{task_type: :orchestration}), do: "coordinator"
  defp default_id(%{task_type: :debugging}), do: "debugger"
  defp default_id(%{task_type: :implementation}), do: "implementer"
  defp default_id(%{task_type: :verification}), do: "verifier"
  defp default_id(%{task_type: :architecture}), do: "researcher"
  defp default_id(_classification), do: "dynamic-specialist"

  defp strategy_id(:orchestration), do: "coordinate"
  defp strategy_id(:debugging), do: "investigate"
  defp strategy_id(:verification), do: "verify"
  defp strategy_id(:implementation), do: "implement"
  defp strategy_id(_task_type), do: "focused"

  defp inferred_role(classification) do
    language =
      case classification.language do
        :unknown -> nil
        value -> value |> to_string() |> String.capitalize()
      end

    focus =
      classification.task_type
      |> to_string()
      |> String.replace("_", " ")

    [language, focus, "specialist"] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end
end
