defmodule BeamAgent.Tools.ListSkills do
  @moduledoc false
  @behaviour BeamAgent.Tool

  alias BeamAgent.Session.Context

  @impl true
  def name, do: "list_skills"

  @impl true
  def description,
    do: "List project skills available for lazy activation in this session."

  @impl true
  def input_schema, do: %{type: "object", properties: %{}}

  @impl true
  def access, do: :read

  @impl true
  def execute(arguments, context) when map_size(arguments) == 0 do
    with {:ok, skills} <- Context.skills(context.session_id) do
      {:ok, JSON.encode!(%{skills: skills})}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_no_arguments}
end
