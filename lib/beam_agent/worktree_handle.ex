defmodule BeamAgent.WorktreeHandle do
  @moduledoc "Opaque ownership record for an isolated Git worktree."
  @enforce_keys [:id, :project_id, :owner_worker_id, :path, :base_revision, :status]
  defstruct @enforce_keys ++ [:purpose_fingerprint, :created_at]
end
