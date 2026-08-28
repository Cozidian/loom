defmodule BeamAgent.Auth.DeviceAdapter do
  @moduledoc "Provider adapter contract for OAuth device authorization."

  @callback authorize(map()) ::
              {:ok, %{public: map(), poll_state: term(), poll_after_ms: pos_integer()}}
              | {:error, term()}
  @callback poll(term()) ::
              {:pending, term(), pos_integer()}
              | {:ok, map()}
              | {:error, term()}
end
