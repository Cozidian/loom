defmodule BeamAgent.Auth.TokenRefresher do
  @moduledoc false

  @callback refresh(map()) :: {:ok, map()} | {:error, term()}
end
