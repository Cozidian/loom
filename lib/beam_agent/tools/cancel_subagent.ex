defmodule BeamAgent.Tools.CancelSubagent do
  @moduledoc false
  @behaviour BeamAgent.Tool

  @impl true
  def name, do: "cancel_subagent"

  @impl true
  def description, do: "Cancel one background subagent and its supervised session subtree."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{delegation_id: %{type: "string"}},
      required: ["delegation_id"]
    }
  end

  @impl true
  def access, do: :delegate

  @impl true
  def execute(%{"delegation_id" => id}, context) when is_binary(id) do
    with :ok <- BeamAgent.cancel_delegation(context.goal_id, id, :cancelled_by_parent) do
      {:ok, JSON.encode!(%{delegation_id: id, status: "cancelled"})}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_delegation_id}
end
