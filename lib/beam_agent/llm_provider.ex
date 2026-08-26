defmodule BeamAgent.LLMProvider do
  @moduledoc """
  Replaceable boundary for model providers.

  Providers are intentionally ordinary modules. Long-lived connections should be
  separate supervised processes and can be discovered through `BeamAgent.Registry`.
  Real model adapters must carry the `:system_prompt` provider option through the
  protocol's native system-instruction channel.
  """

  @type message :: %{
          required(:role) => :user | :assistant | :tool,
          optional(:content) => String.t() | nil,
          optional(:tool_calls) => [map()],
          optional(:tool_call_id) => String.t(),
          optional(:name) => String.t(),
          optional(:is_error) => boolean(),
          optional(:error) => map() | nil
        }

  @type response :: %{
          required(:content) => String.t() | nil,
          required(:tool_calls) => [map()]
        }

  @type stream_event ::
          {:text_delta, String.t()} | {:tool_call_delta, map()} | {:usage, map()}

  @callback id() :: atom()
  @callback complete([message()], [map()], keyword()) :: {:ok, response()} | {:error, term()}

  @callback stream([message()], [map()], keyword(), (stream_event() -> any())) ::
              {:ok, response()} | {:error, term()}
  @callback configuration() :: map()
  @callback healthcheck(keyword()) :: :ok | {:ok, String.t()} | {:error, term()}

  @optional_callbacks configuration: 0, healthcheck: 1, stream: 4
end
