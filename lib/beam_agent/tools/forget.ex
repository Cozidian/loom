defmodule BeamAgent.Tools.Forget do
  @moduledoc false
  @behaviour BeamAgent.Tool

  @impl true
  def name, do: "forget"

  @impl true
  def description do
    "Remove one previously saved memory by id — use this when the user asks to " <>
      "forget something, or a remembered fact turns out to be wrong or stale."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{id: %{type: "string", description: "Id of the memory to remove"}},
      required: ["id"]
    }
  end

  @impl true
  def access, do: :write

  @impl true
  def execute(%{"id" => id}, context) when is_binary(id) and id != "" do
    case BeamAgent.forget(context.project_id, id) do
      :ok -> {:ok, JSON.encode!(%{forgotten: id})}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_memory_id}
end
