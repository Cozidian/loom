defmodule BeamAgent.WorkerResult do
  @moduledoc "Recorded result returned through a delegation boundary."

  @enforce_keys [:worker_id, :delegation_id, :status, :content, :completed_at]
  defstruct @enforce_keys ++ [:verification]

  def new(worker_id, delegation_id, status, content, verification \\ %{status: :unverified}) do
    %__MODULE__{
      worker_id: worker_id,
      delegation_id: delegation_id,
      status: status,
      content: content,
      verification: verification,
      completed_at: DateTime.utc_now()
    }
  end
end
