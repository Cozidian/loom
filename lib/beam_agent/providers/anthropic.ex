defmodule BeamAgent.Providers.Anthropic do
  @moduledoc "Native Anthropic Messages API provider with tool-use content blocks."
  @behaviour BeamAgent.LLMProvider

  alias BeamAgent.Providers.Support
  alias BeamAgent.Stream.SSEDecoder

  @impl true
  def id, do: :anthropic

  @impl true
  def configuration do
    %{
      name: "anthropic",
      label: "Anthropic Claude",
      capabilities: [:text_generation, :tool_use, :streaming],
      modalities: [:text],
      locality: :remote,
      privacy: :provider,
      cost_hint: :metered,
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
         body <- request_body(model, messages, tools, options, false),
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
  def stream(messages, tools, options, emit) do
    options = Keyword.put_new(options, :base_url, configuration().default_base_url)

    with {:ok, model} <- Support.require_option(options, :model),
         {:ok, base_url} <- Support.require_option(options, :base_url),
         {:ok, api_key} <- Support.api_key(options, configuration().default_api_key_env),
         body <- request_body(model, messages, tools, options, true),
         headers <- [
           {"content-type", "application/json"},
           {"x-api-key", api_key},
           {"anthropic-version", "2023-06-01"}
         ],
         client <- Support.http_client(options),
         :ok <- ensure_streaming_client(client),
         initial <- %{decoder: SSEDecoder.new(), blocks: %{}, stop_reason: nil, usage: %{}},
         result <-
           client.post_json_stream(
             Support.endpoint(base_url, "/v1/messages"),
             headers,
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
    options = Keyword.put_new(options, :base_url, configuration().default_base_url)

    with {:ok, _model} <- Support.require_option(options, :model),
         {:ok, _base_url} <- Support.require_option(options, :base_url),
         {:ok, _key} <- Support.api_key(options, configuration().default_api_key_env) do
      {:ok, "credentials configured; connectivity is checked on the first request"}
    end
  end

  defp request_body(model, messages, tools, options, streaming) do
    body = %{
      "model" => model,
      "max_tokens" => Keyword.get(options, :max_tokens, 4_096),
      "messages" => format_messages(messages),
      "tools" => Enum.map(tools, &tool_schema/1),
      "stream" => streaming
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

  defp consume_frame(%{event: frame_event, data: data}, state, emit) do
    case JSON.decode(data) do
      {:ok, payload} when is_map(payload) ->
        consume_event(frame_event || payload["type"], payload, state, emit)

      {:ok, other} ->
        {:error, {:invalid_stream_event, other}}

      {:error, reason} ->
        {:error, {:invalid_stream_json, reason, data}}
    end
  end

  defp consume_event("ping", _payload, state, _emit), do: {:ok, state}
  defp consume_event("message_stop", _payload, state, _emit), do: {:ok, state}

  defp consume_event("message_start", payload, state, emit) do
    usage = get_in(payload, ["message", "usage"]) || %{}
    maybe_emit_usage(usage, emit)
    {:ok, %{state | usage: Map.merge(state.usage, usage)}}
  end

  defp consume_event("content_block_start", payload, state, emit) do
    index = payload["index"]
    block = payload["content_block"] || %{}

    case block["type"] do
      "text" ->
        text = block["text"] || ""
        if text != "", do: emit.({:text_delta, text})
        {:ok, put_in(state.blocks[index], %{type: :text, text: text})}

      "tool_use" ->
        tool = %{
          type: :tool_use,
          id: block["id"],
          name: block["name"],
          input: block["input"] || %{},
          input_json: ""
        }

        emit.({:tool_call_delta, %{"index" => index, "id" => tool.id, "name" => tool.name}})
        {:ok, put_in(state.blocks[index], tool)}

      other ->
        {:error, {:invalid_content_block, other}}
    end
  end

  defp consume_event("content_block_delta", payload, state, emit) do
    index = payload["index"]
    delta = payload["delta"] || %{}

    case {delta["type"], Map.get(state.blocks, index)} do
      {"text_delta", %{type: :text} = block} ->
        text = delta["text"] || ""
        if text != "", do: emit.({:text_delta, text})
        {:ok, put_in(state.blocks[index], %{block | text: block.text <> text})}

      {"input_json_delta", %{type: :tool_use} = block} ->
        fragment = delta["partial_json"] || ""
        emit.({:tool_call_delta, %{"index" => index, "arguments" => fragment}})
        {:ok, put_in(state.blocks[index], %{block | input_json: block.input_json <> fragment})}

      {type, block} ->
        {:error, {:invalid_content_block_delta, type, block}}
    end
  end

  defp consume_event("content_block_stop", _payload, state, _emit), do: {:ok, state}

  defp consume_event("message_delta", payload, state, emit) do
    usage = payload["usage"] || %{}
    maybe_emit_usage(usage, emit)

    {:ok,
     %{
       state
       | stop_reason: get_in(payload, ["delta", "stop_reason"]) || state.stop_reason,
         usage: Map.merge(state.usage, usage)
     }}
  end

  defp consume_event("error", payload, _state, _emit),
    do: {:error, {:provider_stream_error, payload["error"] || payload}}

  defp consume_event(event, payload, _state, _emit),
    do: {:error, {:unknown_provider_stream_event, event, payload}}

  defp finish_stream({:ok, status, :streamed, state}, emit) when status in 200..299 do
    {frames, _decoder} = SSEDecoder.finish(state.decoder)

    with {:ok, state} <- consume_frames(frames, %{state | decoder: ""}, emit),
         {:ok, blocks} <- finalize_blocks(state.blocks) do
      parse_response(%{"content" => blocks, "stop_reason" => state.stop_reason})
    end
  end

  defp finish_stream({:ok, status, response}, _emit) do
    with {:ok, response} <- Support.accept(status, response), do: parse_response(response)
  end

  defp finish_stream({:error, reason}, _emit), do: {:error, reason}

  defp finalize_blocks(blocks) do
    blocks
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn
      {_index, %{type: :text, text: text}}, {:ok, acc} ->
        {:cont, {:ok, acc ++ [%{"type" => "text", "text" => text}]}}

      {_index, %{type: :tool_use} = block}, {:ok, acc} ->
        with {:ok, input} <- finalize_input(block) do
          tool = %{
            "type" => "tool_use",
            "id" => block.id,
            "name" => block.name,
            "input" => input
          }

          {:cont, {:ok, acc ++ [tool]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  defp finalize_input(%{input_json: "", input: input}) when is_map(input), do: {:ok, input}

  defp finalize_input(%{input_json: json}) do
    case JSON.decode(json) do
      {:ok, input} when is_map(input) -> {:ok, input}
      _ -> {:error, {:invalid_tool_arguments, json}}
    end
  end

  defp maybe_emit_usage(usage, emit) when map_size(usage) > 0, do: emit.({:usage, usage})
  defp maybe_emit_usage(_usage, _emit), do: :ok
end
