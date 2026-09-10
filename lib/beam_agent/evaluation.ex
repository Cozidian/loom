defmodule BeamAgent.Evaluation do
  @moduledoc "Manifest-driven, evidence-producing evaluation runs for the complete harness."

  alias BeamAgent.VerificationPlan
  alias BeamAgent.Evaluation.{FileEvidence, Usage}

  @version 1

  @doc "Read-only fixture validation. Does not start sessions, load credentials or call providers."
  def preflight_file(path) do
    with {:ok, manifest} <- load(path) do
      scenarios = Enum.map(manifest.scenarios, &preflight_scenario/1)
      {:ok, %{passed: Enum.all?(scenarios, & &1.passed), scenarios: scenarios}}
    end
  end

  defp preflight_scenario(scenario) do
    result =
      case scenario.fixture do
        nil ->
          if scenario.expect.preserved_files == [],
            do: {:ok, []},
            else: {:error, :protected_files_require_fixture}

        fixture ->
          with {:ok, root} <- BeamAgent.Workspace.canonical_root(fixture) do
            before = FileEvidence.capture(root, scenario.expect.preserved_files)

            {:ok,
             FileEvidence.compare(root, before, scenario.expect.preserved_files, :file_preserved)}
          end
      end

    case result do
      {:ok, files} ->
        %{
          id: scenario.id,
          passed: Enum.all?(files, & &1.passed),
          preserved_files: files,
          required_checks: Enum.count(scenario.checks, & &1.required)
        }

      {:error, reason} ->
        %{id: scenario.id, passed: false, error: inspect(reason)}
    end
  end

  def run_file(path, opts \\ []) when is_binary(path) and is_list(opts) do
    with {:ok, manifest} <- load(path) do
      run(manifest, Keyword.put_new(opts, :manifest_path, Path.expand(path)))
    end
  end

  def load(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- JSON.decode(content),
         {:ok, manifest} <- validate_manifest(decoded, Path.dirname(Path.expand(path))) do
      {:ok, manifest}
    else
      {:error, :enoent} -> {:error, {:evaluation_manifest_not_found, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  def run(%{version: @version, scenarios: scenarios} = manifest, opts)
      when is_list(scenarios) and is_list(opts) do
    run_id = "eval-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    runs_root =
      (Keyword.get(opts, :runs_root) ||
         Path.join(System.tmp_dir!(), "beam-agent-evaluations"))
      |> Path.expand()

    output_dir = Path.join(runs_root, run_id)
    :ok = File.mkdir_p(output_dir)
    started_at = DateTime.utc_now() |> DateTime.to_iso8601()

    maximum = max(1, Keyword.get(opts, :max_concurrency, 1))

    runs = expand_repetitions(scenarios)

    results =
      runs
      |> Task.async_stream(&run_scenario(&1, output_dir, opts),
        ordered: true,
        max_concurrency: maximum,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> failed_result("unknown", {:scenario_runner_exit, reason})
      end)

    summary = summarize(results)
    acceptance = evaluate_acceptance(summary, Map.get(manifest, :acceptance, %{}))

    report = %{
      version: @version,
      run_id: run_id,
      manifest: Keyword.get(opts, :manifest_path),
      started_at: started_at,
      finished_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      scenarios: results,
      summary: Map.put(summary, :acceptance, acceptance),
      metadata: Map.get(manifest, :metadata, %{})
    }

    report_path = Keyword.get(opts, :report_path) || Path.join(output_dir, "report.json")

    with :ok <- File.mkdir_p(Path.dirname(report_path)),
         :ok <- File.write(report_path, [JSON.encode!(stringify(report)), "\n"]) do
      {:ok, Map.put(report, :report_path, report_path)}
    end
  rescue
    error -> {:error, {:evaluation_failed, Exception.message(error)}}
  end

  def run(_manifest, _opts), do: {:error, :invalid_evaluation_manifest}

  defp run_scenario(scenario, output_dir, opts) do
    scenario_dir = Path.join(output_dir, safe_id(scenario.run_id))
    workspace = Path.join(scenario_dir, "workspace")
    data_dir = Path.join(scenario_dir, "runtime")
    started = System.monotonic_time(:millisecond)

    with :ok <- prepare_workspace(scenario.fixture, workspace),
         {:ok, session_id} <- start_session(scenario, workspace, data_dir, opts) do
      try do
        run_started_scenario(scenario, session_id, workspace, started)
      after
        _ = BeamAgent.stop_session(session_id)
      end
    else
      {:error, reason} -> failed_scenario(scenario.id, reason, workspace, started)
    end
  end

  defp run_started_scenario(scenario, session_id, workspace, started) do
    with {:ok, goal} <- BeamAgent.goal(session_id),
         canonical_workspace = goal.workspace_root,
         before <-
           FileEvidence.capture(
             canonical_workspace,
             scenario.expect.preserved_files ++ scenario.expect.changed_files
           ),
         {ask_result, timed_out?} <- ask_with_baseline(session_id, scenario, before),
         integrity <- preserved_files(scenario, canonical_workspace, before),
         verification <- verify_intact(session_id, scenario.checks, ask_result, integrity),
         expectations <- expectations(scenario.expect, canonical_workspace, ask_result),
         {:ok, events} <- BeamAgent.goal_events(session_id, view: :internal) do
      expectations =
        expectations ++
          Enum.map(integrity, &Map.put(&1, :phase, :before_checks)) ++
          Enum.map(
            preserved_files(scenario, canonical_workspace, before),
            &Map.put(&1, :phase, :after_checks)
          ) ++
          FileEvidence.compare(
            canonical_workspace,
            before,
            scenario.expect.changed_files,
            :file_changed
          )

      duration_ms = System.monotonic_time(:millisecond) - started
      {:ok, goal_status} = BeamAgent.Goal.status(session_id)
      artifact = goal_status.last_work && goal_status.last_work.artifact
      metrics = metrics(events, artifact, duration_ms)
      passed = passed?(ask_result, timed_out?, verification, expectations)

      result = %{
        id: scenario.id,
        run_id: scenario.run_id,
        repetition: scenario.repetition,
        status: if(passed, do: :passed, else: :failed),
        verified_completion: passed and verified?(verification),
        session_id: session_id,
        project_id: goal.project_id,
        workspace: canonical_workspace,
        prompt_fingerprint: fingerprint(scenario.prompt),
        answer: answer_summary(ask_result),
        failure: failure_summary(ask_result, timed_out?),
        verification: verification,
        expectations: expectations,
        artifact: artifact_summary(artifact),
        metrics: metrics
      }

      result
    else
      {:error, reason} -> failed_scenario(scenario.id, reason, workspace, started)
    end
  end

  defp preserved_files(scenario, workspace, before),
    do: FileEvidence.compare(workspace, before, scenario.expect.preserved_files, :file_preserved)

  defp ask_with_baseline(session_id, scenario, before) do
    if Enum.all?(scenario.expect.preserved_files, &match?({:ok, _hash}, before[&1])) do
      ask(session_id, scenario.prompt, scenario.timeout_ms)
    else
      {{:error, :protected_fixture_missing_or_unreadable}, false}
    end
  end

  defp verify_intact(session_id, checks, ask_result, integrity) do
    if Enum.all?(integrity, & &1.passed) do
      verify(session_id, checks, ask_result)
    else
      %{status: :not_run, checks: [], failure: "protected_fixture_changed_or_missing"}
    end
  end

  defp verified?(verification),
    do:
      verification.status == :passed and
        Enum.any?(verification.checks, &(&1.required and &1.status == :passed))

  defp failed_scenario(id, reason, workspace, started) do
    failed_result(id, reason)
    |> Map.put(:workspace, workspace)
    |> put_in([:metrics, :duration_ms], System.monotonic_time(:millisecond) - started)
  end

  defp start_session(scenario, workspace, data_dir, opts) do
    session_options =
      opts
      |> Keyword.get(:session_options, [])
      |> Keyword.merge(scenario.session_options)
      |> Keyword.put(:workspace_root, workspace)
      |> Keyword.put(:data_dir, data_dir)
      |> Keyword.put_new(:approval_policy, :auto)

    BeamAgent.start_session(session_options)
  end

  defp ask(session_id, prompt, timeout_ms) do
    task = Task.async(fn -> BeamAgent.ask(session_id, prompt) end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        {result, false}

      nil ->
        _ = BeamAgent.cancel(session_id)
        _ = Task.shutdown(task, :brutal_kill)
        {{:error, :evaluation_timeout}, true}
    end
  end

  defp verify(_session_id, [], _ask_result), do: %{status: :not_configured, checks: []}

  defp verify(session_id, checks, {:ok, _answer}) do
    with {:ok, plan} <- VerificationPlan.new(%{source: "evaluation-manifest", checks: checks}),
         {:ok, result} <- BeamAgent.verify(session_id, plan) do
      Map.take(result, [:status, :source, :summary, :checks, :verification_id])
    else
      {:error, reason} -> %{status: :failed, checks: [], failure: inspect(reason)}
    end
  end

  defp verify(_session_id, _checks, {:error, reason}),
    do: %{status: :not_run, checks: [], failure: inspect(reason)}

  defp expectations(expect, workspace, ask_result) do
    answer =
      case ask_result do
        {:ok, content} -> content
        _other -> ""
      end

    file_results =
      Enum.map(expect.files, fn path ->
        case BeamAgent.Workspace.resolve(workspace, path) do
          {:ok, resolved} ->
            %{kind: :file_exists, path: path, passed: File.regular?(resolved)}

          {:error, reason} ->
            %{kind: :file_exists, path: path, passed: false, error: inspect(reason)}
        end
      end)

    content_results =
      Enum.map(expect.file_contains, fn assertion ->
        result =
          with {:ok, resolved} <- BeamAgent.Workspace.resolve(workspace, assertion.path),
               {:ok, content} <- File.read(resolved) do
            String.contains?(content, assertion.text)
          else
            _other -> false
          end

        %{
          kind: :file_contains,
          path: assertion.path,
          text_fingerprint: fingerprint(assertion.text),
          passed: result
        }
      end)

    answer_results =
      Enum.map(expect.answer_contains, fn text ->
        %{
          kind: :answer_contains,
          text_fingerprint: fingerprint(text),
          passed: String.contains?(answer, text)
        }
      end)

    file_results ++ content_results ++ answer_results
  end

  defp metrics(events, artifact, duration_ms) do
    types = Enum.map(events, &event_type/1)

    routes =
      events
      |> Enum.filter(&(event_type(&1) == "model_response_started"))
      |> Enum.map(fn event ->
        data = event_data(event)

        %{
          endpoint_id: data["provider_profile"] || data["endpoint_id"],
          provider: data["provider"],
          model: data["model"]
        }
      end)
      |> Enum.uniq()

    %{
      duration_ms: duration_ms,
      model_calls: Enum.count(types, &(&1 == "model_response_started")),
      routes: routes,
      distinct_endpoint_count:
        routes |> Enum.map(& &1.endpoint_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length(),
      multi_provider?:
        routes |> Enum.map(& &1.endpoint_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length() >=
          2,
      planning_required:
        Enum.count(events, fn event ->
          event_type(event) == "work_planning_decided" and event_data(event)["mode"] == "required"
        end),
      semantic_decomposition_choices:
        Enum.count(events, fn event ->
          event_type(event) == "semantic_planning_observed" and
            event_data(event)["multi_provider"] == true
        end),
      tool_calls: Enum.count(types, &(&1 == "tool_called")),
      delegated_workers: Enum.count(types, &(&1 == "delegation_started")),
      repair_attempts:
        Enum.count(
          types,
          &(&1 in ["verification_recovery_started", "implementation_review_recovery_started"])
        ),
      approval_requests: Enum.count(types, &(&1 == "tool_approval_requested")),
      permission_denials:
        Enum.count(types, &(&1 in ["tool_denied", "capability_denied", "path_lease_denied"])),
      suspected_stalls: Enum.count(types, &(&1 == "worker_stall_suspected")),
      confirmed_stalls: Enum.count(types, &(&1 == "tool_loop_stalled")),
      cancellations: Enum.count(types, &String.contains?(&1, "cancel")),
      changed_file_count: length((artifact && artifact.changed_files) || []),
      event_count: length(events)
    }
    |> Map.merge(Usage.summarize(events))
  end

  defp passed?({:ok, _answer}, false, verification, expectations) do
    verification.status in [:passed, :not_configured] and Enum.all?(expectations, & &1.passed)
  end

  defp passed?(_ask_result, _timed_out, _verification, _expectations), do: false

  defp prepare_workspace(nil, workspace), do: File.mkdir_p(workspace)

  defp prepare_workspace(fixture, workspace) do
    if File.dir?(fixture) do
      with :ok <- File.mkdir_p(Path.dirname(workspace)) do
        case File.cp_r(fixture, workspace) do
          {:ok, _files} -> :ok
          {:error, reason, _file} -> {:error, {:fixture_copy_failed, reason}}
        end
      end
    else
      {:error, {:evaluation_fixture_not_found, fixture}}
    end
  end

  defp validate_manifest(%{"version" => @version, "scenarios" => scenarios} = manifest, base)
       when is_list(scenarios) and scenarios != [] do
    with {:ok, scenarios} <- normalize_scenarios(scenarios, base),
         {:ok, acceptance} <- normalize_acceptance(manifest["acceptance"] || %{}) do
      {:ok,
       %{
         version: @version,
         scenarios: scenarios,
         acceptance: acceptance,
         metadata: manifest["metadata"] || %{}
       }}
    end
  end

  defp validate_manifest(_manifest, _base), do: {:error, :invalid_evaluation_manifest}

  defp normalize_scenarios(scenarios, base) do
    scenarios
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {scenario, index}, {:ok, acc} ->
      case normalize_scenario(scenario, base, index) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reject_duplicate_scenarios()
  end

  defp reject_duplicate_scenarios({:ok, scenarios}) do
    if length(scenarios) == MapSet.size(MapSet.new(scenarios, & &1.id)),
      do: {:ok, scenarios},
      else: {:error, :duplicate_evaluation_scenario}
  end

  defp reject_duplicate_scenarios(error), do: error

  defp normalize_scenario(%{"id" => id, "prompt" => prompt} = scenario, base, index)
       when is_binary(id) and id != "" and is_binary(prompt) and prompt != "" do
    fixture = scenario["fixture"]
    timeout_ms = scenario["timeout_ms"] || 300_000
    repetitions = scenario["repetitions"] || 1
    checks = scenario["checks"] || []
    expect = scenario["expect"] || %{}

    with true <-
           valid_id?(id) and is_integer(timeout_ms) and timeout_ms in 100..1_800_000 and
             is_integer(repetitions) and repetitions in 1..20 and
             is_list(checks) and is_map(expect) and
             (is_nil(fixture) or (is_binary(fixture) and fixture != "")),
         {:ok, checks} <- normalize_verification_checks(checks),
         {:ok, expect} <- normalize_expectations(expect) do
      {:ok,
       %{
         id: id,
         prompt: prompt,
         repetitions: repetitions,
         fixture: fixture && Path.expand(fixture, base),
         timeout_ms: timeout_ms,
         checks: checks,
         expect: expect,
         session_options: []
       }}
    else
      _invalid -> {:error, {:invalid_evaluation_scenario, index}}
    end
  end

  defp normalize_scenario(_scenario, _base, index),
    do: {:error, {:invalid_evaluation_scenario, index}}

  defp expand_repetitions(scenarios) do
    Enum.flat_map(scenarios, fn scenario ->
      Enum.map(1..scenario.repetitions, fn repetition ->
        scenario
        |> Map.put(:repetition, repetition)
        |> Map.put(:run_id, "#{scenario.id}-#{repetition}")
      end)
    end)
  end

  defp normalize_verification_checks([]), do: {:ok, []}

  defp normalize_verification_checks(checks) do
    case VerificationPlan.new(%{source: "evaluation-manifest", checks: checks}) do
      {:ok, plan} -> {:ok, plan.checks}
      {:error, _reason} -> :error
    end
  end

  defp normalize_expectations(expect) do
    files = Map.get(expect, "files", [])
    answer_contains = Map.get(expect, "answer_contains", [])
    file_contains = Map.get(expect, "file_contains", [])
    preserved_files = Map.get(expect, "preserved_files", [])
    changed_files = Map.get(expect, "changed_files", [])

    valid? =
      Map.keys(expect) --
        ["files", "answer_contains", "file_contains", "preserved_files", "changed_files"] == [] and
        Enum.all?(
          [files, answer_contains, file_contains, preserved_files, changed_files],
          &is_list/1
        ) and
        Enum.all?(files ++ preserved_files ++ changed_files, &valid_relative_file?/1) and
        MapSet.disjoint?(MapSet.new(preserved_files), MapSet.new(changed_files)) and
        Enum.all?(answer_contains, &is_binary/1) and
        Enum.all?(file_contains, fn
          %{"path" => path, "text" => text} ->
            valid_relative_file?(path) and is_binary(text)

          _assertion ->
            false
        end)

    if valid? do
      {:ok,
       %{
         files: files,
         preserved_files: Enum.uniq(preserved_files),
         changed_files: Enum.uniq(changed_files),
         answer_contains: answer_contains,
         file_contains:
           Enum.map(file_contains, fn assertion ->
             %{path: assertion["path"], text: assertion["text"]}
           end)
       }}
    else
      :error
    end
  end

  defp normalize_acceptance(acceptance) when is_map(acceptance) do
    normalized = %{
      minimum_verified_completion_rate: acceptance["minimum_verified_completion_rate"],
      minimum_multi_provider_rate: acceptance["minimum_multi_provider_rate"],
      maximum_permission_denials: acceptance["maximum_permission_denials"],
      maximum_user_interventions: acceptance["maximum_user_interventions"],
      maximum_stalls: acceptance["maximum_stalls"],
      maximum_suspected_stalls: acceptance["maximum_suspected_stalls"],
      maximum_average_model_calls: acceptance["maximum_average_model_calls"]
    }

    valid? =
      rate_or_nil?(normalized.minimum_verified_completion_rate) and
        rate_or_nil?(normalized.minimum_multi_provider_rate) and
        non_negative_or_nil?(normalized.maximum_permission_denials) and
        non_negative_or_nil?(normalized.maximum_user_interventions) and
        non_negative_or_nil?(normalized.maximum_stalls) and
        non_negative_or_nil?(normalized.maximum_suspected_stalls) and
        positive_number_or_nil?(normalized.maximum_average_model_calls)

    if valid?, do: {:ok, reject_nil_values(normalized)}, else: {:error, :invalid_acceptance_gate}
  end

  defp normalize_acceptance(_acceptance), do: {:error, :invalid_acceptance_gate}

  defp summarize(results) do
    passed = Enum.count(results, &(&1.status == :passed))
    total = length(results)

    summary = %{
      total: total,
      passed: passed,
      failed: total - passed,
      completion_rate: if(total == 0, do: 0.0, else: passed / total),
      verified_completion_rate:
        if(total == 0,
          do: 0.0,
          else: Enum.count(results, & &1.verified_completion) / total
        ),
      total_duration_ms: Enum.sum(Enum.map(results, &get_in(&1, [:metrics, :duration_ms]))),
      total_model_calls: Enum.sum(Enum.map(results, &get_in(&1, [:metrics, :model_calls]))),
      total_tool_calls: Enum.sum(Enum.map(results, &get_in(&1, [:metrics, :tool_calls]))),
      total_user_interventions:
        Enum.sum(Enum.map(results, &get_in(&1, [:metrics, :approval_requests]))),
      total_permission_denials:
        Enum.sum(Enum.map(results, &get_in(&1, [:metrics, :permission_denials]))),
      total_stalls: Enum.sum(Enum.map(results, &get_in(&1, [:metrics, :confirmed_stalls]))),
      total_suspected_stalls:
        Enum.sum(Enum.map(results, &get_in(&1, [:metrics, :suspected_stalls]))),
      multi_provider_runs: Enum.count(results, &get_in(&1, [:metrics, :multi_provider?])),
      multi_provider_rate:
        if(total == 0,
          do: 0.0,
          else: Enum.count(results, &get_in(&1, [:metrics, :multi_provider?])) / total
        ),
      average_model_calls:
        if(total == 0,
          do: 0.0,
          else: Enum.sum(Enum.map(results, &get_in(&1, [:metrics, :model_calls]))) / total
        ),
      route_teams: route_team_calibration(results)
    }

    Map.merge(summary, Usage.aggregate(Enum.map(results, & &1.metrics)))
  end

  defp evaluate_acceptance(summary, gates) do
    checks =
      gates
      |> Enum.map(fn
        {:minimum_verified_completion_rate, expected} ->
          acceptance_check(
            :minimum_verified_completion_rate,
            summary.verified_completion_rate,
            expected,
            :minimum
          )

        {:minimum_multi_provider_rate, expected} ->
          acceptance_check(
            :minimum_multi_provider_rate,
            summary.multi_provider_rate,
            expected,
            :minimum
          )

        {:maximum_permission_denials, expected} ->
          acceptance_check(
            :maximum_permission_denials,
            summary.total_permission_denials,
            expected,
            :maximum
          )

        {:maximum_user_interventions, expected} ->
          acceptance_check(
            :maximum_user_interventions,
            summary.total_user_interventions,
            expected,
            :maximum
          )

        {:maximum_stalls, expected} ->
          acceptance_check(:maximum_stalls, summary.total_stalls, expected, :maximum)

        {:maximum_suspected_stalls, expected} ->
          acceptance_check(
            :maximum_suspected_stalls,
            summary.total_suspected_stalls,
            expected,
            :maximum
          )

        {:maximum_average_model_calls, expected} ->
          acceptance_check(
            :maximum_average_model_calls,
            summary.average_model_calls,
            expected,
            :maximum
          )
      end)
      |> Enum.sort_by(& &1.name)

    %{configured: map_size(gates) > 0, passed: Enum.all?(checks, & &1.passed), checks: checks}
  end

  defp acceptance_check(name, actual, expected, :minimum),
    do: %{
      name: name,
      actual: actual,
      expected: expected,
      comparison: :minimum,
      passed: actual >= expected
    }

  defp acceptance_check(name, actual, expected, :maximum),
    do: %{
      name: name,
      actual: actual,
      expected: expected,
      comparison: :maximum,
      passed: actual <= expected
    }

  defp route_team_calibration(results) do
    results
    |> Enum.group_by(fn result ->
      result.metrics.routes
      |> Enum.map(& &1.endpoint_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.join("+")
      |> case do
        "" -> "deterministic"
        team -> team
      end
    end)
    |> Map.new(fn {team, team_results} ->
      runs = length(team_results)
      passed = Enum.count(team_results, &(&1.status == :passed))

      {team,
       %{
         runs: runs,
         passed: passed,
         completion_rate: passed / runs,
         verified_completion_rate: Enum.count(team_results, & &1.verified_completion) / runs,
         average_duration_ms: Enum.sum(Enum.map(team_results, & &1.metrics.duration_ms)) / runs,
         average_model_calls: Enum.sum(Enum.map(team_results, & &1.metrics.model_calls)) / runs,
         average_tool_calls: Enum.sum(Enum.map(team_results, & &1.metrics.tool_calls)) / runs
       }}
    end)
  end

  defp failed_result(id, reason) do
    %{
      id: id,
      status: :failed,
      verified_completion: false,
      failure: inspect(reason),
      verification: %{status: :not_run, checks: []},
      expectations: [],
      artifact: nil,
      metrics: %{
        duration_ms: 0,
        model_calls: 0,
        routes: [],
        distinct_endpoint_count: 0,
        multi_provider?: false,
        planning_required: 0,
        semantic_decomposition_choices: 0,
        total_tokens: nil,
        reported_tokens: 0,
        usage_reported_calls: 0,
        usage_missing_calls: 0,
        usage_status: :unknown,
        usage_unavailable_runs: 1,
        tool_calls: 0,
        delegated_workers: 0,
        repair_attempts: 0,
        approval_requests: 0,
        permission_denials: 0,
        suspected_stalls: 0,
        confirmed_stalls: 0,
        cancellations: 0,
        changed_file_count: 0,
        event_count: 0
      }
    }
  end

  defp artifact_summary(nil), do: nil

  defp artifact_summary(artifact) do
    Map.take(artifact, [
      :id,
      :kind,
      :status,
      :changed_files,
      :mutation_sources,
      :result_fingerprint,
      :workspace_delta
    ])
  end

  defp answer_summary({:ok, answer}), do: String.slice(answer, 0, 4_000)
  defp answer_summary(_result), do: nil
  defp failure_summary(_result, true), do: "evaluation_timeout"
  defp failure_summary({:error, reason}, false), do: inspect(reason)
  defp failure_summary(_result, false), do: nil

  defp event_type(%{payload: %{type: type}}), do: to_string(type)
  defp event_type(%{"payload" => %{"type" => type}}), do: to_string(type)
  defp event_type(_event), do: "unknown"

  defp event_data(%{payload: %{data: data}}) when is_map(data), do: data
  defp event_data(%{"payload" => %{"data" => data}}) when is_map(data), do: data
  defp event_data(_event), do: %{}

  defp fingerprint(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp safe_id(id), do: String.replace(id, ~r/[^a-zA-Z0-9_-]/u, "-")
  defp valid_id?(id), do: Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/u, id)

  defp valid_relative_file?(path),
    do:
      is_binary(path) and path not in ["", "."] and Path.type(path) == :relative and
        not Enum.member?(Path.split(path), "..")

  defp rate_or_nil?(nil), do: true
  defp rate_or_nil?(value), do: is_number(value) and value >= 0 and value <= 1
  defp non_negative_or_nil?(nil), do: true
  defp non_negative_or_nil?(value), do: is_integer(value) and value >= 0
  defp positive_number_or_nil?(nil), do: true
  defp positive_number_or_nil?(value), do: is_number(value) and value > 0

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value) when is_boolean(value) or is_nil(value), do: value
  defp stringify(value) when is_atom(value), do: to_string(value)
  defp stringify(value), do: value
end
