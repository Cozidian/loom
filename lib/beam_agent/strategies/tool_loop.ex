defmodule BeamAgent.Strategies.ToolLoop do
  @moduledoc "Default sequential, cancellable, multi-step model/tool strategy."
  @behaviour BeamAgent.AgentStrategy

  alias BeamAgent.{CapabilityCatalog, ModelInvocation, ModelRequest, ToolRunner}
  alias BeamAgent.Session.{Context, ConversationContext, EventLog, StreamHub}

  @repeated_tool_result_limit 3
  @tool_loop_recovery_prompt """
  The runtime detected the same tool calls returning the same results repeatedly.
  Tools are disabled for this recovery response. Use the tool results already in
  the conversation and answer the user's request directly without calling tools.
  """

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
      step(context, turn, 1, nil, 0, true)
    end
  end

  defp step(context, turn, step_number, previous_signature, repetition_count, tools_enabled?) do
    with {:ok, _} <-
           EventLog.append(context.session_id, :step_started, %{
             "turn" => turn,
             "step" => step_number,
             "tools_enabled" => tools_enabled?
           }),
         {:ok, project_context} <- Context.snapshot(context.session_id),
         tool_schemas <- if(tools_enabled?, do: CapabilityCatalog.tool_schemas(), else: []),
         system_prompt <- recovery_prompt(project_context.system_prompt, tools_enabled?),
         {:ok, messages, _context_stats} <-
           ConversationContext.messages(
             context.session_id,
             context.provider_module,
             context.provider_options,
             system_prompt,
             tool_schemas
           ),
         {:ok, response} <-
           call_provider(
             context,
             messages,
             system_prompt,
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
        continue_tool_calls(
          context,
          turn,
          step_number,
          response.tool_calls,
          previous_signature,
          repetition_count,
          tools_enabled?
        )
      end
    else
      {:error, reason} -> fail_turn(context, turn, reason)
    end
  end

  defp continue_tool_calls(
         context,
         turn,
         step_number,
         calls,
         previous_signature,
         repetition_count,
         true
       ) do
    case execute_tools(context, turn, step_number, calls) do
      {:ok, outcomes} ->
        signature = iteration_signature(calls, outcomes)

        repetition_count =
          if signature == previous_signature, do: repetition_count + 1, else: 1

        advance_after_tools(
          context,
          turn,
          step_number,
          calls,
          signature,
          repetition_count
        )

      {:error, reason} ->
        fail_turn(context, turn, reason)
    end
  end

  defp continue_tool_calls(context, turn, step_number, calls, _signature, _count, false) do
    with :ok <- reject_disabled_tool_calls(context, turn, step_number, calls) do
      fail_turn(
        context,
        turn,
        {:tools_disabled_during_loop_recovery, Enum.map(calls, &call_summary/1)}
      )
    else
      {:error, reason} -> fail_turn(context, turn, reason)
    end
  end

  defp advance_after_tools(context, turn, step_number, calls, signature, repetition_count) do
    if repetition_count >= @repeated_tool_result_limit do
      with {:ok, _} <-
             EventLog.append(context.session_id, :tool_loop_stalled, %{
               "turn" => turn,
               "step" => step_number,
               "repetitions" => repetition_count,
               "calls" => Enum.map(calls, &call_summary/1)
             }),
           {:ok, _} <-
             EventLog.append(context.session_id, :step_finished, %{
               "turn" => turn,
               "step" => step_number,
               "reason" => "tool_loop_stalled"
             }) do
        step(context, turn, step_number + 1, nil, 0, false)
      else
        {:error, reason} -> fail_turn(context, turn, reason)
      end
    else
      with {:ok, _} <-
             EventLog.append(context.session_id, :step_finished, %{
               "turn" => turn,
               "step" => step_number,
               "reason" => "tool_calls"
             }) do
        step(context, turn, step_number + 1, signature, repetition_count, true)
      else
        {:error, reason} -> fail_turn(context, turn, reason)
      end
    end
  end

  defp call_provider(context, messages, system_prompt, tool_schemas, turn, step) do
    options =
      context.provider_options
      |> Keyword.put(:session_id, context.session_id)
      |> Keyword.put(:parent_session_id, context.parent_session_id)
      |> Keyword.put(:system_prompt, system_prompt)

    with {:ok, request} <-
           ModelRequest.new(
             endpoint_id: context.provider_profile,
             provider: context.provider,
             provider_module: context.provider_module,
             model: options[:model],
             messages: messages,
             tools: tool_schemas,
             timeout: Keyword.get(context.provider_options, :invocation_timeout_ms, :infinity),
             options: options,
             metadata: %{session_id: context.session_id, turn: turn, step: step}
           ),
         {:ok, response_id} <-
           StreamHub.begin_response(context.session_id, invocation_metadata(request, turn, step)) do
      emit = &StreamHub.emit(context.session_id, response_id, &1)

      result = ModelInvocation.invoke(request, emit)

      case result do
        {:ok, response} ->
          finish_metadata = %{
            "request_id" => request.request_id,
            "usage" => response.usage
          }

          case StreamHub.finish_response(context.session_id, response_id, finish_metadata) do
            :ok -> {:ok, response}
            {:error, reason} -> {:error, reason}
          end

        {:error, error} ->
          _ = StreamHub.fail_response(context.session_id, response_id, error)
          {:error, error.cause}
      end
    end
  end

  defp invocation_metadata(request, turn, step) do
    %{
      "request_id" => request.request_id,
      "request_version" => request.version,
      "turn" => turn,
      "step" => step,
      "provider" => to_string(request.provider),
      "provider_profile" => request.endpoint_id,
      "model" => request.model,
      "stream" => request.stream,
      "timeout" => if(request.timeout == :infinity, do: "infinity", else: request.timeout)
    }
  end

  defp validate_response(%{content: content, tool_calls: calls})
       when (is_binary(content) or is_nil(content)) and is_list(calls),
       do: :ok

  defp validate_response(other), do: {:error, {:invalid_provider_response, other}}

  defp execute_tools(context, turn, step, calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, outcomes} ->
      with :ok <- validate_call(call),
           {:ok, tool_event} <-
             EventLog.append(context.session_id, :tool_called, %{
               "turn" => turn,
               "step" => step,
               "tool_call_id" => call.id,
               "name" => call.name,
               "arguments" => call.arguments
             }),
           result <- execute_tool(call, context, event_id(tool_event)),
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
        outcome = %{content: content, error: error, is_error: match?({:error, _}, result)}
        {:cont, {:ok, outcomes ++ [outcome]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reject_disabled_tool_calls(context, turn, step, calls) do
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
           {:ok, _} <-
             EventLog.append(context.session_id, :tool_result, %{
               "turn" => turn,
               "step" => step,
               "tool_call_id" => call.id,
               "name" => call.name,
               "content" => "ERROR: tools are disabled during repeated-tool recovery",
               "is_error" => true,
               "error" => %{
                 "code" => "tools_disabled_during_loop_recovery",
                 "detail" => "the same tool call and result repeated without progress"
               }
             }) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp iteration_signature(calls, outcomes) do
    calls
    |> Enum.zip(outcomes)
    |> Enum.map(fn {call, outcome} ->
      %{
        "name" => call.name,
        "arguments" => call.arguments,
        "content" => outcome.content,
        "error" => outcome.error,
        "is_error" => outcome.is_error
      }
    end)
    |> JSON.encode!()
  end

  defp call_summary(call), do: %{"name" => call.name, "arguments" => call.arguments}

  defp recovery_prompt(system_prompt, true), do: system_prompt

  defp recovery_prompt(system_prompt, false),
    do: system_prompt <> "\n\n" <> @tool_loop_recovery_prompt

  defp validate_call(%{id: id, name: name, arguments: arguments})
       when is_binary(id) and is_binary(name) and is_map(arguments),
       do: :ok

  defp validate_call(other), do: {:error, {:invalid_tool_call, other}}

  defp execute_tool(call, context, causation_id) do
    case CapabilityCatalog.tool(call.name) do
      {:ok, module} ->
        ToolRunner.execute(module, call.arguments, tool_context(context, causation_id))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tool_context(context, causation_id) do
    context
    |> Map.take([
      :session_id,
      :parent_session_id,
      :project_id,
      :goal_id,
      :provider,
      :provider_profile,
      :provider_options,
      :strategy,
      :data_dir,
      :workspace_root,
      :approval_policy,
      :approval_handler,
      :context_window_tokens,
      :compaction_threshold_percent,
      :runtime_command
    ])
    |> Map.put(:causation_id, causation_id)
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

  defp event_id(event), do: "#{event["session_id"]}:#{event["seq"]}"
end
