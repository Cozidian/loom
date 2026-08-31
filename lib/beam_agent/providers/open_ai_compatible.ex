defmodule BeamAgent.Providers.OpenAICompatible do
  @moduledoc false

  alias BeamAgent.Providers.Support
  alias BeamAgent.Stream.SSEDecoder

  def complete(messages, tools, options) do
    with {:ok, model} <- Support.require_option(options, :model),
         {:ok, base_url} <- Support.require_option(options, :base_url),
         {:ok, headers} <- headers(options),
         body <- request_body(model, messages, tools, options, false),
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

  def stream(messages, tools, options, emit) do
    with {:ok, model} <- Support.require_option(options, :model),
         {:ok, base_url} <- Support.require_option(options, :base_url),
         {:ok, headers} <- headers(options),
         body <- request_body(model, messages, tools, options, true),
         client <- Support.http_client(options),
         :ok <- ensure_streaming_client(client),
         initial <- %{decoder: SSEDecoder.new(), content: [], calls: %{}, usage: nil},
         result <-
           client.post_json_stream(
             Support.endpoint(base_url, "/chat/completions"),
             headers,
             body,
             options,
             initial,
             &consume_stream_chunk(&1, &2, emit)
           ) do
      finish_stream(result, emit)
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

  defp request_body(model, messages, tools, options, streaming) do
    %{
      "model" => model,
      "messages" => format_messages(messages, options),
      "tools" => Enum.map(tools, &Support.tool_schema/1),
      "stream" => streaming
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

  defp message(%{role: :user, content: content} = message) do
    attachments = Map.get(message, :attachments, [])

    if attachments == [] do
      %{"role" => "user", "content" => content}
    else
      text =
        if is_binary(content) and content != "",
          do: [%{"type" => "text", "text" => content}],
          else: []

      images =
        Enum.map(attachments, fn attachment ->
          %{
            "type" => "image_url",
            "image_url" => %{
              "url" => "data:#{attachment.mime_type};base64,#{attachment.data}",
              "detail" => "auto"
            }
          }
        end)

      %{"role" => "user", "content" => text ++ images}
    end
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

  defp ensure_streaming_client(client) do
    if Code.ensure_loaded?(client) and function_exported?(client, :post_json_stream, 6),
      do: :ok,
      else: {:error, {:streaming_not_supported, client}}
  end

  defp consume_stream_chunk(chunk, state, emit) do
    {frames, decoder} = SSEDecoder.feed(state.decoder, chunk)

    with {:ok, state} <- consume_frames(frames, %{state | decoder: decoder}, emit) do
      {:ok, state}
    end
  end

  defp consume_frames(frames, state, emit) do
    Enum.reduce_while(frames, {:ok, state}, fn frame, {:ok, acc} ->
      case consume_frame(frame, acc, emit) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp consume_frame(%{data: ""}, state, _emit), do: {:ok, state}
  defp consume_frame(%{data: "[DONE]"}, state, _emit), do: {:ok, state}

  defp consume_frame(%{data: data}, state, emit) do
    case JSON.decode(data) do
      {:ok, %{"error" => error}} ->
        {:error, {:provider_stream_error, error}}

      {:ok, payload} when is_map(payload) ->
        consume_payload(payload, state, emit)

      {:ok, other} ->
        {:error, {:invalid_stream_event, other}}

      {:error, reason} ->
        {:error, {:invalid_stream_json, reason, data}}
    end
  end

  defp consume_payload(payload, state, emit) do
    state =
      case payload["usage"] do
        usage when is_map(usage) ->
          emit.({:usage, usage})
          %{state | usage: usage}

        _ ->
          state
      end

    payload
    |> Map.get("choices", [])
    |> Enum.reduce_while({:ok, state}, fn choice, {:ok, acc} ->
      delta = choice["delta"] || %{}

      with {:ok, acc} <- consume_text_delta(delta["content"], acc, emit),
           {:ok, acc} <- consume_tool_deltas(delta["tool_calls"] || [], acc, emit) do
        {:cont, {:ok, acc}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp consume_text_delta(delta, state, emit) when is_binary(delta) do
    emit.({:text_delta, delta})
    {:ok, %{state | content: state.content ++ [delta]}}
  end

  defp consume_text_delta(nil, state, _emit), do: {:ok, state}

  defp consume_text_delta(other, _state, _emit),
    do: {:error, {:invalid_text_delta, other}}

  defp consume_tool_deltas(deltas, state, emit) when is_list(deltas) do
    Enum.reduce_while(deltas, {:ok, state}, fn delta, {:ok, acc} ->
      index = delta["index"] || 0
      function = delta["function"] || %{}
      existing = Map.get(acc.calls, index, %{id: nil, name: "", arguments: ""})

      call = %{
        id: delta["id"] || existing.id,
        name: existing.name <> (function["name"] || ""),
        arguments: existing.arguments <> (function["arguments"] || "")
      }

      emit.({:tool_call_delta, Map.put(delta, "index", index)})
      {:cont, {:ok, %{acc | calls: Map.put(acc.calls, index, call)}}}
    end)
  end

  defp consume_tool_deltas(other, _state, _emit),
    do: {:error, {:invalid_tool_call_delta, other}}

  defp finish_stream({:ok, status, :streamed, state}, emit) when status in 200..299 do
    {frames, _decoder} = SSEDecoder.finish(state.decoder)

    with {:ok, state} <- consume_frames(frames, %{state | decoder: ""}, emit),
         {:ok, calls} <- finalize_stream_calls(state.calls) do
      content = state.content |> IO.iodata_to_binary() |> empty_to_nil()
      {:ok, %{content: content, tool_calls: calls}}
    end
  end

  defp finish_stream({:ok, status, response}, _emit) do
    with {:ok, response} <- Support.accept(status, response), do: parse_response(response)
  end

  defp finish_stream({:error, reason}, _emit), do: {:error, reason}

  defp finalize_stream_calls(calls) do
    calls
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {_index, call}, {:ok, acc} ->
      with true <- call.name != "",
           {:ok, arguments} <- parse_arguments(call.arguments) do
        parsed = %{id: call.id || Support.call_id(), name: call.name, arguments: arguments}
        {:cont, {:ok, acc ++ [parsed]}}
      else
        false -> {:halt, {:error, {:invalid_tool_call_response, call}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(content), do: content
end
