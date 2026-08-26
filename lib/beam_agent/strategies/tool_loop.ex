defmodule BeamAgent.Strategies.ToolLoop do
  @moduledoc "Default sequential, bounded, multi-step model/tool strategy."
  @behaviour BeamAgent.AgentStrategy

  alias BeamAgent.{CapabilityCatalog, ToolRunner}
  alias BeamAgent.Session.{Context, ConversationContext, EventLog, StreamHub}

  @impl true
  def run(context, prompt) do
    turn = count_events(context.session_id, "turn_started") + 1

    with {:ok, project_context} <- Context.snapshot(context.session_id),
         {:ok, _} <-
           EventLog.append(context.session_id, :turn_started, %{
             "turn" => turn,
             "context_fingerprint" => project_context.fingerprint
           }),
         {:ok, _} <- EventLog.append(context.session_id, :user_message, %{"content" => prompt}) do
      step(context, turn, 1)
    end
  end

  defp step(context, turn, step_number) when step_number <= context.max_steps do
    with {:ok, _} <-
           EventLog.append(context.session_id, :step_started, %{
             "turn" => turn,
             "step" => step_number
           }),
         {:ok, project_context} <- Context.snapshot(context.session_id),
         tool_schemas <- CapabilityCatalog.tool_schemas(),
         {:ok, messages, _context_stats} <-
           ConversationContext.messages(
             context.session_id,
             context.provider_module,
             context.provider_options,
             project_context.system_prompt,
             tool_schemas
           ),
         {:ok, response} <-
           call_provider(
             context,
             messages,
             project_context.system_prompt,
             tool_schemas,
             turn,
             step_number
           ),
         :ok <- validate_response(response),
         {:ok, _} <-
           EventLog.append(context.session_id, :assistant_message, %{
             "content" => response.content,
             "tool_calls" => response.tool_calls
           }) do
      if response.tool_calls == [] do
        finish(context, turn, step_number, response.content || "")
      else
        with :ok <- execute_tools(context, turn, step_number, response.tool_calls),
             {:ok, _} <-
               EventLog.append(context.session_id, :step_finished, %{
                 "turn" => turn,
                 "step" => step_number,
                 "reason" => "tool_calls"
               }) do
          step(context, turn, step_number + 1)
        end
      end
    else
      {:error, reason} -> fail_turn(context, turn, reason)
    end
  end

  defp step(context, turn, _step_number), do: fail_turn(context, turn, :max_steps_exceeded)

  defp call_provider(context, messages, system_prompt, tool_schemas, turn, step) do
    options =
      context.provider_options
      |> Keyword.put(:session_id, context.session_id)
      |> Keyword.put(:parent_session_id, context.parent_session_id)
      |> Keyword.put(:system_prompt, system_prompt)

    if function_exported?(context.provider_module, :stream, 4) do
      call_streaming_provider(context, messages, tool_schemas, options, turn, step)
    else
      context.provider_module.complete(messages, tool_schemas, options)
    end
  end

  defp call_streaming_provider(context, messages, tool_schemas, options, turn, step) do
    metadata = %{
      "turn" => turn,
      "step" => step,
      "provider" => to_string(context.provider),
      "provider_profile" => context.provider_profile,
      "model" => options[:model]
    }

    with {:ok, response_id} <- StreamHub.begin_response(context.session_id, metadata) do
      emit = &StreamHub.emit(context.session_id, response_id, &1)

      result =
        try do
          context.provider_module.stream(
            messages,
            tool_schemas,
            options,
            emit
          )
        rescue
          error -> {:error, {:provider_exception, Exception.message(error)}}
        catch
          kind, reason -> {:error, {:provider_throw, kind, reason}}
        end

      case result do
        {:ok, response} ->
          case StreamHub.finish_response(context.session_id, response_id) do
            :ok -> {:ok, response}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          _ = StreamHub.fail_response(context.session_id, response_id, reason)
          {:error, reason}

        other ->
          reason = {:invalid_provider_return, other}
          _ = StreamHub.fail_response(context.session_id, response_id, reason)
          {:error, reason}
      end
    end
  end

  defp validate_response(%{content: content, tool_calls: calls})
       when (is_binary(content) or is_nil(content)) and is_list(calls),
       do: :ok

  defp validate_response(other), do: {:error, {:invalid_provider_response, other}}

  defp execute_tools(context, turn, step, calls) do
    Enum.reduce_while(calls, :ok, fn call, :ok ->
      with :ok <- validate_call(call),
           {:ok, _} <-
             EventLog.append(context.session_id, :tool_called, %{
               "turn" => turn,
               "step" => step,
               "tool_call_id" => call.id,
               "name" => call.name,
               "arguments" => call.arguments
             }),
           result <- execute_tool(call, context),
           {content, error} <- format_result(result),
           {:ok, _} <-
             EventLog.append(context.session_id, :tool_result, %{
               "turn" => turn,
               "step" => step,
               "tool_call_id" => call.id,
               "name" => call.name,
               "content" => content,
               "is_error" => match?({:error, _}, result),
               "error" => error
             }) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_call(%{id: id, name: name, arguments: arguments})
       when is_binary(id) and is_binary(name) and is_map(arguments),
       do: :ok

  defp validate_call(other), do: {:error, {:invalid_tool_call, other}}

  defp execute_tool(call, context) do
    case CapabilityCatalog.tool(call.name) do
      {:ok, module} ->
        ToolRunner.execute(module, call.arguments, tool_context(context))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tool_context(context) do
    Map.take(context, [
      :session_id,
      :parent_session_id,
      :provider,
      :provider_profile,
      :provider_options,
      :strategy,
      :max_steps,
      :data_dir,
      :workspace_root,
      :approval_policy,
      :approval_handler,
      :context_window_tokens,
      :compaction_threshold_percent
    ])
  end

  defp format_result({:ok, result}) when is_binary(result), do: {result, nil}
  defp format_result({:ok, result}), do: {inspect(result), nil}

  defp format_result({:error, reason}) do
    {"ERROR: " <> inspect(reason), error_envelope(reason)}
  end

  defp format_result(other) do
    {"ERROR: invalid tool return " <> inspect(other),
     %{"code" => "invalid_tool_return", "detail" => inspect(other)}}
  end

  defp error_envelope(reason) when is_atom(reason),
    do: %{"code" => to_string(reason), "detail" => inspect(reason)}

  defp error_envelope(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    code = elem(reason, 0)

    %{
      "code" => if(is_atom(code), do: to_string(code), else: "tool_error"),
      "detail" => inspect(reason)
    }
  end

  defp error_envelope(reason), do: %{"code" => "tool_error", "detail" => inspect(reason)}

  defp finish(context, turn, step, answer) do
    with {:ok, _} <-
           EventLog.append(context.session_id, :step_finished, %{
             "turn" => turn,
             "step" => step,
             "reason" => "completed"
           }),
         {:ok, _} <-
           EventLog.append(context.session_id, :turn_finished, %{
             "turn" => turn,
             "reason" => "completed"
           }) do
      {:ok, answer}
    end
  end

  defp fail_turn(context, turn, reason) do
    _ =
      EventLog.append(context.session_id, :turn_finished, %{
        "turn" => turn,
        "reason" => "error",
        "error" => inspect(reason)
      })

    {:error, reason}
  end

  defp count_events(session_id, type) do
    {:ok, events} = EventLog.events(session_id)
    Enum.count(events, &(&1["type"] == type))
  end
end
