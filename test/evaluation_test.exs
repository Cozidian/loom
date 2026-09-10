defmodule BeamAgent.EvaluationTest do
  use ExUnit.Case, async: false

  defmodule EvaluationProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :evaluation_test

    @impl true
    def complete(_messages, _tools, options) do
      if action = options[:evaluation_action] do
        {:ok, context} = BeamAgent.Agent.construction_context(options[:session_id])
        action.(context.workspace_root)
      end

      {:ok, %{content: "Evaluation done with evidence.", tool_calls: []}}
    end
  end

  setup_all do
    :ok = BeamAgent.CapabilityCatalog.register_provider(EvaluationProvider)
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "beam-agent-eval-#{System.unique_integer([:positive])}")
    fixture = Path.join(root, "fixture")
    File.mkdir_p!(fixture)
    File.write!(Path.join(fixture, "seed.txt"), "fixture evidence\n")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, fixture: fixture}
  end

  test "runs a complete isolated scenario and writes measurable evidence", context do
    manifest_path = Path.join(context.root, "evaluation.json")
    report_path = Path.join(context.root, "report.json")

    File.write!(
      manifest_path,
      JSON.encode!(%{
        version: 1,
        scenarios: [
          %{
            id: "evidence-answer",
            fixture: context.fixture,
            prompt: "Explain whether the fixture is ready",
            expect: %{
              files: ["seed.txt"],
              file_contains: [%{path: "seed.txt", text: "fixture evidence"}],
              answer_contains: ["Evaluation done"]
            }
          }
        ]
      })
    )

    assert {:ok, report} =
             BeamAgent.Evaluation.run_file(manifest_path,
               runs_root: Path.join(context.root, "runs"),
               report_path: report_path,
               session_options: [provider: :evaluation_test]
             )

    assert report.summary.total == 1
    assert report.summary.passed == 1
    assert report.summary.completion_rate == 1.0
    assert report.summary.verified_completion_rate == 0.0
    assert report.summary.total_tokens == nil
    assert report.summary.usage_status == :unknown
    assert [scenario] = report.scenarios
    assert scenario.status == :passed
    assert scenario.metrics.model_calls == 1
    assert scenario.metrics.event_count > 0
    assert File.regular?(Path.join(scenario.workspace, "seed.txt"))

    assert {:ok, stored} = report_path |> File.read!() |> JSON.decode()
    assert stored["summary"]["passed"] == 1
    assert stored["scenarios"] |> hd() |> get_in(["metrics", "model_calls"]) == 1
  end

  test "the checked-in coding suite and fixture remain loadable" do
    manifest_path = Path.expand("evals/coding.json")

    assert {:ok, manifest} = BeamAgent.Evaluation.load(manifest_path)
    assert [scenario] = manifest.scenarios
    assert scenario.id == "clipboard-image-paste"
    assert File.regular?(Path.join(scenario.fixture, "test/editor_test.exs"))
    assert Enum.map(scenario.checks, & &1.id) == ["tests", "compile"]
  end

  test "repeated runs are held to an explicit acceptance gate", context do
    manifest_path = Path.join(context.root, "acceptance.json")

    File.write!(
      manifest_path,
      JSON.encode!(%{
        version: 1,
        acceptance: %{
          minimum_verified_completion_rate: 1.0,
          maximum_permission_denials: 0,
          maximum_user_interventions: 0,
          maximum_stalls: 0,
          maximum_average_model_calls: 2
        },
        scenarios: [
          %{
            id: "repeatable-answer",
            repetitions: 3,
            fixture: context.fixture,
            prompt: "Explain whether the fixture is ready",
            checks: [%{id: "seed", command: "test -f seed.txt"}],
            expect: %{answer_contains: ["Evaluation done"]}
          }
        ]
      })
    )

    assert {:ok, report} =
             BeamAgent.Evaluation.run_file(manifest_path,
               runs_root: Path.join(context.root, "acceptance-runs"),
               session_options: [provider: :evaluation_test]
             )

    assert report.summary.total == 3
    assert report.summary.acceptance.configured
    assert report.summary.acceptance.passed
    assert Enum.map(report.scenarios, & &1.repetition) == [1, 2, 3]
    assert Enum.uniq(Enum.map(report.scenarios, & &1.run_id)) |> length() == 3

    decoded = report.report_path |> File.read!() |> JSON.decode!()
    assert decoded["summary"]["acceptance"]["configured"] == true
    assert decoded["summary"]["acceptance"]["passed"] == true
    assert hd(decoded["scenarios"])["metrics"]["multi_provider?"] == false
  end

  test "protected fixture changes invalidate the result before running acceptance commands",
       ctx do
    action = fn workspace -> File.write!(Path.join(workspace, "seed.txt"), "weakened check") end

    report =
      evaluate(ctx,
        expect: %{preserved_files: ["seed.txt"]},
        checks: [%{id: "sentinel", command: "touch verification-ran"}],
        action: action
      )

    assert [scenario] = report.scenarios
    assert scenario.status == :failed
    assert scenario.verification.status == :not_run
    assert scenario.verification.failure == "protected_fixture_changed_or_missing"
    refute File.exists?(Path.join(scenario.workspace, "verification-ran"))
    assert File.read!(Path.join(ctx.fixture, "seed.txt")) == "fixture evidence\n"

    assert [%{passed: false, phase: :before_checks}, %{passed: false, phase: :after_checks}] =
             scenario.expectations
  end

  test "a missing protected original fails without spending a model call", ctx do
    report = evaluate(ctx, expect: %{preserved_files: ["absent.bin"]})
    assert [scenario] = report.scenarios
    assert scenario.status == :failed
    assert scenario.metrics.model_calls == 0
    assert scenario.failure == ":protected_fixture_missing_or_unreadable"
  end

  test "requested changes need a content delta and a real output file", ctx do
    report = evaluate(ctx, expect: %{changed_files: ["seed.txt"]})
    assert [scenario] = report.scenarios
    assert scenario.status == :failed
    assert [%{kind: :file_changed, passed: false}] = scenario.expectations

    changed =
      evaluate(ctx,
        expect: %{changed_files: ["seed.txt", "new.txt"]},
        action: fn workspace ->
          File.write!(Path.join(workspace, "seed.txt"), "actual change")
          File.write!(Path.join(workspace, "new.txt"), "new result")
        end
      )

    assert [scenario] = changed.scenarios
    assert scenario.status == :passed
    refute scenario.verified_completion
    assert Enum.all?(scenario.expectations, & &1.passed)
  end

  test "acceptance commands cannot silently damage the preserved original", ctx do
    report =
      evaluate(ctx,
        expect: %{preserved_files: ["seed.txt"]},
        checks: [%{id: "mutating-check", command: "printf changed > seed.txt"}]
      )

    assert [scenario] = report.scenarios
    assert scenario.verification.status == :passed
    assert scenario.status == :failed
    refute scenario.verified_completion

    assert [%{passed: true, phase: :before_checks}, %{passed: false, phase: :after_checks}] =
             scenario.expectations
  end

  test "answer-only and optional-only runs cannot meet a verified-completion gate", ctx do
    for checks <- [[], [%{id: "optional", command: "true", required: false}]] do
      report = evaluate(ctx, checks: checks, acceptance: %{minimum_verified_completion_rate: 1})
      assert report.summary.passed == 1
      assert report.summary.verified_completion_rate == 0.0
      refute report.summary.acceptance.passed
    end
  end

  test "malformed expectations and duplicate scenario ids are rejected", ctx do
    path = Path.join(ctx.root, "invalid.json")

    for expect <- [
          %{files: "seed.txt"},
          %{files: false},
          %{preserved_file: ["seed.txt"]},
          %{preserved_files: ["seed.txt"], changed_files: ["seed.txt"]},
          %{preserved_files: ["../outside"]},
          %{changed_files: ["/tmp/absolute"]},
          %{file_contains: [%{path: "../outside", text: "x"}]}
        ] do
      File.write!(
        path,
        JSON.encode!(%{version: 1, scenarios: [%{id: "test", prompt: "x", expect: expect}]})
      )

      assert {:error, {:invalid_evaluation_scenario, 1}} = BeamAgent.Evaluation.load(path)
    end

    scenario = %{id: "same", prompt: "x"}
    File.write!(path, JSON.encode!(%{version: 1, scenarios: [scenario, scenario]}))
    assert {:error, :duplicate_evaluation_scenario} = BeamAgent.Evaluation.load(path)
  end

  test "preflight checks originals without starting a provider or running shell checks", ctx do
    path = Path.join(ctx.root, "preflight.json")

    File.write!(
      path,
      JSON.encode!(%{
        version: 1,
        scenarios: [
          %{
            id: "preflight",
            prompt: "Unused",
            fixture: ctx.fixture,
            checks: [%{id: "never-run", command: "touch should-not-exist"}],
            expect: %{preserved_files: ["seed.txt"]}
          }
        ]
      })
    )

    assert {:ok, %{passed: true, scenarios: [%{required_checks: 1}]}} =
             BeamAgent.Evaluation.preflight_file(path)

    refute File.exists?(Path.join(ctx.fixture, "should-not-exist"))
    File.rm!(Path.join(ctx.fixture, "seed.txt"))
    assert {:ok, %{passed: false}} = BeamAgent.Evaluation.preflight_file(path)
  end

  defp evaluate(ctx, options) do
    manifest_path = Path.join(ctx.root, "trial.json")

    File.write!(
      manifest_path,
      JSON.encode!(%{
        version: 1,
        acceptance: options[:acceptance] || %{},
        scenarios: [
          %{
            id: "trial",
            prompt: "Explain whether the fixture is ready",
            fixture: ctx.fixture,
            expect: options[:expect] || %{},
            checks: options[:checks] || []
          }
        ]
      })
    )

    assert {:ok, report} =
             BeamAgent.Evaluation.run_file(manifest_path,
               runs_root: Path.join(ctx.root, "trial-runs"),
               session_options: [
                 provider: :evaluation_test,
                 provider_options: [evaluation_action: options[:action]]
               ]
             )

    report
  end
end
