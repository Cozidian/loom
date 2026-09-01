defmodule Mix.Tasks.BeamAgent.Eval do
  @moduledoc """
  Runs manifest-defined end-to-end BeamAgent evaluations.

      mix beam_agent.eval evals/coding.json

  Each scenario gets an isolated fixture workspace and runtime directory. The
  resulting JSON report records verification, filesystem artifacts, routing,
  token usage, delegation, repairs, permission decisions, stalls, and timing.

  ## Options

    * `--config PATH` - BeamAgent config (defaults to the normal config path)
    * `--profile NAME` - provider profile to evaluate
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
    output: :string,
    runs_root: :string,
    concurrency: :integer
  ]

  @impl true
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    case {positional, invalid} do
      {[manifest], []} -> run_manifest(manifest, opts)
      _other -> Mix.raise(usage())
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
          "(#{Float.round(summary.verified_completion_rate * 100, 1)}%)"
      )

      Mix.shell().info(
        "model calls: #{summary.total_model_calls} · tool calls: #{summary.total_tool_calls} · " <>
          "tokens: #{summary.total_tokens}"
      )

      Mix.shell().info("report: #{report.report_path}")

      if summary.failed > 0, do: Mix.raise("#{summary.failed} evaluation scenario(s) failed")
    else
      {:error, reason} -> Mix.raise("evaluation failed: #{inspect(reason)}")
    end
  end

  defp usage do
    """
    Usage: mix beam_agent.eval MANIFEST [options]

      --config PATH       BeamAgent config (defaults to the normal config path)
      --profile NAME      provider profile to evaluate
      --output PATH       explicit JSON report path
      --runs-root PATH    directory for isolated workspaces and runtime logs
      --concurrency N     scenarios to run concurrently (default: 1)
    """
  end
end
