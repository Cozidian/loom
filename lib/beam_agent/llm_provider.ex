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
          optional(:attachments) => [map()],
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
  @callback routing_preflight(keyword()) :: :ok | {:ok, String.t()} | {:error, term()}

  @doc """
  An optional, doctor-only diagnostic distinct from `healthcheck/1`: a non-nil
  string names a real limitation of the configured model/endpoint (for
  example, a local model whose chat template does not support native tool
  calling) worth surfacing before a session starts. It is not part of the
  routing preflight and must not be invoked on a per-request hot path.
  """
  @callback tool_support_notice(keyword()) :: String.t() | nil

  @optional_callbacks configuration: 0,
                      healthcheck: 1,
                      routing_preflight: 1,
                      stream: 4,
                      tool_support_notice: 1
end
