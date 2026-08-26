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
          required(:provider_profile) => String.t() | nil,
          required(:provider_options) => keyword(),
          required(:strategy) => module(),
          required(:max_steps) => pos_integer(),
          required(:data_dir) => String.t(),
          required(:workspace_root) => String.t(),
          required(:approval_policy) => :ask | :allow | :deny,
          required(:approval_handler) => pid() | nil
        }

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback input_schema() :: map()
  @callback access() :: :trusted | :read | :write | :execute | :delegate
  @callback execute(map(), context()) :: {:ok, term()} | {:error, term()}

  @optional_callbacks access: 0
end
