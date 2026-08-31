defmodule BeamAgent.ExecutionStrategy do
  @moduledoc """
  Versioned, interface-neutral execution strategy metadata.

  Strategies describe how work should be coordinated; they are not agent
  identities and do not grant authority or resources.
  """

  @enforce_keys [:id, :version, :mode, :maximum_attempts, :maximum_parallelism]
  defstruct [:id, :version, :mode, :maximum_attempts, :maximum_parallelism, :review_required]

  @strategies %{
    "focused" => %{mode: :sequential, maximum_attempts: 1, maximum_parallelism: 1},
    "investigate" => %{mode: :investigator, maximum_attempts: 2, maximum_parallelism: 2},
    "implement" => %{mode: :sequential, maximum_attempts: 2, maximum_parallelism: 1},
    "review" => %{
      mode: :reviewer,
      maximum_attempts: 1,
      maximum_parallelism: 1,
      review_required: true
    },
    "verify" => %{mode: :deterministic, maximum_attempts: 1, maximum_parallelism: 1},
    "coordinate" => %{mode: :coordinator, maximum_attempts: 2, maximum_parallelism: 2}
  }

  def resolve(id) when is_binary(id) do
    attributes = Map.get(@strategies, id, Map.fetch!(@strategies, "focused"))

    struct!(__MODULE__,
      id: id,
      version: 1,
      mode: attributes.mode,
      maximum_attempts: attributes.maximum_attempts,
      maximum_parallelism: attributes.maximum_parallelism,
      review_required: Map.get(attributes, :review_required, false)
    )
  end

  def resolve(_id), do: resolve("focused")

  def to_map(%__MODULE__{} = strategy), do: Map.from_struct(strategy)
end
