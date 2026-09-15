defmodule BeamAgent.Sandbox.Backend do
  @moduledoc """
  Enforcing command-confinement backend selected by the host, not by a model.

  A backend either wraps a shell invocation so the OS kernel enforces the
  workspace-write policy, or it reports that it cannot. There is no passthrough
  fallback: missing backends fail closed.
  """

  @type invocation :: %{executable: String.t(), argv: [String.t()]}

  @callback id() :: String.t()
  @callback available?() :: boolean()
  @callback wrap(String.t(), String.t(), keyword()) :: {:ok, invocation()} | {:error, term()}
end
