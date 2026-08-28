defmodule BeamAgent.Tools.RequestProjectContext do
  @moduledoc false
  @behaviour BeamAgent.Tool

  @impl true
  def name, do: "request_project_context"

  @impl true
  def description do
    "Request a bounded, provenance-bearing projection of current project repository intelligence."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        kinds: %{
          type: "array",
          items: %{type: "string", enum: ["repository", "git", "diagnostics", "tests"]}
        },
        maximum_bytes: %{type: "integer", minimum: 1_000, maximum: 64_000}
      }
    }
  end

  @impl true
  def access, do: :read

  @impl true
  def execute(arguments, context) when is_map(arguments) do
    request = %{
      kinds: arguments["kinds"] || ["repository"],
      maximum_bytes: min(arguments["maximum_bytes"] || 32_000, 64_000)
    }

    case BeamAgent.project_context(context.project_id, request) do
      {:ok, view} -> {:ok, JSON.encode!(stringify(view))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stringify(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value) when is_atom(value), do: to_string(value)
  defp stringify(value), do: value
end
