defmodule BeamAgent.Providers.Ollama do
  @moduledoc "Native Ollama `/api/chat` provider with tool calling."
  @behaviour BeamAgent.LLMProvider

  alias BeamAgent.Providers.Support

  @impl true
  def id, do: :ollama

  @impl true
  def configuration do
    %{
      name: "ollama",
      label: "Ollama (local)",
      model_required: true,
      default_model: "llama3.2",
      default_base_url: "http://127.0.0.1:11434"
    }
  end

  @impl true
  def complete(messages, tools, options) do
    options =
      options
      |> Keyword.put_new(:model, configuration().default_model)
      |> Keyword.put_new(:base_url, configuration().default_base_url)

    with {:ok, model} <- Support.require_option(options, :model),
         {:ok, base_url} <- Support.require_option(options, :base_url),
         body <- %{
           "model" => model,
           "messages" => format_messages(messages, options),
           "tools" => Enum.map(tools, &Support.tool_schema/1),
           "stream" => false
         },
         client <- Support.http_client(options),
         {:ok, status, response} <-
           client.post_json(
             Support.endpoint(base_url, "/api/chat"),
             [{"content-type", "application/json"}],
             body,
             options
           ),
         {:ok, response} <- Support.accept(status, response) do
      parse_response(response)
    end
  end

  @impl true
  def healthcheck(options) do
    options =
      options
      |> Keyword.put_new(:model, configuration().default_model)
      |> Keyword.put_new(:base_url, configuration().default_base_url)

    with {:ok, model} <- Support.require_option(options, :model),
         {:ok, base_url} <- Support.require_option(options, :base_url),
         client <- Support.http_client(options),
         {:ok, status, response} <-
           client.get_json(
             Support.endpoint(base_url, "/api/tags"),
             [{"accept", "application/json"}],
             options
           ),
         {:ok, response} <- Support.accept(status, response),
         :ok <- ensure_model_present(model, response) do
      {:ok, "connected; model #{model} is installed"}
    end
  end

  defp message(%{role: :user, content: content}),
    do: %{"role" => "user", "content" => content}

  defp message(%{role: :assistant} = message) do
    calls = Map.get(message, :tool_calls, [])

    %{"role" => "assistant", "content" => Map.get(message, :content) || ""}
    |> maybe_put_tool_calls(calls)
  end

  defp message(%{role: :tool} = message) do
    %{
      "role" => "tool",
      "tool_name" => message.name,
      "content" => message.content
    }
  end

  defp format_messages(messages, options) do
    formatted = Enum.map(messages, &message/1)

    case Keyword.get(options, :system_prompt) do
      prompt when is_binary(prompt) and prompt != "" ->
        [%{"role" => "system", "content" => prompt} | formatted]

      _ ->
        formatted
    end
  end

  defp maybe_put_tool_calls(message, []), do: message

  defp maybe_put_tool_calls(message, calls) do
    formatted =
      Enum.with_index(calls)
      |> Enum.map(fn {call, index} ->
        %{
          "type" => "function",
          "function" => %{
            "index" => index,
            "name" => call.name,
            "arguments" => call.arguments
          }
        }
      end)

    Map.put(message, "tool_calls", formatted)
  end

  defp parse_response(%{"message" => message}) do
    calls =
      Enum.map(message["tool_calls"] || [], fn call ->
        function = call["function"] || %{}

        %{
          id: call["id"] || Support.call_id(),
          name: function["name"],
          arguments: function["arguments"] || %{}
        }
      end)

    if Enum.all?(calls, &(is_binary(&1.name) and is_map(&1.arguments))) do
      {:ok, %{content: normalize_content(message["content"]), tool_calls: calls}}
    else
      {:error, {:invalid_provider_response, message}}
    end
  end

  defp parse_response(response), do: {:error, {:invalid_provider_response, response}}

  defp ensure_model_present(model, %{"models" => models}) when is_list(models) do
    names = Enum.map(models, & &1["name"])

    if Enum.any?(names, &same_model?(&1, model)) do
      :ok
    else
      {:error, {:ollama_model_not_found, model, Enum.reject(names, &is_nil/1)}}
    end
  end

  defp ensure_model_present(_model, response),
    do: {:error, {:invalid_provider_response, response}}

  defp same_model?(name, model) when is_binary(name) do
    name == model or name == model <> ":latest" or name <> ":latest" == model
  end

  defp same_model?(_name, _model), do: false

  defp normalize_content(content) when is_binary(content), do: content
  defp normalize_content(nil), do: nil
  defp normalize_content(other), do: inspect(other)
end
