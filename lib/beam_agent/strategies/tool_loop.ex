defmodule BeamAgent.Strategies.ToolLoop do
  @moduledoc "Default sequential, cancellable, multi-step model/tool strategy."
  @behaviour BeamAgent.AgentStrategy

  alias BeamAgent.{
    CapabilityCatalog,
    CapabilityEnvelope,
    MCP.Registry,
    ModelEndpoint,
    ModelInvocation,
    ModelRequest,
    ModelRouter,
    OutcomeStore,
    RacePolicy,
    ToolRunner
  }

  alias BeamAgent.Goal.{BudgetManager, CapabilityManager}

  alias BeamAgent.Session.{Context, ConversationContext, EventLog, StreamHub}

  @repeated_tool_result_limit 3
  @non_final_response_limit 2
  @tool_loop_recovery_prompt """
  The runtime detected the same tool calls returning the same results repeatedly.
  Tools are disabled for this recovery response. Use the tool results already in
  the conversation and answer the user's request directly without calling tools.
  """
  @completion_recovery_prompt """
  The runtime rejected your previous response as non-terminal: %{reason}.
  Continue the same user request now. Do not write or update a plan, claim progress,
  ask for permission to begin work the user already requested, or repeat the blocker
  unless no appropriate tool is available. Never claim a step completed unless a tool
  result in the conversation proves it. End only with a completed result or a concrete
  blocker that truly requires user input.
  """

  @impl true
  def run(context, prompt) do
    turn = count_events(context.session_id, "turn_started") + 1
    attachments = Map.get(context, :turn_attachments, [])

    with {:ok, project_context} <- Context.snapshot(context.session_id),
         {:ok, _} <-
           EventLog.append(context.session_id, :turn_started, %{
             "turn" => turn,
             "context_fingerprint" => project_context.fingerprint
           }),
         {:ok, _} <-
           EventLog.append(context.session_id, :user_message, %{
             "content" => prompt,
             "attachments" => attachments
           }) do
      start_turn(context, prompt, turn)
    end
  end

  defp start_turn(context, prompt, turn) do
    case maybe_race(context, prompt) do
      {:answered, content} ->
        with {:ok, _} <-
               EventLog.append(context.session_id, :assistant_message, %{
                 "content" => content,
                 "tool_calls" => []
               }) do
          finish(context, turn, 1, content)
        end

      :continue ->
        step(context, turn, 1, nil, 0, true)
    end
  end

  defp maybe_race(context, prompt) do
    case {Map.get(context, :turn_attachments, []), RacePolicy.consider(prompt, context)} do
      {[_ | _], _decision} ->
        :continue

      {[], {:race, plan}} ->
        opts = [
          justification: plan.justification,
          maximum_parallelism: length(plan.candidates),
          worker_options: race_worker_options(context)
        ]

        case BeamAgent.race_workers(context.session_id, plan.candidates, opts) do
          {:ok, %{status: :selected} = race} ->
            case winner_content(race) do
              content when is_binary(content) and content != "" -> {:answered, content}
              _missing -> continue_after_inconclusive_race(context, race)
            end

          {:ok, race} ->
            continue_after_inconclusive_race(context, race)

          {:error, _reason} ->
            :continue
        end

      {[], :skip} ->
        :continue
    end
  end

  defp continue_after_inconclusive_race(context, race) do
    _ =
      EventLog.append(context.session_id, :user_message, %{
        "content" => race_judgment_prompt(race)
      })

    :continue
  end

  defp race_judgment_prompt(race) do
    candidates =
      race.results
      |> Enum.sort_by(fn {id, _result} -> id end)
      |> Enum.flat_map(fn
        {id, {:ok, %{content: content}}} when is_binary(content) and content != "" ->
          ["- #{id}:\n#{String.slice(content, 0, 2_000)}"]

        _other ->
          []
      end)

    """
    The runtime raced #{map_size(race.results)} independent candidates for this goal and could not select a winner with deterministic evidence. Pick exactly one candidate. Quote it verbatim. Do not merge, blend, or list them.

    Candidates:
    #{Enum.join(candidates, "\n\n")}
    """
    |> String.trim()
  end

  defp winner_content(%{winner_id: id, results: results}) do
    case results[id] do
      {:ok, %{content: content}} -> content
      _other -> nil
    end
  end

  defp race_worker_options(context) do
    [
      provider: context.provider,
      provider_profile: context.provider_profile,
      provider_options: context.provider_options,
      strategy: context.strategy,
      data_dir: context.data_dir,
      workspace_root: context.workspace_root,
      approval_policy: context.approval_policy,
      approval_handler: context.approval_handler,
      context_window_tokens: context.context_window_tokens,
      compaction_threshold_percent: context.compaction_threshold_percent,
      model_strategy: context.model_strategy,
      correlation_id: runtime_command_field(context, :correlation_id),
      causation_id: runtime_command_field(context, :event_id)
    ]
  end

  defp runtime_command_field(%{runtime_command: command}, field) when is_map(command),
    do: Map.get(command, field)

  defp runtime_command_field(_context, _field), do: nil

  defp step(context, turn, step_number, previous_signature, repetition_count, tools_enabled?) do
    with {:ok, _} <-
           EventLog.append(context.session_id, :step_started, %{
             "turn" => turn,
             "step" => step_number,
             "tools_enabled" => tools_enabled?
           }),
         {:ok, project_context} <- Context.snapshot(context.session_id),
         tool_schemas <-
           if(tools_enabled?,
             do: available_tool_schemas(context),
             else: []
           ),
         system_prompt <-
           project_context.system_prompt
           |> turn_execution_prompt(context, tool_schemas)
           |> recovery_prompt(
             context,
             tools_enabled?,
             completion_recovery_reason(context.session_id, turn, step_number),
             tool_schemas
           ),
         {:ok, route} <- route_model(context, tool_schemas, turn, step_number),
         {:ok, messages, _context_stats} <-
           ConversationContext.messages(
             context.session_id,
             provider_module(route, context),
             provider_options(route, context),
             system_prompt,
             tool_schemas
           ),
         {:ok, response} <-
           call_provider(
             context,
             route,
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
        handle_terminal_response(
          context,
          turn,
          step_number,
          response.content,
          tool_schemas
        )
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

  defp call_provider(
         _context,
         %{endpoint: nil, deterministic_answer: answer},
         _messages,
         _system_prompt,
         _tool_schemas,
         _turn,
         _step
       ),
       do: {:ok, %{content: answer, tool_calls: []}}

  defp call_provider(context, route, messages, system_prompt, tool_schemas, turn, step) do
    endpoint = route.endpoint

    options =
      provider_options(route, context)
      |> Keyword.put(:session_id, context.session_id)
      |> Keyword.put(:parent_session_id, context.parent_session_id)
      |> Keyword.put(:system_prompt, system_prompt)

    with :ok <-
           BudgetManager.check(context.goal_id, context.session_id, %{
             model_tokens: estimated_context_tokens(context.session_id)
           }),
         {:ok, request} <-
           ModelRequest.new(
             endpoint_id: endpoint.id,
             provider: endpoint.provider,
             provider_module: endpoint.provider_module,
             model: options[:model],
             messages: messages,
             tools: tool_schemas,
             timeout: Keyword.get(options, :invocation_timeout_ms, :infinity),
             options: options,
             metadata: %{session_id: context.session_id, turn: turn, step: step}
           ),
         {:ok, response_id} <-
           StreamHub.begin_response(context.session_id, invocation_metadata(request, turn, step)) do
      emit = &StreamHub.emit(context.session_id, response_id, &1)

      started = System.monotonic_time(:millisecond)

      result =
        BeamAgent.Project.ResourceScheduler.run(
          context.project_id,
          model_pool(route),
          [session_id: context.session_id, priority: resource_priority(context)],
          fn -> ModelInvocation.invoke(request, emit) end
        )

      latency = System.monotonic_time(:millisecond) - started

      case result do
        {:ok, response} ->
          finish_metadata = %{
            "request_id" => request.request_id,
            "usage" => response.usage
          }

          case StreamHub.finish_response(context.session_id, response_id, finish_metadata) do
            :ok ->
              record_model_outcome(
                context,
                route,
                request,
                response.usage,
                latency,
                :succeeded,
                nil,
                turn,
                step
              )

              {:ok, response}

            {:error, reason} ->
              record_model_outcome(
                context,
                route,
                request,
                response.usage,
                latency,
                :failed,
                reason,
                turn,
                step
              )

              {:error, reason}
          end

        {:error, error} ->
          _ = StreamHub.fail_response(context.session_id, response_id, error)

          record_model_outcome(
            context,
            route,
            request,
            %{},
            latency,
            :failed,
            error.cause,
            turn,
            step
          )

          {:error, error.cause}
      end
    end
  end

  defp model_pool(route) do
    if route.inputs.reasoning == :high, do: :expensive_model, else: :model
  end

  defp resource_priority(context), do: if(context.parent_session_id, do: 0, else: 10)

  defp record_model_outcome(
         context,
         route,
         request,
         usage,
         latency,
         status,
         failure,
         turn,
         step
       ) do
    attrs = %{
      kind: :model,
      goal_id: context.goal_id,
      session_id: context.session_id,
      turn: turn,
      step: step,
      task_type: route.inputs.task_type,
      language: route.inputs.language,
      endpoint_id: request.endpoint_id,
      provider: request.provider,
      model: request.model,
      latency_ms: latency,
      usage: usage,
      estimated_cost: if(route.endpoint.claims.cost_hint == :free, do: 0, else: nil),
      retries: 0,
      status: status,
      failure: failure,
      route_decision_id: route.decision_id
    }

    tokens = usage["total_tokens"] || estimated_context_tokens(context.session_id)
    _ = BudgetManager.consume(context.goal_id, context.session_id, %{model_tokens: tokens})

    case OutcomeStore.record(context.project_id, attrs) do
      {:ok, %{id: id}} ->
        EventLog.append(context.session_id, :model_outcome_recorded, %{
          "outcome_id" => id,
          "status" => status,
          "latency_ms" => latency
        })

      _other ->
        :ok
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

  defp route_model(context, tool_schemas, turn, step) do
    prompt = latest_user_prompt(context.session_id)
    requirements = context.agent_spec.model_requirements

    input =
      %{
        prompt: prompt,
        workspace_root: context.workspace_root,
        strategy: context.model_strategy,
        preferred_endpoint_id: context.provider_profile,
        preferred_provider: context.provider,
        tools: tool_schemas,
        context_tokens: estimated_context_tokens(context.session_id),
        latency_preference: requirements.latency,
        cost_preference: requirements.cost,
        reasoning_requirement: requirements.reasoning,
        locality_requirement: requirements.locality,
        privacy_requirement: requirements.privacy,
        capability_envelope: context.capability_envelope,
        fallback_endpoint: current_endpoint(context)
      }
      |> Map.put(:modalities_required, required_modalities(context.session_id))

    with {:ok, route} <- ModelRouter.route(context.project_id, input),
         {:ok, _} <-
           EventLog.append(context.session_id, :model_route_selected, %{
             "decision_id" => route.decision_id,
             "turn" => turn,
             "step" => step,
             "strategy" => inspect(context.model_strategy),
             "candidate_endpoint_ids" => route.candidate_endpoint_ids,
             "candidates" => route.candidates,
             "selected_endpoint_id" => route.selected_endpoint_id,
             "inputs" => route.inputs,
             "reason" => route.reason,
             "evidence" => Map.get(route, :evidence)
           }) do
      {:ok, route}
    end
  end

  defp provider_module(%{endpoint: nil}, context), do: context.provider_module
  defp provider_module(%{endpoint: endpoint}, _context), do: endpoint.provider_module
  defp provider_options(%{endpoint: nil}, context), do: context.provider_options

  defp provider_options(%{endpoint: _endpoint}, %{model_strategy: :manual} = context),
    do: context.provider_options

  defp provider_options(%{endpoint: endpoint}, _context),
    do: ModelEndpoint.invocation_options(endpoint)

  defp latest_user_prompt(session_id) do
    {:ok, events} = EventLog.events(session_id)

    events
    |> Enum.reverse()
    |> Enum.find_value("", fn event ->
      if event["type"] == "user_message", do: event["data"]["content"]
    end)
  end

  defp required_modalities(session_id) do
    {:ok, events} = EventLog.events(session_id)

    compacted_through =
      events
      |> Enum.reverse()
      |> Enum.find_value(-1, fn event ->
        if event["type"] == "context_compaction_completed", do: event["data"]["through_seq"]
      end)

    image_in_context? =
      Enum.any?(events, fn event ->
        event["seq"] > compacted_through and event["type"] == "user_message" and
          match?([_ | _], event["data"]["attachments"])
      end)

    if image_in_context?, do: [:text, :image], else: [:text]
  end

  defp estimated_context_tokens(session_id) do
    {:ok, events} = EventLog.events(session_id)

    characters =
      Enum.reduce(events, 0, fn event, total ->
        data = event["data"] || %{}
        content = data["content"]
        total + if(is_binary(content), do: String.length(content), else: 0)
      end)

    div(characters + 3, 4)
  end

  defp current_endpoint(context) do
    {:ok, endpoint} =
      ModelEndpoint.new(%{
        id: context.provider_profile || to_string(context.provider),
        provider: context.provider,
        provider_module: context.provider_module,
        model: context.provider_options[:model],
        base_url: context.provider_options[:base_url],
        api_key_env: context.provider_options[:api_key_env],
        credential_ref: context.provider_options[:credential_ref],
        auth: context.provider_options[:auth]
      })

    endpoint
  end

  defp validate_response(%{content: content, tool_calls: calls})
       when (is_binary(content) or is_nil(content)) and is_list(calls),
       do: :ok

  defp validate_response(other), do: {:error, {:invalid_provider_response, other}}

  defp handle_terminal_response(context, turn, step, content, tool_schemas) do
    case completion_guard(context, turn, content, tool_schemas) do
      :complete ->
        finish(context, turn, step, content || "")

      {:non_final, reason} ->
        continue_after_non_final_response(context, turn, step, reason)
    end
  end

  defp completion_guard(context, turn, content, tool_schemas) do
    cond do
      not is_binary(content) or String.trim(content) == "" ->
        {:non_final, :empty_response}

      action_required?(context) and future_intent?(content) ->
        {:non_final, :future_intent}

      action_required?(context) and implementation_tool_names(context, tool_schemas) != [] and
          turn_action_count(context, turn) == 0 ->
        {:non_final, :action_not_started}

      true ->
        :complete
    end
  end

  defp continue_after_non_final_response(context, turn, step, reason) do
    attempt = completion_deferral_count(context.session_id, turn) + 1

    if attempt <= @non_final_response_limit do
      with {:ok, _} <-
             EventLog.append(context.session_id, :model_completion_deferred, %{
               "turn" => turn,
               "step" => step,
               "completion_reason" => to_string(reason),
               "attempt" => attempt,
               "maximum_attempts" => @non_final_response_limit
             }),
           {:ok, _} <-
             EventLog.append(context.session_id, :step_finished, %{
               "turn" => turn,
               "step" => step,
               "reason" => "non_final_response"
             }) do
        step(context, turn, step + 1, nil, 0, true)
      else
        {:error, event_error} -> fail_turn(context, turn, event_error)
      end
    else
      _ =
        EventLog.append(context.session_id, :model_completion_rejected, %{
          "turn" => turn,
          "step" => step,
          "completion_reason" => to_string(reason),
          "attempts" => attempt - 1
        })

      fail_turn(
        context,
        turn,
        {:non_final_model_response, reason, @non_final_response_limit}
      )
    end
  end

  defp completion_deferral_count(session_id, turn) do
    {:ok, events} = EventLog.events(session_id)

    Enum.count(events, fn event ->
      event["type"] == "model_completion_deferred" and event["data"]["turn"] == turn
    end)
  end

  defp completion_recovery_reason(session_id, turn, step) when step > 1 do
    {:ok, events} = EventLog.events(session_id)

    Enum.find_value(Enum.reverse(events), fn event ->
      data = event["data"] || %{}

      if event["type"] == "model_completion_deferred" and data["turn"] == turn and
           data["step"] == step - 1 do
        data["completion_reason"]
      end
    end)
  end

  defp completion_recovery_reason(_session_id, _turn, _step), do: nil

  defp turn_action_count(context, turn) do
    {:ok, events} = EventLog.events(context.session_id)

    calls =
      events
      |> Enum.filter(fn event ->
        event["type"] == "tool_called" and event["data"]["turn"] == turn
      end)
      |> Map.new(fn event -> {event["data"]["tool_call_id"], event["data"]["name"]} end)

    Enum.count(events, fn event ->
      data = event["data"] || %{}

      event["type"] == "tool_result" and data["turn"] == turn and
        data["is_error"] == false and action_tool?(calls[data["tool_call_id"]], context)
    end)
  end

  defp action_tool?("mcp__" <> _name, _context), do: true

  defp action_tool?(name, context) when is_binary(name) do
    case CapabilityCatalog.tool(name) do
      {:ok, module} ->
        access = if function_exported?(module, :access, 0), do: module.access(), else: :trusted

        (access == :write and name != "reload_context") or
          (access == :delegate and not direct_implementation_worker?(context))

      {:error, _reason} ->
        false
    end
  end

  defp action_tool?(_name, _context), do: false

  defp action_required?(context) do
    prompt = latest_user_prompt(context.session_id)
    classification = BeamAgent.TaskClassifier.classify(prompt, context.workspace_root)
    text = String.downcase(prompt)

    classification.task_type == :implementation or
      Regex.match?(~r/\b(implement|fix|modify|refactor)\b/u, text) or
      String.contains?(text, ["add support", "make a plan and then", "do that, make"])
  end

  defp future_intent?(content) do
    Enum.any?(
      [
        ~r/(?:^|\n)\s*(?:i['’]ll|i will|let me|i(?:'m| am) going to)\s+(?:start|begin|first|now|locate|inspect|trace|investigate|implement|change|edit|modify|plan)/iu,
        ~r/\bwould you like me to (?:start|begin|proceed|do that|locate|implement)\b/iu,
        ~r/\bshall i (?:start|begin|proceed|implement)\b/iu,
        ~r/\bto proceed,?\s+(?:i['’]ll|i will|i need to)\b/iu,
        ~r/\bi can start by\b/iu
      ],
      &Regex.match?(&1, content)
    )
  end

  defp completion_reason_text("empty_response"), do: "the model returned no answer or tool call"

  defp completion_reason_text("action_not_started"),
    do: "implementation requires a successful source write or delegation, but none occurred"

  defp completion_reason_text("future_intent"),
    do: "the response described future work instead of performing the requested work"

  defp completion_reason_text(reason), do: to_string(reason)

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

  defp turn_execution_prompt(system_prompt, context, tool_schemas) do
    if action_required?(context) do
      action_tools = implementation_tool_names(context, tool_schemas)
      direct_worker? = direct_implementation_worker?(context)

      contract =
        case {direct_worker?, action_tools} do
          {_direct_worker?, []} ->
            """
            # Current turn execution contract
            Task type: implementation.
            The current user request is the active goal for this turn. This worker has no
            source-write or delegation tool, so it may investigate and report a concrete
            missing-authority blocker, but it must not claim that implementation occurred.
            """

          {true, names} ->
            """
            # Current turn execution contract
            Task type: implementation.
            This is a bounded implementation worker. Perform the delegated change directly.
            Delegation and read-only investigation are intermediate work and do not satisfy
            this worker's goal. Before returning a terminal response, successfully invoke at
            least one source-write tool: #{Enum.join(names, ", ")}.
            Then verify the resulting change and report only what execution evidence supports.
            """

          {false, names} ->
            """
            # Current turn execution contract
            Task type: implementation.
            The current user request is the active goal for this turn. A persistent
            coordinator may perform bounded implementation directly or delegate it.
            Read-only investigation, planning, and scope summaries are intermediate work,
            not terminal results. Before returning a terminal response, successfully invoke
            at least one implementation-capable tool: #{Enum.join(names, ", ")}.
            Then verify the resulting change and report only what execution evidence supports.
            """
        end

      append_prompt(system_prompt, String.trim(contract))
    else
      system_prompt
    end
  end

  defp recovery_prompt(
         system_prompt,
         context,
         tools_enabled?,
         completion_reason,
         tool_schemas
       ) do
    system_prompt
    |> append_prompt(if(tools_enabled?, do: nil, else: @tool_loop_recovery_prompt))
    |> append_prompt(completion_recovery_prompt(context, completion_reason, tool_schemas))
  end

  defp append_prompt(prompt, nil), do: prompt
  defp append_prompt(prompt, addition), do: prompt <> "\n\n" <> addition

  defp completion_recovery_prompt(_context, nil, _tool_schemas), do: nil

  defp completion_recovery_prompt(context, reason, tool_schemas) do
    base =
      @completion_recovery_prompt
      |> String.replace("%{reason}", completion_reason_text(reason))
      |> String.trim()

    case {reason, implementation_tool_names(context, tool_schemas)} do
      {"action_not_started", [_ | _] = names} ->
        base <>
          "\nRead-only investigation has already been recorded and does not satisfy " <>
          "implementation. Your next response must invoke one of these tools through " <>
          "the provider's native tool protocol: #{Enum.join(names, ", ")}. " <>
          "Do not perform another read-only round or return another scope or plan."

      {_reason, _names} ->
        base
    end
  end

  defp implementation_tool_names(context, tool_schemas) do
    tool_schemas
    |> Enum.map(& &1.name)
    |> Enum.filter(&action_tool?(&1, context))
    |> Enum.sort()
  end

  defp direct_implementation_worker?(%{
         agent_spec: %{execution_strategy: %{id: "implement"}}
       }),
       do: true

  defp direct_implementation_worker?(_context), do: false

  defp available_tool_schemas(context) do
    (CapabilityCatalog.tool_schemas() ++ Registry.tool_schemas(context.goal_id))
    |> Enum.filter(fn schema ->
      resource = %{tools: schema.name}

      CapabilityEnvelope.authorize(context.capability_envelope, resource) == :ok or
        CapabilityManager.permits?(context.goal_id, context.session_id, resource)
    end)
  end

  defp validate_call(%{id: id, name: name, arguments: arguments})
       when is_binary(id) and is_binary(name) and is_map(arguments),
       do: :ok

  defp validate_call(other), do: {:error, {:invalid_tool_call, other}}

  defp execute_tool(call, context, causation_id) do
    case CapabilityCatalog.tool(call.name) do
      {:ok, module} ->
        ToolRunner.execute(module, call.arguments, tool_context(context, causation_id))

      {:error, _reason} ->
        Registry.execute(
          context.goal_id,
          call.name,
          call.arguments,
          tool_context(context, causation_id)
        )
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
      :capability_envelope,
      :model_strategy,
      :agent_spec,
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
      with {:ok, outcome} <- record_task_outcome(context, turn, :completed, nil) do
        maybe_verify_completion(context, outcome)
      end

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

    record_task_outcome(context, turn, :failed, reason)
    {:error, reason}
  end

  defp record_task_outcome(context, turn, status, failure) do
    prompt = latest_user_prompt(context.session_id)
    classification = BeamAgent.TaskClassifier.classify(prompt, context.workspace_root)

    attrs = %{
      kind: :task,
      goal_id: context.goal_id,
      session_id: context.session_id,
      turn: turn,
      task_type: classification.task_type,
      language: classification.language,
      status: status,
      failure: failure
    }

    case OutcomeStore.record(context.project_id, attrs) do
      {:ok, %{id: id, verification: verification} = outcome} ->
        with {:ok, _event} <-
               EventLog.append(context.session_id, :task_outcome_recorded, %{
                 "outcome_id" => id,
                 "status" => status,
                 "verification" => verification
               }) do
          {:ok, outcome}
        end

      other ->
        other
    end
  end

  defp maybe_verify_completion(context, outcome) do
    requirements = context.agent_spec.verification_requirements
    prompt = latest_user_prompt(context.session_id)
    classification = BeamAgent.TaskClassifier.classify(prompt, context.workspace_root)
    required? = (requirements[:required] || requirements["required"]) == true
    automatic? = classification.task_type in [:implementation, :debugging, :verification]

    if required? or automatic? do
      plan = requirements[:plan] || requirements["plan"] || :auto

      case BeamAgent.Goal.Verifier.run(context.goal_id, plan,
             session_id: context.session_id,
             outcome_id: outcome.id
           ) do
        {:ok, _result} ->
          :ok

        {:error, reason} ->
          if required? do
            result = %{
              status: :failed,
              source: "automatic",
              summary: "Required verification could not run: #{verification_error(reason)}"
            }

            _ = OutcomeStore.attach_verification(context.project_id, outcome.id, result)
          end

          _ =
            EventLog.append(context.session_id, :completion_report_generated, %{
              "status" => if(required?, do: "verification_failed", else: "unverified"),
              "evidence_count" => 0,
              "failure_code" => verification_error(reason)
            })

          :ok
      end
    else
      _ =
        EventLog.append(context.session_id, :completion_report_generated, %{
          "status" => "unverified",
          "evidence_count" => 0
        })

      :ok
    end
  end

  defp verification_error(reason) when is_atom(reason), do: to_string(reason)
  defp verification_error({reason, _detail}) when is_atom(reason), do: to_string(reason)
  defp verification_error(_reason), do: "verification_error"

  defp count_events(session_id, type) do
    {:ok, events} = EventLog.events(session_id)
    Enum.count(events, &(&1["type"] == type))
  end

  defp event_id(event), do: "#{event["session_id"]}:#{event["seq"]}"
end
