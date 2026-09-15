defmodule BeamAgent.Tools.RepositoryIntelligence do
  @moduledoc "Read-only Observatory queries for coding agents."
  @behaviour BeamAgent.Tool
  alias BeamAgent.Project.{Observatory, ObservatoryIntelligence}
  @impl true
  def name, do: "repository_intelligence"
  @impl true
  def description,
    do:
      "Understand the repository, inspect a component/file, or estimate downstream static change impact with evidence, candidate tests and explicit unknowns. Does not execute tests or modify code."

  @impl true
  def access, do: :read
  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        action: %{type: "string", enum: ["overview", "inspect", "impact", "trace"]},
        destination: %{type: "string", description: "Destination component ID or file for trace"},
        target: %{
          type: "string",
          description: "Exact component ID or workspace-relative file path from overview"
        }
      },
      required: ["action"]
    }
  end

  @impl true
  def execute(%{"action" => action} = args, context)
      when action in ["overview", "inspect", "impact", "trace"] do
    with {:ok, report} <- Observatory.snapshot(context.project_id),
         {:ok, result} <- query_action(report.model, action, args) do
      {:ok, JSON.encode!(%{head: report.head, generated_at: report.generated_at, result: result})}
    end
  end

  def execute(_, _), do: {:error, :invalid_intelligence_query}

  defp query_action(model, "trace", %{"target" => target, "destination" => destination})
       when is_binary(target) and is_binary(destination),
       do: ObservatoryIntelligence.trace(model, target, destination)

  defp query_action(_model, "trace", _), do: {:error, :expected_observatory_target}
  defp query_action(model, action, args), do: query(model, action, args["target"])

  defp query(model, "overview", _),
    do:
      {:ok,
       Map.take(model, [
         :schema_version,
         :components,
         :dimensions,
         :investigations,
         :coverage,
         :limits
       ])}

  defp query(model, "impact", target) when is_binary(target),
    do: ObservatoryIntelligence.impact(model, target)

  defp query(model, "inspect", target) when is_binary(target) do
    files = Enum.filter(model.files, &(&1.path == target or &1.component == target))

    if files == [],
      do: {:error, :unknown_observatory_target},
      else: {:ok, %{files: files, limits: model.limits}}
  end

  defp query(_, _, _), do: {:error, :expected_observatory_target}
end
