defmodule BeamAgent.Tool do
  @moduledoc """
  Behaviour for stateless model-callable tools.

  A tool module may call session-owned resource processes through the explicit
  execution context, but the module itself owns no mutable lifecycle.
  """

  @type context :: %{
          required(:session_id) => String.t(),
          required(:parent_session_id) => String.t() | nil,
          required(:provider) => atom(),
          required(:provider_options) => keyword(),
          required(:strategy) => module(),
          required(:max_steps) => pos_integer(),
          required(:data_dir) => String.t()
        }

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback input_schema() :: map()
  @callback execute(map(), context()) :: {:ok, term()} | {:error, term()}
end
