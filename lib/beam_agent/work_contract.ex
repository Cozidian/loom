defmodule BeamAgent.WorkContract do
  @moduledoc """
  Runtime-owned description of one unit of goal work.

  The contract is deliberately small. It gives OTP enough information to own
  worker shape and completion semantics without turning model-proposed personas
  or template strings into authority.
  """

  alias BeamAgent.TaskClassifier

  @version 1
  @kinds [:implementation, :debugging, :verification, :investigation, :general]

  @enforce_keys [
    :id,
    :version,
    :objective,
    :kind,
    :worker_kind,
    :expected_artifact,
    :verification_required,
    :classification
  ]
  defstruct @enforce_keys ++ [:acceptance_criteria, :context_packet]

  def new(objective, workspace_root, opts \\ [])

  def new(objective, workspace_root, opts) when is_binary(objective) do
    objective = String.trim(objective)
    classification = TaskClassifier.classify(objective, workspace_root)
    kind = Keyword.get(opts, :kind, kind(classification))

    with true <- objective != "",
         true <- kind in @kinds do
      {:ok,
       %__MODULE__{
         id: new_id(),
         version: @version,
         objective: objective,
         kind: kind,
         worker_kind: worker_kind(kind),
         expected_artifact: expected_artifact(kind),
         verification_required: kind in [:implementation, :debugging, :verification],
         acceptance_criteria:
           Keyword.get(opts, :acceptance_criteria, "Satisfy the complete user request"),
         context_packet: Keyword.get(opts, :context_packet, %{}),
         classification: classification
       }}
    else
      false -> {:error, :invalid_work_contract}
    end
  end

  def new(_objective, _workspace_root, _opts), do: {:error, :invalid_work_contract}

  def to_map(%__MODULE__{} = contract) do
    contract
    |> Map.from_struct()
    |> Map.update!(:classification, &stringify/1)
  end

  def prompt(%__MODULE__{} = contract) do
    """
    # Runtime work contract
    Contract: #{contract.id} v#{contract.version}
    Work kind: #{contract.kind}
    Worker kind: #{contract.worker_kind}
    Expected artifact: #{contract.expected_artifact}
    Acceptance: #{contract.acceptance_criteria}

    The OTP Goal process owns coordination and completion. For this turn you are
    the primary #{contract.worker_kind}, not the goal coordinator. Produce the
    expected artifact directly with the granted tools. Preserve the complete
    objective and report only evidence produced by this run.

    Runtime project context:
    #{JSON.encode!(contract.context_packet)}
    """
    |> String.trim()
  end

  defp kind(%{change_intent: true}), do: :implementation
  defp kind(%{task_type: task_type}), do: kind(task_type)
  defp kind(:implementation), do: :implementation
  defp kind(:debugging), do: :debugging
  defp kind(:verification), do: :verification
  defp kind(:architecture), do: :investigation
  defp kind(_), do: :general

  defp worker_kind(:implementation), do: :implementer
  defp worker_kind(:debugging), do: :implementer
  defp worker_kind(:verification), do: :verifier
  defp worker_kind(:investigation), do: :investigator
  defp worker_kind(:general), do: :generalist

  defp expected_artifact(:implementation), do: :workspace_patch
  defp expected_artifact(:debugging), do: :workspace_patch
  defp expected_artifact(:verification), do: :verification_report
  defp expected_artifact(:investigation), do: :evidence_report
  defp expected_artifact(:general), do: :answer

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(value) when is_atom(value), do: to_string(value)
  defp stringify(value), do: value

  defp new_id do
    "work-" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end
end
