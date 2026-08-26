defmodule BeamAgent.LLMProvider do
  @moduledoc """
  Replaceable boundary for model providers.

  Providers are intentionally ordinary modules. Long-lived connections should be
  separate supervised processes and can be discovered through `BeamAgent.Registry`.
  """

  @type message :: %{
          required(:role) => :user | :assistant | :tool,
          optional(:content) => String.t() | nil,
          optional(:tool_calls) => [map()],
          optional(:tool_call_id) => String.t(),
          optional(:name) => String.t()
        }

  @type response :: %{
          required(:content) => String.t() | nil,
          required(:tool_calls) => [map()]
        }

  @callback id() :: atom()
  @callback complete([message()], [map()], keyword()) :: {:ok, response()} | {:error, term()}
end
