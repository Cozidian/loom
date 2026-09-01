defmodule BeamAgent.EvaluationTest do
  use ExUnit.Case, async: false

  defmodule EvaluationProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :evaluation_test

    @impl true
    def complete(_messages, _tools, _options),
      do: {:ok, %{content: "Evaluation done with evidence.", tool_calls: []}}
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
    assert report.summary.verified_completion_rate == 1.0
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
end
