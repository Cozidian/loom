defmodule BeamAgent.Providers.OpenAICompatible do
  @moduledoc false

  alias BeamAgent.Providers.Support

  def complete(messages, tools, options) do
    with {:ok, model} <- Support.require_option(options, :model),
         {:ok, base_url} <- Support.require_option(options, :base_url),
         {:ok, headers} <- headers(options),
         body <- request_body(model, messages, tools),
         client <- Support.http_client(options),
         {:ok, status, response} <-
           client.post_json(
             Support.endpoint(base_url, "/chat/completions"),
             headers,
             body,
             options
           ),
         {:ok, response} <- Support.accept(status, response) do
      parse_response(response)
    end
  end

  defp headers(options) do
    case Keyword.get(options, :auth, :bearer) do
      :none ->
        {:ok, [{"content-type", "application/json"}]}

      :bearer ->
        with {:ok, key} <- Support.api_key(options, Keyword.fetch!(options, :default_api_key_env)) do
          {:ok,
           [
             {"content-type", "application/json"},
             {"authorization", "Bearer " <> key}
           ]}
        end
    end
  end

  defp request_body(model, messages, tools) do
    %{
      "model" => model,
      "messages" => Enum.map(messages, &message/1),
      "tools" => Enum.map(tools, &Support.tool_schema/1),
      "stream" => false
    }
  end

  defp message(%{role: :user, content: content}) do
    %{"role" => "user", "content" => content}
  end

  defp message(%{role: :assistant} = message) do
    calls = Map.get(message, :tool_calls, [])

    %{"role" => "assistant", "content" => Map.get(message, :content)}
    |> maybe_put_tool_calls(calls)
  end

  defp message(%{role: :tool} = message) do
    %{
      "role" => "tool",
      "tool_call_id" => message.tool_call_id,
      "content" => message.content
    }
  end

  defp maybe_put_tool_calls(message, []), do: message

  defp maybe_put_tool_calls(message, calls) do
    Map.put(message, "tool_calls", Enum.map(calls, &tool_call/1))
  end

  defp tool_call(call) do
    %{
      "id" => call.id,
      "type" => "function",
      "function" => %{
        "name" => call.name,
        "arguments" => JSON.encode!(call.arguments)
      }
    }
  end

  defp parse_response(%{"choices" => [%{"message" => message} | _]}) do
    with {:ok, calls} <- parse_tool_calls(message["tool_calls"] || []) do
      {:ok, %{content: normalize_content(message["content"]), tool_calls: calls}}
    end
  end

  defp parse_response(response), do: {:error, {:invalid_provider_response, response}}

  defp parse_tool_calls(calls) when is_list(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, acc} ->
      function = call["function"] || %{}

      with name when is_binary(name) <- function["name"],
           {:ok, arguments} <- parse_arguments(function["arguments"]) do
        parsed = %{
          id: call["id"] || Support.call_id(),
          name: name,
          arguments: arguments
        }

        {:cont, {:ok, acc ++ [parsed]}}
      else
        other -> {:halt, {:error, {:invalid_tool_call_response, other}}}
      end
    end)
  end

  defp parse_tool_calls(other), do: {:error, {:invalid_tool_calls, other}}

  defp parse_arguments(arguments) when is_map(arguments), do: {:ok, arguments}
  defp parse_arguments(nil), do: {:ok, %{}}
  defp parse_arguments(""), do: {:ok, %{}}

  defp parse_arguments(arguments) when is_binary(arguments) do
    case JSON.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, {:invalid_tool_arguments, arguments}}
    end
  end

  defp parse_arguments(other), do: {:error, {:invalid_tool_arguments, other}}

  defp normalize_content(content) when is_binary(content), do: content
  defp normalize_content(nil), do: nil
  defp normalize_content(other), do: inspect(other)
end
