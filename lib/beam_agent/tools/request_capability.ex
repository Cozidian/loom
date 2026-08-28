defmodule BeamAgent.Tools.RequestCapability do
  @moduledoc false
  @behaviour BeamAgent.Tool

  @impl true
  def name, do: "request_capability"

  @impl true
  def description,
    do:
      "Request a temporary capability lease from runtime policy and the parent approval boundary."

  @impl true
  def input_schema do
    scope = %{type: "array", items: %{type: "string"}}

    %{
      type: "object",
      properties: %{
        purpose: %{type: "string"},
        capabilities: %{
          type: "object",
          properties: %{
            tools: scope,
            paths: scope,
            commands: scope,
            hosts: scope,
            git_operations: scope,
            browser_scopes: scope,
            mcp_servers: scope,
            model_classes: scope,
            secret_kinds: scope,
            approval_scopes: scope
          }
        },
        duration_ms: %{type: "integer"},
        operations: %{type: "integer"},
        fallback: %{type: "string"}
      },
      required: ["purpose", "capabilities"]
    }
  end

  @impl true
  def access, do: :trusted

  @impl true
  def execute(arguments, context) do
    case BeamAgent.request_capability(context.session_id, arguments) do
      {:ok, lease} -> {:ok, JSON.encode!(lease)}
      {:error, reason} -> {:error, reason}
    end
  end
end
