defmodule BeamAgent.Providers.Anthropic do
  @moduledoc "Native Anthropic Messages API provider with tool-use content blocks."
  @behaviour BeamAgent.LLMProvider

  alias BeamAgent.Providers.Support

  @impl true
  def id, do: :anthropic

  @impl true
  def configuration do
    %{
      name: "anthropic",
      label: "Anthropic Claude",
      model_required: true,
      default_base_url: "https://api.anthropic.com",
      default_api_key_env: "ANTHROPIC_API_KEY"
    }
  end

  @impl true
  def complete(messages, tools, options) do
    options = Keyword.put_new(options, :base_url, configuration().default_base_url)

    with {:ok, model} <- Support.require_option(options, :model),
         {:ok, base_url} <- Support.require_option(options, :base_url),
         {:ok, api_key} <- Support.api_key(options, configuration().default_api_key_env),
         body <- request_body(model, messages, tools, options),
         headers <- [
           {"content-type", "application/json"},
           {"x-api-key", api_key},
           {"anthropic-version", "2023-06-01"}
         ],
         client <- Support.http_client(options),
         {:ok, status, response} <-
           client.post_json(
             Support.endpoint(base_url, "/v1/messages"),
             headers,
             body,
             options
           ),
         {:ok, response} <- Support.accept(status, response) do
      parse_response(response)
    end
  end

  @impl true
  def healthcheck(options) do
    options = Keyword.put_new(options, :base_url, configuration().default_base_url)

    with {:ok, _model} <- Support.require_option(options, :model),
         {:ok, _base_url} <- Support.require_option(options, :base_url),
         {:ok, _key} <- Support.api_key(options, configuration().default_api_key_env) do
      {:ok, "credentials configured; connectivity is checked on the first request"}
    end
  end

  defp request_body(model, messages, tools, options) do
    body = %{
      "model" => model,
      "max_tokens" => Keyword.get(options, :max_tokens, 4_096),
      "messages" => format_messages(messages),
      "tools" => Enum.map(tools, &tool_schema/1)
    }

    case Keyword.get(options, :system_prompt) do
      prompt when is_binary(prompt) and prompt != "" -> Map.put(body, "system", prompt)
      _ -> body
    end
  end

  defp tool_schema(tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "input_schema" => tool.input_schema
    }
  end

  defp format_messages(messages) do
    {formatted, _grouping_tools?} =
      Enum.reduce(messages, {[], false}, fn
        %{role: :user, content: content}, {acc, _grouping} ->
          {acc ++ [%{"role" => "user", "content" => content}], false}

        %{role: :assistant} = message, {acc, _grouping} ->
          blocks = assistant_blocks(message)
          {acc ++ [%{"role" => "assistant", "content" => blocks}], false}

        %{role: :tool} = message, {acc, true} ->
          {List.update_at(acc, -1, &append_tool_result(&1, message)), true}

        %{role: :tool} = message, {acc, false} ->
          result_message = %{"role" => "user", "content" => [tool_result(message)]}
          {acc ++ [result_message], true}
      end)

    formatted
  end

  defp assistant_blocks(message) do
    text =
      case Map.get(message, :content) do
        content when is_binary(content) and content != "" ->
          [%{"type" => "text", "text" => content}]

        _ ->
          []
      end

    calls =
      Enum.map(Map.get(message, :tool_calls, []), fn call ->
        %{
          "type" => "tool_use",
          "id" => call.id,
          "name" => call.name,
          "input" => call.arguments
        }
      end)

    text ++ calls
  end

  defp append_tool_result(message, tool_message) do
    Map.update!(message, "content", &(&1 ++ [tool_result(tool_message)]))
  end

  defp tool_result(message) do
    %{
      "type" => "tool_result",
      "tool_use_id" => message.tool_call_id,
      "content" => message.content,
      "is_error" => Map.get(message, :is_error, false)
    }
  end

  defp parse_response(%{"content" => blocks} = response) when is_list(blocks) do
    text =
      blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(& &1["text"])
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
      |> empty_to_nil()

    calls =
      blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(fn block ->
        %{id: block["id"], name: block["name"], arguments: block["input"] || %{}}
      end)

    cond do
      not Enum.all?(calls, &(is_binary(&1.id) and is_binary(&1.name) and is_map(&1.arguments))) ->
        {:error, {:invalid_provider_response, response}}

      response["stop_reason"] == "max_tokens" and calls == [] ->
        {:error, {:provider_incomplete, :max_tokens}}

      true ->
        {:ok, %{content: text, tool_calls: calls}}
    end
  end

  defp parse_response(response), do: {:error, {:invalid_provider_response, response}}

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(content), do: content
end
