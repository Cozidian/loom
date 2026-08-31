defmodule BeamAgent.Goal.ContextPacket do
  @moduledoc "Runtime-assembled project truth supplied when a goal starts work."

  alias BeamAgent.Project.RepositoryIndex

  def build(project_id, objective) when is_binary(project_id) and is_binary(objective) do
    case safe_snapshot(project_id) do
      {:ok, repository} ->
        relevant =
          repository.files
          |> Map.values()
          |> Enum.map(&{relevance(&1, objective), &1})
          |> Enum.filter(fn {score, _file} -> score > 0 end)
          |> Enum.sort_by(fn {score, file} -> {-score, file.path} end)
          |> Enum.take(20)
          |> Enum.map(fn {_score, file} ->
            Map.take(file, [
              :path,
              :language,
              :symbols,
              :diagnostics,
              :test_relationships,
              :generation
            ])
          end)

        diagnostics =
          repository.files
          |> Map.values()
          |> Enum.filter(&(Map.get(&1, :diagnostics, []) != []))
          |> Enum.take(20)
          |> Enum.map(&Map.take(&1, [:path, :diagnostics, :generation]))

        {:ok,
         %{
           repository_generation: repository.generation,
           git: repository.git,
           relevant_files: relevant,
           diagnostics: diagnostics
         }}

      {:error, reason} ->
        {:ok,
         %{
           repository_generation: nil,
           git: %{},
           relevant_files: [],
           diagnostics: [],
           repository_status: "unavailable: #{inspect(reason)}"
         }}
    end
  end

  def build(_project_id, _objective), do: {:error, :invalid_context_packet_request}

  defp safe_snapshot(project_id) do
    RepositoryIndex.snapshot(project_id)
  catch
    :exit, reason -> {:error, {:repository_snapshot_exit, reason}}
  end

  defp relevance(file, objective) do
    haystack =
      [file.path | Map.get(file, :symbols, [])]
      |> Enum.join(" ")
      |> String.downcase()

    objective
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_.-]+/u, trim: true)
    |> Enum.reject(&(byte_size(&1) < 3))
    |> Enum.uniq()
    |> Enum.count(&String.contains?(haystack, &1))
  end
end
