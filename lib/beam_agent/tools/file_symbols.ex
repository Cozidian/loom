defmodule BeamAgent.Tools.FileSymbols do
  @moduledoc false
  @behaviour BeamAgent.Tool

  @impl true
  def name, do: "file_symbols"

  @impl true
  def description,
    do: "Read language-aware symbols and dependencies from the current repository index."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{path: %{type: "string", description: "Workspace-relative indexed file"}},
      required: ["path"]
    }
  end

  @impl true
  def access, do: :read

  @impl true
  def execute(%{"path" => path}, context) when is_binary(path) do
    case BeamAgent.repository_file(context.project_id, path) do
      {:ok, file} ->
        {:ok,
         JSON.encode!(
           Map.take(file, [:path, :hash, :generation, :language, :symbols, :dependencies])
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_file_path}
end
