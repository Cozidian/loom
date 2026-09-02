defmodule BeamAgent.Strategies.ToolLoop do
  @moduledoc "Default sequential, cancellable, multi-step model/tool strategy."
  @behaviour BeamAgent.AgentStrategy

  alias BeamAgent.{
    CapabilityCatalog,
    CapabilityEnvelope,
    MCP.Registry,
    ModelEndpoint,
    ModelInvocation,
    ModelRegistry,
    ModelRequest,
    OutcomeStore,
    RacePolicy,
    TournamentPolicy,
    ToolRunner,
    WorkPlanningPolicy
  }

  alias BeamAgent.Goal.{
    BudgetManager,
    CapabilityManager,
    ModelLease,
    ProviderBidCoordinator,
    Tournament
  }

  alias BeamAgent.Session.{Context, ConversationContext, EventLog, StreamHub}

  @repeated_tool_result_limit 3
  @non_final_response_limit 2
  @verification_recovery_limit 2
  @review_recovery_limit 2
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
    file_references = Map.get(context, :turn_file_references, [])

    with {:ok, project_context} <- Context.snapshot(context.session_id),
         {:ok, _} <-
           EventLog.append(context.session_id, :turn_started, %{
             "turn" => turn,
             "context_fingerprint" => project_context.fingerprint
           }),
         {:ok, _} <-
           EventLog.append(context.session_id, :user_message, %{
             "content" => prompt,
             "attachments" => attachments,
             "file_references" => Enum.map(file_references, &Map.delete(&1, :content))
           }) do
      start_turn(context, prompt, turn)
    end
  end

  defp start_turn(context, prompt, turn) do
    planning = planning_decision(context, prompt)

    _ =
      EventLog.append(context.session_id, :work_planning_decided, %{
        "turn" => turn,
        "mode" => to_string(planning.mode),
        "source" => to_string(planning.source),
        "reason" => planning.reason,
        "endpoint_count" => planning.endpoint_count,
        "explicit_multi_provider_intent" => planning.explicit_multi_provider_intent,
        "suggested_endpoints" => planning.suggested_endpoints
      })

    case maybe_competition(context, prompt) do
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

  defp maybe_competition(context, prompt) do
    decision =
      case RacePolicy.consider(prompt, context) do
        :skip -> TournamentPolicy.consider(prompt, context)
        race -> race
      end

    case {Map.get(context, :turn_attachments, []), decision} do
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
              _missing -> :continue
            end

          {:ok, _race} ->
            :continue

          {:error, _reason} ->
            :continue
        end

      {[], {:tournament, plan}} ->
        opts = [
          justification: plan.justification,
          maximum_parallelism: length(plan.candidates),
          worker_options: race_worker_options(context)
        ]

        case BeamAgent.tournament_workers(context.session_id, plan.candidates, opts) do
          {:ok, %{status: :selected} = tournament} ->
            case winner_content(tournament) do
              content when is_binary(content) and content != "" -> {:answered, content}
              _missing -> continue_after_inconclusive_tournament(context, tournament)
            end

          {:ok, tournament} ->
            continue_after_inconclusive_tournament(context, tournament)

          {:error, _reason} ->
            :continue
        end

      {[], :skip} ->
        :continue
    end
  end

  defp continue_after_inconclusive_tournament(context, tournament) do
    _ = Tournament.request_judgment(context.session_id, tournament)

    _ =
      EventLog.append(context.session_id, :user_message, %{
        "content" => tournament_judgment_prompt(tournament)
      })

    :continue
  end

  defp tournament_judgment_prompt(tournament) do
    candidates =
      tournament.results
      |> Enum.sort_by(fn {id, _result} -> id end)
      |> Enum.flat_map(fn
        {id, {:ok, %{content: content}}} when is_binary(content) and content != "" ->
          ["- #{id}:\n#{String.slice(content, 0, 2_000)}"]

        _other ->
          []
      end)

    """
    The runtime compared #{map_size(tournament.results)} independent tournament candidates for this goal and could not select a winner with deterministic evidence. Pick exactly one candidate. Return that candidate's answer verbatim with no label, preface, explanation, merge, blend, or list.

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
    apply_steering(context, turn)

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

  defp apply_steering(context, turn) do
    receive do
      {:beam_agent_steer, message} ->
        _ =
          EventLog.append(context.session_id, :user_message, %{
            "content" => "Live user steering for turn #{turn}:\n\n#{message}",
            "steering" => true
          })

        apply_steering(context, turn)
    after
      0 -> :ok
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
      |> Keyword.put(:beam_turn, turn)
      |> maybe_put_provider_conversation(context.session_id)
      |> Keyword.put(
        :dynamic_tool_executor,
        &execute_native_tool(context, turn, step, &1)
      )

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
          [
            session_id: context.session_id,
            parent_session_id: context.parent_session_id,
            priority: resource_priority(context)
          ],
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

  defp maybe_put_provider_conversation(options, session_id) do
    case BeamAgent.CodexAppServer.Conversation.pid(session_id) do
      {:ok, pid} -> Keyword.put(options, :provider_conversation, pid)
      {:error, :not_found} -> options
    end
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
    case leased_route(context) do
      {:ok, route} ->
        append_reused_route(context, route, turn, step)

      :not_found ->
        select_and_lease_route(context, tool_schemas, turn, step)
    end
  end

  defp select_and_lease_route(context, tool_schemas, turn, step) do
    prompt = latest_user_prompt(context.session_id)
    requirements = context.agent_spec.model_requirements

    requested_endpoint_id =
      requirements[:preferred_endpoint_id] || requirements["preferred_endpoint_id"]

    preferred_endpoint_id = requested_endpoint_id || context.provider_profile

    preference_source = preference_source(context, requested_endpoint_id)
    planning = planning_decision(context)

    input =
      %{
        prompt: prompt,
        workspace_root: context.workspace_root,
        strategy: context.model_strategy,
        preferred_endpoint_id: preferred_endpoint_id,
        preference_source: preference_source,
        preferred_provider: context.provider,
        job_role: context.agent_spec.role,
        market_competition: context.model_strategy == :auto and planning.mode != :direct,
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

    with {:ok, auction} <-
           ProviderBidCoordinator.auction(
             context.goal_id,
             context.session_id,
             input,
             purpose: :work_contract,
             award_count: 1,
             pinned_endpoint_ids:
               if(preference_source in [:manual, :work_assignment],
                 do: [preferred_endpoint_id],
                 else: []
               )
           ),
         route <- auction.route,
         {:ok, route} <- lease_route(context, route),
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
             "preference_source" => to_string(preference_source),
             "job_role" => context.agent_spec.role,
             "evidence" => Map.get(route, :evidence),
             "provider_auction_id" => Map.get(route, :provider_auction_id),
             "winning_bid" => Map.get(route, :winning_bid)
           }) do
      {:ok, route}
    end
  end

  defp preference_source(context, requested_endpoint_id) do
    cond do
      context.model_strategy == :manual ->
        :manual

      is_binary(context.parent_session_id) and is_binary(requested_endpoint_id) ->
        :work_assignment

      true ->
        :session_default
    end
  end

  defp leased_route(%{work_contract: %{id: work_id}, goal_id: goal_id}),
    do: ModelLease.fetch(goal_id, work_id)

  defp leased_route(%{goal_id: goal_id, session_id: session_id}),
    do: ModelLease.fetch(goal_id, worker_lease_id(session_id))

  defp lease_route(%{work_contract: %{id: work_id}, goal_id: goal_id}, route),
    do: ModelLease.put_new(goal_id, work_id, route)

  defp lease_route(%{goal_id: goal_id, session_id: session_id}, route),
    do: ModelLease.put_new(goal_id, worker_lease_id(session_id), route)

  defp lease_route(_context, route), do: {:ok, route}

  defp worker_lease_id(session_id), do: "worker:" <> session_id

  defp append_reused_route(context, route, turn, step) do
    with {:ok, _event} <-
           EventLog.append(context.session_id, :model_route_reused, %{
             "decision_id" => route.decision_id,
             "turn" => turn,
             "step" => step,
             "selected_endpoint_id" => route.selected_endpoint_id,
             "reason" => "work_contract_model_lease"
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
    case ConversationContext.stats(session_id, "", []) do
      {:ok, %{estimated_tokens: tokens}} -> tokens
      _error -> 0
    end
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
        answer = content || ""

        case Tournament.resolve_pending_judgment(context.goal_id, context.session_id, answer) do
          {:ok, winner_content} -> finish(context, turn, step, winner_content)
          _not_resolved -> finish(context, turn, step, answer)
        end

      {:non_final, reason} ->
        continue_after_non_final_response(context, turn, step, reason)
    end
  end

  defp completion_guard(context, turn, content, tool_schemas) do
    planning = planning_decision(context)
    delegation = turn_delegation(context, turn)
    decomposition_recovery = turn_decomposition_recovery(context, turn)
    record_semantic_planning_observation(context, turn, planning, delegation)

    cond do
      not is_binary(content) or String.trim(content) == "" ->
        {:non_final, :empty_response}

      action_required?(context) and future_intent?(content) ->
        {:non_final, :future_intent}

      decomposition_recovery == "replan" and
          not turn_action_blocked_by_runtime?(context, turn) ->
        {:non_final, :replan_required}

      planning.mode == :required and tool_available?(tool_schemas, "delegate_tasks") and
        delegation.endpoint_count < 2 and
        not terminal_decomposition_recovery?(decomposition_recovery) and
          not turn_action_blocked_by_runtime?(context, turn) ->
        {:non_final, :decomposition_required}

      action_required?(context) and implementation_tool_names(context, tool_schemas) != [] and
        turn_action_count(context, turn) == 0 and
        not terminal_decomposition_recovery?(decomposition_recovery) and
          not turn_action_blocked_by_runtime?(context, turn) ->
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
        data["is_error"] == false and
        action_tool?(calls[data["tool_call_id"]], data, context)
    end)
  end

  defp turn_delegation(context, turn) do
    {:ok, events} = EventLog.events(context.session_id)

    calls =
      events
      |> Enum.filter(fn event ->
        event["type"] == "tool_called" and event["data"]["turn"] == turn and
          event["data"]["name"] == "delegate_tasks"
      end)
      |> MapSet.new(& &1["data"]["tool_call_id"])

    successful_results =
      events
      |> Enum.filter(fn event ->
        data = event["data"] || %{}

        event["type"] == "tool_result" and data["turn"] == turn and
          data["is_error"] == false and MapSet.member?(calls, data["tool_call_id"]) and
          successful_decomposition_result?(data["content"])
      end)

    worker_endpoint_ids =
      successful_results
      |> Enum.flat_map(fn event ->
        case JSON.decode(event["data"]["content"] || "") do
          {:ok, %{"used_endpoint_ids" => ids}} when is_list(ids) -> ids
          _other -> []
        end
      end)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    coordinator_endpoint_ids =
      if successful_results == [] do
        []
      else
        events
        |> Enum.filter(fn event ->
          event["type"] == "model_response_started" and event["data"]["turn"] == turn
        end)
        |> Enum.map(& &1["data"]["provider_profile"])
        |> Enum.filter(&is_binary/1)
      end

    endpoint_ids = Enum.uniq(worker_endpoint_ids ++ coordinator_endpoint_ids)

    %{
      delegated?: successful_results != [],
      endpoint_ids: endpoint_ids,
      endpoint_count: length(endpoint_ids)
    }
  end

  defp turn_decomposition_recovery(context, turn) do
    {:ok, events} = EventLog.events(context.session_id)

    calls =
      events
      |> Enum.filter(fn event ->
        event["type"] == "tool_called" and event["data"]["turn"] == turn and
          event["data"]["name"] == "delegate_tasks"
      end)
      |> MapSet.new(& &1["data"]["tool_call_id"])

    Enum.find_value(Enum.reverse(events), fn event ->
      data = event["data"] || %{}

      if event["type"] == "tool_result" and data["turn"] == turn and
           data["is_error"] == false and MapSet.member?(calls, data["tool_call_id"]) do
        case JSON.decode(data["content"] || "") do
          {:ok, %{"recovery" => %{"action" => action}}} -> action
          _other -> nil
        end
      end
    end)
  end

  defp successful_decomposition_result?(content) do
    case JSON.decode(content || "") do
      {:ok, %{"status" => status}} -> status in ["completed", "succeeded"]
      _other -> false
    end
  end

  defp terminal_decomposition_recovery?(action), do: action in ["ask", "stop"]

  defp turn_action_blocked_by_runtime?(context, turn) do
    {:ok, events} = EventLog.events(context.session_id)

    calls =
      events
      |> Enum.filter(fn event ->
        event["type"] == "tool_called" and event["data"]["turn"] == turn
      end)
      |> Map.new(fn event -> {event["data"]["tool_call_id"], event["data"]["name"]} end)

    Enum.any?(events, fn event ->
      data = event["data"] || %{}
      code = get_in(data, ["error", "code"])

      event["type"] == "tool_result" and data["turn"] == turn and
        data["is_error"] == true and runtime_blocker?(code) and
        action_capable_tool?(calls[data["tool_call_id"]], context)
    end)
  end

  defp runtime_blocker?(code),
    do:
      code in [
        "tool_denied",
        "capability_denied",
        "capability_lease_denied",
        "path_lease_denied",
        "codex_tool_not_allowed",
        "tool_not_allowed",
        "budget_deadline_exceeded"
      ]

  defp action_tool?("mcp__" <> _name, _result, _context), do: true

  defp action_tool?("run_command", result, _context) do
    case JSON.decode(result["content"] || "") do
      {:ok, %{"changed_files" => [_ | _]}} -> true
      _other -> false
    end
  end

  defp action_tool?("delegate_tasks", result, _context) do
    case JSON.decode(result["content"] || "") do
      {:ok, %{"status" => status, "changed_files" => [_ | _]}} ->
        status in ["completed", "succeeded"]

      _other ->
        false
    end
  end

  defp action_tool?("spawn_subagent", result, _context) do
    case JSON.decode(result["content"] || "") do
      {:ok, %{"background" => true}} -> false
      {:ok, %{"status" => status}} -> status in ["completed", "succeeded"]
      _other -> false
    end
  end

  defp action_tool?("await_subagent", result, _context) do
    case JSON.decode(result["content"] || "") do
      {:ok, %{"status" => status}} -> status in ["completed", "succeeded"]
      _other -> false
    end
  end

  defp action_tool?(name, _result, _context)
       when name in ["subagent_status", "cancel_subagent"],
       do: false

  defp action_tool?(name, _result, context) when is_binary(name) do
    case CapabilityCatalog.tool(name) do
      {:ok, module} ->
        access = if function_exported?(module, :access, 0), do: module.access(), else: :trusted

        (access == :write and name != "reload_context") or
          (access == :delegate and not direct_implementation_worker?(context))

      {:error, _reason} ->
        false
    end
  end

  defp action_tool?(_name, _result, _context), do: false

  defp planning_decision(context, prompt \\ nil) do
    endpoints =
      case ModelRegistry.list(context.project_id) do
        {:ok, endpoints} -> endpoints
        {:error, _reason} -> []
      end

    WorkPlanningPolicy.decide(prompt || latest_user_prompt(context.session_id), endpoints,
      workspace_root: context.workspace_root,
      model_strategy: context.model_strategy
    )
  end

  defp record_semantic_planning_observation(context, turn, planning, delegation) do
    {:ok, events} = EventLog.events(context.session_id)

    recorded? =
      Enum.any?(events, fn event ->
        event["type"] == "semantic_planning_observed" and event["data"]["turn"] == turn
      end)

    if not recorded? do
      choice = if delegation.delegated?, do: "decomposed", else: "direct"
      multi_provider? = delegation.endpoint_count >= 2

      _ =
        EventLog.append(context.session_id, :semantic_planning_observed, %{
          "turn" => turn,
          "runtime_mode" => to_string(planning.mode),
          "model_choice" => choice,
          "endpoint_count" => delegation.endpoint_count,
          "multi_provider" => multi_provider?,
          "classification" => to_string(planning.classification.task_type),
          "change_intent" => planning.classification.change_intent,
          "agreed" => semantic_planning_agreement?(planning.mode, delegation)
        })
    end

    :ok
  end

  defp semantic_planning_agreement?(:required, delegation), do: delegation.endpoint_count >= 2
  defp semantic_planning_agreement?(:direct, delegation), do: not delegation.delegated?
  defp semantic_planning_agreement?(:advisory, _delegation), do: nil

  defp tool_available?(tool_schemas, name), do: Enum.any?(tool_schemas, &(&1.name == name))

  defp action_required?(context) do
    cond do
      direct_evidence_worker?(context) ->
        false

      true ->
        contract = Map.get(context, :work_contract)
        prompt = latest_user_prompt(context.session_id)
        classification = BeamAgent.TaskClassifier.classify(prompt, context.workspace_root)
        text = String.downcase(prompt)

        match?(
          %BeamAgent.WorkContract{kind: kind} when kind in [:implementation, :debugging],
          contract
        ) or
          classification.task_type == :implementation or
          classification.change_intent or
          Regex.match?(~r/\b(implement|fix|modify|refactor)\b/u, text) or
          String.contains?(text, ["add support", "make a plan and then", "do that, make"])
    end
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

  defp completion_reason_text("decomposition_required"),
    do: "the required multi-provider decomposition has not been executed"

  defp completion_reason_text("replan_required"),
    do: "the previous task graph returned a typed replan decision"

  defp completion_reason_text("future_intent"),
    do: "the response described future work instead of performing the requested work"

  defp completion_reason_text(reason), do: to_string(reason)

  defp execute_tools(context, turn, step, calls) do
    if parallel_read_batch?(calls) do
      calls
      |> Task.async_stream(&execute_one_tool(context, turn, step, &1),
        ordered: true,
        max_concurrency: min(length(calls), 8),
        timeout: :infinity
      )
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, {:ok, outcome}}, {:ok, outcomes} ->
          {:cont, {:ok, outcomes ++ [outcome]}}

        {:ok, {:error, reason}}, _acc ->
          {:halt, {:error, reason}}

        {:exit, reason}, _acc ->
          {:halt, {:error, {:parallel_tool_exit, reason}}}
      end)
    else
      Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, outcomes} ->
        case execute_one_tool(context, turn, step, call) do
          {:ok, outcome} -> {:cont, {:ok, outcomes ++ [outcome]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp execute_one_tool(context, turn, step, call) do
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
      {:ok, %{content: content, error: error, is_error: match?({:error, _}, result)}}
    end
  end

  defp execute_native_tool(context, turn, step, call) do
    with :ok <- validate_call(call),
         {:ok, _} <-
           EventLog.append(context.session_id, :assistant_message, %{
             "content" => nil,
             "tool_calls" => [call]
           }) do
      execute_one_tool(context, turn, step, call)
    end
    |> case do
      {:ok, outcome} ->
        {:ok, outcome}

      {:error, reason} ->
        {content, error} = format_result({:error, reason})
        {:ok, %{content: content, error: error, is_error: true}}
    end
  end

  defp parallel_read_batch?([_, _ | _] = calls), do: Enum.all?(calls, &read_only_call?/1)
  defp parallel_read_batch?(_calls), do: false

  defp read_only_call?(%{name: name}) do
    case CapabilityCatalog.tool(name) do
      {:ok, module} ->
        access = if function_exported?(module, :access, 0), do: module.access(), else: :trusted
        access in [:read, :trusted]

      {:error, _reason} ->
        false
    end
  end

  defp read_only_call?(_call), do: false

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
    system_prompt =
      case Map.get(context, :work_contract) do
        %BeamAgent.WorkContract{} = contract ->
          append_prompt(system_prompt, BeamAgent.WorkContract.prompt(contract))

        _other ->
          system_prompt
      end

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

      system_prompt
      |> append_prompt(String.trim(contract))
      |> append_prompt(provider_market_prompt(direct_worker?, tool_schemas, context))
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

  defp provider_market_prompt(false, tool_schemas, context) do
    names = MapSet.new(tool_schemas, & &1.name)

    if MapSet.member?(names, "list_models") and MapSet.member?(names, "delegate_tasks") do
      planning = planning_decision(context)

      obligation =
        case planning.mode do
          :required ->
            "The runtime requires a validated decomposition for this substantial implementation. Call list_models and then delegate_tasks before returning a terminal answer."

          :advisory ->
            "The runtime marks decomposition as advisory. Use it only when specialization improves the result; otherwise keep one coherent implementation owner."

          :direct ->
            "The runtime currently prefers direct work, but bounded delegation remains available if new evidence justifies it."
        end

      """
      # Multi-provider coordination
      Runtime planning mode: #{planning.mode}. #{obligation}
      Runtime suggested assignments: scaffold=#{planning.suggested_endpoints.scaffold || "none"},
      coherent implementation=#{planning.suggested_endpoints.implementation || "none"},
      independent verification=#{planning.suggested_endpoints.verification || "none"}.
      A feature may use different providers for meaningfully different bounded phases. Inspect
      the safe endpoint inventory with list_models, then propose workers through delegate_tasks
      with explicit model requirements. Cheap or local endpoints may fit deterministic
      scaffolding and narrow inspection; stronger coding endpoints may fit coherent
      implementation; an independent endpoint may fit tests or review. These are preferences,
      not authority: runtime capability, privacy, availability, evidence, budget, leases, and
      routing policy decide the award. Run independent workers concurrently. Order workers with
      explicit dependencies whenever their paths overlap so ownership is handed off, not raced.
      """
      |> String.trim()
    end
  end

  defp provider_market_prompt(_direct_worker?, _tool_schemas, _context), do: nil

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

      {"decomposition_required", _names} ->
        base <>
          "\nThe runtime requires multiple providers for this substantial request. Call list_models, then invoke " <>
          "delegate_tasks with a validated dependency plan and per-task model requirements."

      {"replan_required", _names} ->
        base <>
          "\nThe previous task graph ended with a typed replan decision. Inspect its failed and blocked tasks, then invoke delegate_tasks with a corrected dependency graph or assignments."

      {_reason, _names} ->
        base
    end
  end

  defp implementation_tool_names(context, tool_schemas) do
    tool_schemas
    |> Enum.map(& &1.name)
    |> Enum.filter(&action_capable_tool?(&1, context))
    |> Enum.sort()
  end

  defp action_capable_tool?("run_command", _context), do: true
  defp action_capable_tool?("mcp__" <> _name, _context), do: true

  defp action_capable_tool?(name, _context)
       when name in ["subagent_status", "cancel_subagent"],
       do: false

  defp action_capable_tool?(name, context) when is_binary(name) do
    case CapabilityCatalog.tool(name) do
      {:ok, module} ->
        access = if function_exported?(module, :access, 0), do: module.access(), else: :trusted

        (access == :write and name != "reload_context") or
          (access == :delegate and not direct_implementation_worker?(context))

      {:error, _reason} ->
        false
    end
  end

  defp action_capable_tool?(_name, _context), do: false

  defp direct_implementation_worker?(%{
         agent_spec: %{execution_strategy: %{id: "implement"}}
       }),
       do: true

  defp direct_implementation_worker?(%{
         work_contract: %BeamAgent.WorkContract{worker_kind: :implementer}
       }),
       do: true

  defp direct_implementation_worker?(_context), do: false

  defp direct_evidence_worker?(%{
         parent_session_id: parent_session_id,
         agent_spec: %{execution_strategy: %{id: id}}
       })
       when is_binary(parent_session_id) and id in ["investigate", "review", "verify"],
       do: true

  defp direct_evidence_worker?(_context), do: false

  defp available_tool_schemas(context) do
    (CapabilityCatalog.tool_schemas() ++ Registry.tool_schemas(context.goal_id))
    |> Enum.filter(fn schema ->
      resource = %{tools: schema.name}

      CapabilityEnvelope.authorize(context.capability_envelope, resource) == :ok or
        CapabilityManager.permits?(context.goal_id, context.session_id, resource)
    end)
    |> enforce_planning_gate(context)
  end

  defp enforce_planning_gate(tool_schemas, context) do
    planning = planning_decision(context)
    turn = count_events(context.session_id, "turn_started")
    recovery = turn_decomposition_recovery(context, turn)

    if recovery == "replan" or
         (planning.mode == :required and turn_delegation(context, turn).endpoint_count < 2) do
      Enum.filter(tool_schemas, &planning_tool?/1)
    else
      tool_schemas
    end
  end

  defp planning_tool?(%{name: name}) when name in ["list_models", "delegate_tasks"], do: true

  defp planning_tool?(%{name: name}) do
    case CapabilityCatalog.tool(name) do
      {:ok, module} ->
        access = if function_exported?(module, :access, 0), do: module.access(), else: :trusted
        access == :read

      {:error, _reason} ->
        false
    end
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

  defp format_result({:error, {:command_failed, data}}) when is_map(data) do
    {JSON.encode!(data),
     %{
       "code" => "command_failed",
       "detail" => "Command exited with status #{data.status}"
     }}
  end

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
             "reason" => "candidate_completed"
           }) do
      case completion_verification(context, turn) do
        {:ok, verification} ->
          case completion_review(context, turn, verification) do
            :skip ->
              finalize_verified_turn(context, turn, answer, verification)

            {:ok, review} ->
              finalize_verified_turn(context, turn, answer, verification, review)

            {:retry, review, attempt} ->
              continue_after_review_failure(context, turn, step, review, attempt)

            {:error, review} ->
              fail_reviewed_turn(context, turn, verification, review)
          end

        {:retry, result, attempt} ->
          continue_after_verification_failure(context, turn, step, result, attempt)

        {:error, result} ->
          fail_verified_turn(context, turn, result)
      end
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

  defp record_task_outcome(context, turn, status, failure, verification \\ nil) do
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
      failure: failure,
      verification: verification_summary(verification)
    }

    case OutcomeStore.record(context.project_id, attrs) do
      {:ok, %{id: id} = outcome} ->
        with :ok <- maybe_attach_completion_verification(context, outcome, verification),
             {:ok, _event} <-
               EventLog.append(context.session_id, :task_outcome_recorded, %{
                 "outcome_id" => id,
                 "status" => status,
                 "verification" => verification_summary(verification)
               }) do
          {:ok, outcome}
        end

      other ->
        other
    end
  end

  defp maybe_attach_completion_verification(_context, _outcome, nil), do: :ok

  defp maybe_attach_completion_verification(context, outcome, verification) do
    OutcomeStore.attach_verification(context.project_id, outcome.id, verification)
  end

  defp completion_verification(%{work_contract: %BeamAgent.WorkContract{}}, _turn),
    do: {:ok, nil}

  defp completion_verification(context, turn) do
    requirements = context.agent_spec.verification_requirements
    prompt = latest_user_prompt(context.session_id)
    classification = BeamAgent.TaskClassifier.classify(prompt, context.workspace_root)
    required? = (requirements[:required] || requirements["required"]) == true
    review_or_verifier? = context.agent_spec.template in ["reviewer", "verifier"]

    automatic? =
      turn_action_count(context, turn) > 0 and not review_or_verifier? and
        classification.task_type in [:implementation, :debugging, :verification]

    if required? or automatic? do
      plan = requirements[:plan] || requirements["plan"] || :auto

      case BeamAgent.Goal.Verifier.run(context.goal_id, plan,
             session_id: context.session_id,
             worker_id: context.session_id,
             attach: false,
             completion_report: false
           ) do
        {:ok, %{status: :passed} = result} ->
          {:ok, result}

        {:ok, %{status: :failed} = result} ->
          verification_recovery(context, turn, result)

        {:error, :no_verification_checks} ->
          {:ok,
           %{
             status: :not_configured,
             source: "workspace-discovery",
             summary: "No deterministic verification checks were discovered",
             checks: []
           }}

        {:error, reason} ->
          {:error,
           %{
             status: :failed,
             source: "automatic",
             failure_kind: :infrastructure,
             summary: "Verification could not run: #{verification_error(reason)}",
             checks: []
           }}
      end
    else
      {:ok, nil}
    end
  end

  defp verification_recovery(context, turn, result) do
    {:ok, events} = EventLog.events(context.session_id)

    attempt =
      Enum.count(events, fn event ->
        event["type"] == "verification_recovery_started" and event["data"]["turn"] == turn
      end) + 1

    if attempt <= @verification_recovery_limit,
      do: {:retry, result, attempt},
      else: {:error, result}
  end

  defp continue_after_verification_failure(context, turn, step, result, attempt) do
    feedback = verification_feedback(result)

    with {:ok, _} <-
           EventLog.append(context.session_id, :verification_recovery_started, %{
             "turn" => turn,
             "step" => step,
             "attempt" => attempt,
             "maximum_attempts" => @verification_recovery_limit,
             "verification_id" => Map.get(result, :verification_id),
             "failure_code" => "required_checks_failed"
           }),
         {:ok, _} <-
           EventLog.append(context.session_id, :verification_feedback, %{
             "turn" => turn,
             "attempt" => attempt,
             "content" => feedback
           }) do
      step(context, turn, step + 1, nil, 0, true)
    else
      {:error, reason} -> fail_turn(context, turn, reason)
    end
  end

  defp finalize_verified_turn(context, turn, answer, verification, review \\ nil) do
    if Map.get(context, :work_contract) do
      with {:ok, _event} <-
             EventLog.append(context.session_id, :worker_candidate_finished, %{
               "turn" => turn,
               "contract_id" => context.work_contract.id,
               "reason" => "candidate_completed"
             }) do
        {:ok, answer}
      end
    else
      status = if verification, do: :succeeded, else: :completed

      with {:ok, _} <-
             EventLog.append(context.session_id, :turn_finished, %{
               "turn" => turn,
               "reason" => "completed",
               "verification_status" => verification_status(verification),
               "review_status" => review_status(review)
             }),
           {:ok, _outcome} <- record_task_outcome(context, turn, status, nil, verification),
           {:ok, _report} <- append_completion_report(context, verification) do
        {:ok, answer}
      end
    end
  end

  defp completion_review(%{work_contract: %BeamAgent.WorkContract{}}, _turn, _verification),
    do: :skip

  defp completion_review(context, turn, verification) do
    prompt = latest_user_prompt(context.session_id)
    classification = BeamAgent.TaskClassifier.classify(prompt, context.workspace_root)
    requirements = context.agent_spec.verification_requirements

    review_required? =
      Map.get(requirements, :review_required, Map.get(requirements, "review_required", true)) !=
        false

    cond do
      not review_required? ->
        :skip

      context.agent_spec.template in ["reviewer", "verifier"] ->
        :skip

      turn_action_count(context, turn) == 0 ->
        :skip

      classification.task_type != :implementation ->
        :skip

      true ->
        case BeamAgent.GitDiff.summary(context.workspace_root) do
          {:ok, %{changed_file_count: 0}} -> :skip
          {:ok, _summary} -> run_review_worker(context, turn, prompt, verification)
          {:error, _not_git} -> run_review_worker(context, turn, prompt, verification)
        end
    end
  end

  defp run_review_worker(context, turn, prompt, verification) do
    with {:ok, goal} <- BeamAgent.Goal.snapshot(context.goal_id) do
      review_prompt = """
      Review the current uncommitted workspace changes against this authoritative request:

      #{prompt}

      Deterministic verification evidence supplied by the runtime:
      #{JSON.encode!(verification || %{status: :unverified, checks: []})}

      Inspect the Git diff and relevant source/tests using read-only tools. If Git evidence is
      unavailable, inspect the changed workspace files and recorded tool evidence directly.
      Do not report tests as missing or failed when the runtime evidence says they passed.
      Prioritize correctness, security, missing acceptance criteria, and verification gaps. The first line of the final
      response must be exactly REVIEW_PASS when there are no actionable findings, or REVIEW_FAIL
      when fixes are required. After REVIEW_FAIL, provide concrete file-and-line findings.
      """

      proposal = %{
        goal: "Independently review the current implementation before it may complete",
        role: "Mandatory completion reviewer",
        template: "reviewer",
        instructions: [
          "Use git_inspect before reaching a conclusion.",
          "Do not modify files and do not accept claims unsupported by the diff or tests."
        ],
        capabilities: %{
          tools: ["git_inspect", "read_file", "search_files", "file_diagnostics"],
          paths: :all
        },
        verification_requirements: %{required: false},
        completion_criteria: "Return REVIEW_PASS or REVIEW_FAIL with evidence"
      }

      opts = review_worker_options(context)

      with {:ok, _} <-
             EventLog.append(context.session_id, :implementation_review_started, %{
               "turn" => turn,
               "root_session_id" => goal.session_id
             }),
           {:ok, handle} <- BeamAgent.spawn_worker(goal.session_id, proposal, opts) do
        try do
          case BeamAgent.ask(handle.worker_id, review_prompt) do
            {:ok, answer} ->
              _ = BeamAgent.complete_worker(handle, answer, %{status: :unverified})
              finish_review(context, turn, handle.worker_id, answer)

            {:error, reason} ->
              _ = BeamAgent.cancel_worker(handle, reason)
              review_recovery(context, turn, %{status: :failed, content: inspect(reason)})
          end
        after
          _ = BeamAgent.stop_session(handle.worker_id)
        end
      else
        {:error, reason} ->
          review_recovery(context, turn, %{status: :failed, content: inspect(reason)})
      end
    else
      {:error, reason} ->
        review_recovery(context, turn, %{status: :failed, content: inspect(reason)})
    end
  end

  defp finish_review(context, turn, worker_id, answer) do
    status =
      if String.starts_with?(String.trim(answer), "REVIEW_PASS"), do: :passed, else: :failed

    review = %{status: status, content: answer, worker_id: worker_id}

    _ =
      EventLog.append(context.session_id, :implementation_review_finished, %{
        "turn" => turn,
        "status" => status,
        "worker_id" => worker_id,
        "evidence_count" => if(status == :passed, do: 1, else: 0)
      })

    if status == :passed, do: {:ok, review}, else: review_recovery(context, turn, review)
  end

  defp review_recovery(context, turn, review) do
    {:ok, events} = EventLog.events(context.session_id)

    attempt =
      Enum.count(events, fn event ->
        event["type"] == "implementation_review_recovery_started" and
          event["data"]["turn"] == turn
      end) + 1

    if attempt <= @review_recovery_limit,
      do: {:retry, review, attempt},
      else: {:error, review}
  end

  defp continue_after_review_failure(context, turn, step, review, attempt) do
    with {:ok, _} <-
           EventLog.append(context.session_id, :implementation_review_recovery_started, %{
             "turn" => turn,
             "step" => step,
             "attempt" => attempt,
             "maximum_attempts" => @review_recovery_limit,
             "worker_id" => Map.get(review, :worker_id)
           }),
         {:ok, _} <-
           EventLog.append(context.session_id, :review_feedback, %{
             "turn" => turn,
             "attempt" => attempt,
             "content" => review.content
           }) do
      step(context, turn, step + 1, nil, 0, true)
    else
      {:error, reason} -> fail_turn(context, turn, reason)
    end
  end

  defp fail_reviewed_turn(context, turn, verification, review) do
    reason = {:implementation_review_failed, String.slice(review.content || "", 0, 1_000)}

    with {:ok, _} <-
           EventLog.append(context.session_id, :turn_finished, %{
             "turn" => turn,
             "reason" => "implementation_review_failed",
             "error" => inspect(reason),
             "verification_status" => verification_status(verification),
             "review_status" => "failed"
           }),
         {:ok, _outcome} <- record_task_outcome(context, turn, :failed, reason, verification),
         {:ok, _report} <- append_completion_report(context, verification) do
      {:error, reason}
    end
  end

  defp review_worker_options(context) do
    [
      provider: context.provider,
      provider_profile: context.provider_profile,
      provider_options: context.provider_options,
      strategy: context.strategy,
      data_dir: context.data_dir,
      workspace_root: context.workspace_root,
      context_window_tokens: context.context_window_tokens,
      compaction_threshold_percent: context.compaction_threshold_percent,
      model_strategy: context.model_strategy,
      correlation_id: runtime_command_field(context, :correlation_id),
      causation_id: runtime_command_field(context, :event_id)
    ]
  end

  defp review_status(nil), do: "not_required"
  defp review_status(review), do: to_string(review.status)

  defp fail_verified_turn(context, turn, verification) do
    failure_code =
      if Map.get(verification, :failure_kind) == :infrastructure,
        do: :verification_infrastructure_failed,
        else: :verification_failed

    reason = {failure_code, Map.get(verification, :summary, "required checks failed")}

    with {:ok, _} <-
           EventLog.append(context.session_id, :turn_finished, %{
             "turn" => turn,
             "reason" => "verification_failed",
             "error" => inspect(reason),
             "verification_status" => "failed"
           }),
         {:ok, _outcome} <- record_task_outcome(context, turn, :failed, reason, verification),
         {:ok, _report} <- append_completion_report(context, verification) do
      {:error, reason}
    end
  end

  defp append_completion_report(context, nil) do
    EventLog.append(context.session_id, :completion_report_generated, %{
      "status" => "unverified",
      "evidence_count" => 0
    })
  end

  defp append_completion_report(context, verification) do
    checks = Map.get(verification, :checks, [])

    status =
      case verification.status do
        :passed -> "verified"
        :not_configured -> "unverified"
        _other -> "verification_failed"
      end

    EventLog.append(context.session_id, :completion_report_generated, %{
      "verification_id" => Map.get(verification, :verification_id),
      "status" => status,
      "evidence_count" => length(checks),
      "passed_count" => Enum.count(checks, &(&1.status == :passed)),
      "failed_count" => Enum.count(checks, &(&1.status != :passed))
    })
  end

  defp verification_feedback(result) do
    checks =
      result
      |> Map.get(:checks, [])
      |> Enum.map_join("\n\n", fn check ->
        output = check.output || "[no output]"

        """
        Check #{check.id} (required=#{check.required}) failed with exit status #{inspect(check.exit_status)}:
        #{String.slice(output, 0, 16_000)}
        """
        |> String.trim()
      end)

    """
    Required verification rejected the previous completion candidate.
    Summary: #{result.summary}

    #{checks}

    Continue the same implementation now. Fix the reported failures, rerun focused checks as useful, and return a new completion candidate. Do not merely explain the failures.
    """
    |> String.trim()
  end

  defp verification_summary(nil), do: %{status: :unverified}

  defp verification_summary(verification) do
    Map.take(verification, [:status, :source, :summary, :verification_id])
  end

  defp verification_status(nil), do: "unverified"
  defp verification_status(verification), do: to_string(verification.status)

  defp verification_error(reason) when is_atom(reason), do: to_string(reason)
  defp verification_error({reason, _detail}) when is_atom(reason), do: to_string(reason)
  defp verification_error(_reason), do: "verification_error"

  defp count_events(session_id, type) do
    {:ok, events} = EventLog.events(session_id)
    Enum.count(events, &(&1["type"] == type))
  end

  defp event_id(event), do: "#{event["session_id"]}:#{event["seq"]}"
end
