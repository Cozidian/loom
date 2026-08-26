defmodule BeamAgent.AgentStrategy do
  @moduledoc "Replaceable strategy boundary for an agent's turn-driving loop."

  @callback run(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
end
