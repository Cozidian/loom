defmodule BeamAgent.Tools.Remember do
  @moduledoc false
  @behaviour BeamAgent.Tool

  @impl true
  def name, do: "remember"

  @impl true
  def description do
    "Save a durable memory about this project that should persist across future " <>
      "sessions: a user preference, feedback/a correction about how to work, a " <>
      "project fact or decision, or a pointer to an external resource. Use this " <>
      "on your own initiative whenever you learn something worth keeping, not only " <>
      "when explicitly asked. Writing the same id again updates that memory " <>
      "instead of creating a duplicate."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        id: %{
          type: "string",
          description:
            "Stable slug to update this memory later; derived from description if omitted"
        },
        type: %{
          type: "string",
          enum: ["user", "feedback", "project", "reference"],
          description:
            "user: who the user is/prefers. feedback: a correction or confirmed approach. " <>
              "project: a fact/decision about ongoing work. reference: a pointer to an external resource."
        },
        description: %{
          type: "string",
          description: "One-line summary used to judge relevance later"
        },
        content: %{type: "string", description: "The memory itself, including why it matters"},
        links: %{
          type: "array",
          items: %{type: "string"},
          description: "Ids of related memories, if any"
        }
      },
      required: ["type", "description", "content"]
    }
  end

  @impl true
  def access, do: :write

  @impl true
  def execute(arguments, context) when is_map(arguments) do
    attributes = Map.take(arguments, ["id", "type", "description", "content", "links"])

    case BeamAgent.remember(context.project_id, attributes) do
      {:ok, entry} -> {:ok, JSON.encode!(stringify(Map.take(entry, [:id, :type, :updated_at])))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
