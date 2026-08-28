defmodule BeamAgent.Auth.Keyring do
  @moduledoc "Backend contract for storing provider credentials outside BeamAgent configuration."

  @callback init(keyword()) :: {:ok, term()} | {:error, term()}
  @callback put(binary(), binary(), term()) :: {:ok, term()} | {:error, term()}
  @callback fetch(binary(), term()) :: {{:ok, binary()} | {:error, term()}, term()}
  @callback delete(binary(), term()) :: {:ok, term()} | {:error, term()}
end
