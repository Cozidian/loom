defmodule BeamAgent.Providers.Ollama do
  @moduledoc "Native Ollama `/api/chat` provider with tool calling."
  @behaviour BeamAgent.LLMProvider

  alias BeamAgent.Providers.Support
  alias BeamAgent.Stream.NDJSONDecoder

  @impl true
  def id, do: :ollama

  @impl true
  def configuration do
    %{
      name: "ollama",
      label: "Ollama (local)",
      capabilities: [:text_generation, :tool_use, :streaming],
      modalities: [:text],
      locality: :local,
      privacy: :local,
      cost_hint: :free,
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
  def stream(messages, tools, options, emit) do
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
           "stream" => true
         },
         client <- Support.http_client(options),
         :ok <- ensure_streaming_client(client),
         initial <- %{decoder: NDJSONDecoder.new(), content: [], tool_calls: [], done: false},
         result <-
           client.post_json_stream(
             Support.endpoint(base_url, "/api/chat"),
             [{"content-type", "application/json"}],
             body,
             options,
             initial,
             &consume_stream_chunk(&1, &2, emit)
           ) do
      finish_stream(result, emit)
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

  defp message(%{role: :user, content: content} = message) do
    images = Enum.map(Map.get(message, :attachments, []), & &1.data)

    %{"role" => "user", "content" => content}
    |> then(fn formatted ->
      if images == [], do: formatted, else: Map.put(formatted, "images", images)
    end)
  end

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

  defp ensure_streaming_client(client) do
    if Code.ensure_loaded?(client) and function_exported?(client, :post_json_stream, 6),
      do: :ok,
      else: {:error, {:streaming_not_supported, client}}
  end

  defp consume_stream_chunk(chunk, state, emit) do
    {lines, decoder} = NDJSONDecoder.feed(state.decoder, chunk)

    with {:ok, state} <- consume_lines(lines, %{state | decoder: decoder}, emit) do
      {:ok, state}
    end
  end

  defp consume_lines(lines, state, emit) do
    Enum.reduce_while(lines, {:ok, state}, fn line, {:ok, acc} ->
      case JSON.decode(line) do
        {:ok, payload} when is_map(payload) ->
          case consume_payload(payload, acc, emit) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:ok, other} ->
          {:halt, {:error, {:invalid_stream_event, other}}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_stream_json, reason, line}}}
      end
    end)
  end

  defp consume_payload(%{"error" => error}, _state, _emit),
    do: {:error, {:provider_stream_error, error}}

  defp consume_payload(payload, state, emit) do
    message = payload["message"] || %{}

    state =
      case message["content"] do
        delta when is_binary(delta) and delta != "" ->
          emit.({:text_delta, delta})
          %{state | content: state.content ++ [delta]}

        _ ->
          state
      end

    state =
      case message["tool_calls"] do
        calls when is_list(calls) and calls != [] ->
          Enum.each(calls, &emit.({:tool_call_delta, &1}))
          %{state | tool_calls: calls}

        _ ->
          state
      end

    if payload["done"] do
      usage =
        Map.take(payload, [
          "total_duration",
          "load_duration",
          "prompt_eval_count",
          "prompt_eval_duration",
          "eval_count",
          "eval_duration"
        ])

      if usage != %{}, do: emit.({:usage, usage})
      {:ok, %{state | done: true}}
    else
      {:ok, state}
    end
  end

  defp finish_stream({:ok, status, :streamed, state}, emit) when status in 200..299 do
    {lines, _decoder} = NDJSONDecoder.finish(state.decoder)

    with {:ok, state} <- consume_lines(lines, %{state | decoder: ""}, emit) do
      parse_response(%{
        "done" => state.done,
        "message" => %{
          "content" => IO.iodata_to_binary(state.content),
          "tool_calls" => state.tool_calls
        }
      })
    end
  end

  defp finish_stream({:ok, status, response}, _emit) do
    with {:ok, response} <- Support.accept(status, response), do: parse_response(response)
  end

  defp finish_stream({:error, reason}, _emit), do: {:error, reason}
end
