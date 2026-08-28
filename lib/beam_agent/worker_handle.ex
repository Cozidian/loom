defmodule BeamAgent.WorkerHandle do
  @moduledoc "Structured runtime handle for a dynamically constructed worker."

  @enforce_keys [
    :worker_id,
    :goal_id,
    :parent_worker_id,
    :spec_id,
    :role,
    :template,
    :delegation_id,
    :budget_allocation_id
  ]
  defstruct @enforce_keys

  def from_spec(worker_id, goal_id, spec, delegation_id) do
    %__MODULE__{
      worker_id: worker_id,
      goal_id: goal_id,
      parent_worker_id: spec.parent.worker_id,
      spec_id: spec.spec_id,
      role: spec.role,
      template: %{id: spec.template, version: spec.template_version, source: spec.template_source},
      delegation_id: delegation_id,
      budget_allocation_id: spec.resources.allocation_id
    }
  end
end
