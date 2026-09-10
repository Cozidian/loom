defmodule Mix.Tasks.BeamAgent.Eval do
  @moduledoc """
  Runs manifest-defined end-to-end BeamAgent evaluations.

      mix beam_agent.eval evals/coding.json

  Each scenario gets an isolated fixture workspace and runtime directory. The
  resulting JSON report records verification, filesystem artifacts, routing,
  token usage, delegation, repairs, permission decisions, stalls, and timing.

  ## Options

    * `--preflight` - validate fixture integrity without provider calls or verification commands
    * `--config PATH` - BeamAgent config (defaults to the normal config path)
    * `--profile NAME` - provider profile to evaluate
    * `--model MODEL` - model override for this evaluation only
    * `--model-strategy MODE` - auto, manual, or local_only
    * `--output PATH` - explicit JSON report path
    * `--runs-root PATH` - isolated workspaces and runtime logs directory
    * `--concurrency N` - scenarios to run concurrently (default: 1)

  """
  use Mix.Task

  alias BeamAgent.CLI.Config

  @shortdoc "Run manifest-defined end-to-end BeamAgent evaluations"

  @switches [
    config: :string,
    profile: :string,
    model: :string,
    model_strategy: :string,
    output: :string,
    runs_root: :string,
    concurrency: :integer,
    preflight: :boolean
  ]

  @impl true
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    case {positional, invalid} do
      {[manifest], []} ->
        if opts[:preflight], do: preflight(manifest), else: run_manifest(manifest, opts)

      _other ->
        Mix.raise(usage())
    end
  end

  defp preflight(manifest) do
    case BeamAgent.Evaluation.preflight_file(manifest) do
      {:ok, result} ->
        Enum.each(result.scenarios, fn scenario ->
          status = if scenario.passed, do: "ready", else: "failed"
          Mix.shell().info("#{scenario.id}: #{status}")
          if not scenario.passed, do: Mix.shell().info(inspect(scenario))
        end)

        Mix.shell().info("Preflight only: no model calls or verification commands were run.")
        unless result.passed, do: Mix.raise("evaluation preflight failed")

      {:error, reason} ->
        Mix.raise("evaluation preflight failed: #{inspect(reason)}")
    end
  end

  defp run_manifest(manifest, opts) do
    Mix.Task.run("app.start")

    config_path = opts[:config] || Config.path()

    config =
      case Config.load(config_path) do
        {:ok, config} -> config
        {:error, {:not_initialized, _path}} -> Config.defaults()
        {:error, reason} -> Mix.raise("could not load BeamAgent config: #{inspect(reason)}")
      end

    with {:ok, runtime} <- Config.runtime(config, opts[:profile]),
         runtime <- Config.merge_overrides(runtime, opts),
         {:ok, provider} <- Config.provider_atom(runtime["provider"]),
         {:ok, report} <-
           BeamAgent.Evaluation.run_file(manifest,
             session_options: [
               provider: provider,
               provider_profile: runtime["profile"],
               provider_options: Config.provider_options(runtime),
               model_endpoints: Config.model_endpoints(config, runtime),
               model_strategy: Config.model_strategy_atom(runtime["model_strategy"]),
               approval_policy: :auto
             ],
             report_path: opts[:output],
             runs_root: opts[:runs_root],
             max_concurrency: opts[:concurrency] || 1
           ) do
      summary = report.summary

      Mix.shell().info(
        "BeamAgent evaluation #{report.run_id}: #{summary.passed}/#{summary.total} passed " <>
          "(#{Float.round(summary.verified_completion_rate * 100, 1)}% verified)"
      )

      Mix.shell().info(
        "model calls: #{summary.total_model_calls} · tool calls: #{summary.total_tool_calls} · " <>
          "tokens: #{usage_label(summary)}"
      )

      Mix.shell().info("report: #{report.report_path}")

      if summary.acceptance.configured do
        status = if summary.acceptance.passed, do: "passed", else: "failed"
        Mix.shell().info("acceptance gate: #{status}")
      end

      cond do
        summary.failed > 0 ->
          Mix.raise("#{summary.failed} evaluation run(s) failed")

        summary.acceptance.configured and not summary.acceptance.passed ->
          Mix.raise("evaluation acceptance gate failed")

        true ->
          :ok
      end
    else
      {:error, reason} -> Mix.raise("evaluation failed: #{inspect(reason)}")
    end
  end

  defp usage_label(%{usage_status: status, total_tokens: tokens})
       when status in [:complete, :not_applicable],
       do: to_string(tokens)

  defp usage_label(summary),
    do:
      "unknown total (#{summary.reported_tokens} reported; " <>
        "#{summary.usage_missing_calls} call(s) without usage; " <>
        "#{summary.usage_unavailable_runs} run(s) without event evidence)"

  defp usage do
    """
    Usage: mix beam_agent.eval MANIFEST [options]

      --config PATH       BeamAgent config (defaults to the normal config path)
      --preflight         validate fixtures without calling a provider or running checks
      --profile NAME      provider profile to evaluate
      --model MODEL       model override for this evaluation only
      --model-strategy MODE auto, manual, or local_only
      --output PATH       explicit JSON report path
      --runs-root PATH    directory for isolated workspaces and runtime logs
      --concurrency N     scenarios to run concurrently (default: 1)
    """
  end
end
