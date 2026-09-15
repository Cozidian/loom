defmodule BeamAgent.Tools.Recall do
  @moduledoc false
  @behaviour BeamAgent.Tool

  @impl true
  def name, do: "recall"

  @impl true
  def description do
    "List this project's durable memory as a short index (id, type, description), " <>
      "or read one entry's full content by id. Check this near the start of work " <>
      "when prior feedback, preferences or project facts might change your approach."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        id: %{
          type: "string",
          description: "Omit to list the index; provide to read one memory in full"
        }
      }
    }
  end

  @impl true
  def access, do: :read

  @impl true
  def execute(%{"id" => id}, context) when is_binary(id) and id != "" do
    case BeamAgent.recall(context.project_id, id) do
      {:ok, entry} -> {:ok, JSON.encode!(stringify(entry))}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(arguments, context) when map_size(arguments) == 0 do
    case BeamAgent.recall(context.project_id) do
      {:ok, index} -> {:ok, JSON.encode!(%{memories: Enum.map(index, &stringify/1)})}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_recall_arguments}

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
