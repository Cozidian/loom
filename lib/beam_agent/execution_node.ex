defmodule BeamAgent.ExecutionNode do
  @moduledoc "Trust and compatibility descriptor for a local or remote BEAM execution node."
  @enforce_keys [:id, :node, :trust, :code_version, :capabilities, :data_locality, :status]
  defstruct @enforce_keys ++ [:last_heartbeat_at]
end
