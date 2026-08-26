defmodule BeamAgent.Strategies.ToolLoop do
  @moduledoc "Default sequential, bounded, multi-step model/tool strategy."
  @behaviour BeamAgent.AgentStrategy

  alias BeamAgent.CapabilityCatalog
  alias BeamAgent.Session.EventLog

  @impl true
  def run(context, prompt) do
    turn = count_events(context.session_id, "turn_started") + 1

    with {:ok, _} <- EventLog.append(context.session_id, :turn_started, %{"turn" => turn}),
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
         {:ok, messages} <- EventLog.messages(context.session_id),
         {:ok, response} <- call_provider(context, messages),
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

  defp call_provider(context, messages) do
    options =
      context.provider_options
      |> Keyword.put(:session_id, context.session_id)
      |> Keyword.put(:parent_session_id, context.parent_session_id)

    context.provider_module.complete(messages, CapabilityCatalog.tool_schemas(), options)
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
           {:ok, _} <-
             EventLog.append(context.session_id, :tool_result, %{
               "turn" => turn,
               "step" => step,
               "tool_call_id" => call.id,
               "name" => call.name,
               "content" => format_result(result),
               "is_error" => match?({:error, _}, result)
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
        try do
          module.execute(call.arguments, tool_context(context))
        rescue
          error -> {:error, {:tool_exception, Exception.message(error)}}
        catch
          kind, reason -> {:error, {:tool_throw, kind, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tool_context(context) do
    Map.take(context, [
      :session_id,
      :parent_session_id,
      :provider,
      :provider_options,
      :strategy,
      :max_steps,
      :data_dir
    ])
  end

  defp format_result({:ok, result}) when is_binary(result), do: result
  defp format_result({:ok, result}), do: inspect(result)
  defp format_result({:error, reason}), do: "ERROR: " <> inspect(reason)
  defp format_result(other), do: "ERROR: invalid tool return " <> inspect(other)

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
