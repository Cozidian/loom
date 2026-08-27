defmodule BeamAgent.ModelError do
  @moduledoc "Normalized failure from a model invocation while retaining the internal cause."

  @enforce_keys [:request_id, :provider, :code, :retryable, :cause]
  defstruct [:request_id, :endpoint_id, :provider, :code, :retryable, :cause]

  def normalize(request, cause) do
    %__MODULE__{
      request_id: request.request_id,
      endpoint_id: request.endpoint_id,
      provider: request.provider,
      code: code(cause),
      retryable: retryable?(cause),
      cause: cause
    }
  end

  defp code({code, _rest}) when is_atom(code), do: code
  defp code({code, _one, _two}) when is_atom(code), do: code
  defp code(code) when is_atom(code), do: code
  defp code(_cause), do: :model_error

  defp retryable?(:model_timeout), do: true

  defp retryable?({:provider_http_error, status, _body}) when status == 429 or status >= 500,
    do: true

  defp retryable?({:provider_transport_error, _reason}), do: true
  defp retryable?(_cause), do: false
end
