defmodule BeamAgent.ModelRequest do
  @moduledoc "Versioned request contract for one provider-independent model invocation."

  @version 1

  @enforce_keys [
    :request_id,
    :provider,
    :provider_module,
    :messages,
    :tools,
    :stream,
    :timeout,
    :options,
    :metadata
  ]
  defstruct [
    :version,
    :request_id,
    :endpoint_id,
    :provider,
    :provider_module,
    :model,
    :messages,
    :tools,
    :stream,
    :timeout,
    :cancellation,
    :options,
    :metadata
  ]

  def new(opts) when is_list(opts) do
    timeout = Keyword.get(opts, :timeout, :infinity)

    with :ok <- validate_timeout(timeout) do
      provider_module = Keyword.fetch!(opts, :provider_module)

      {:ok,
       %__MODULE__{
         version: @version,
         request_id: Keyword.get_lazy(opts, :request_id, &new_id/0),
         endpoint_id: Keyword.get(opts, :endpoint_id),
         provider: Keyword.fetch!(opts, :provider),
         provider_module: provider_module,
         model: Keyword.get(opts, :model),
         messages: Keyword.fetch!(opts, :messages),
         tools: Keyword.get(opts, :tools, []),
         stream:
           Keyword.get_lazy(opts, :stream, fn ->
             Code.ensure_loaded?(provider_module) and
               function_exported?(provider_module, :stream, 4)
           end),
         timeout: timeout,
         cancellation: :owner_process,
         options: Keyword.get(opts, :options, []),
         metadata: Keyword.get(opts, :metadata, %{})
       }}
    end
  end

  defp validate_timeout(:infinity), do: :ok
  defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0, do: :ok
  defp validate_timeout(timeout), do: {:error, {:invalid_model_timeout, timeout}}

  defp new_id do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    "model-request-#{suffix}"
  end
end
