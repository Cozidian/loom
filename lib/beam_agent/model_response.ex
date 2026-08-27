defmodule BeamAgent.ModelResponse do
  @moduledoc "Normalized successful result from a model invocation."

  alias BeamAgent.ModelUsage

  @enforce_keys [:request_id, :content, :tool_calls, :usage]
  defstruct [:request_id, :content, :tool_calls, :usage, :provider_response]

  def normalize(request_id, response) when is_map(response) do
    content = response[:content] || response["content"]
    tool_calls = response[:tool_calls] || response["tool_calls"] || []
    usage = response[:usage] || response["usage"] || %{}

    if (is_binary(content) or is_nil(content)) and is_list(tool_calls) do
      {:ok,
       %__MODULE__{
         request_id: request_id,
         content: content,
         tool_calls: tool_calls,
         usage: ModelUsage.normalize(usage),
         provider_response: response
       }}
    else
      {:error, {:invalid_provider_response, response}}
    end
  end

  def normalize(_request_id, response), do: {:error, {:invalid_provider_response, response}}
end
