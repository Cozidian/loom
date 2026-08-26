defmodule BeamAgent.Tools.ReadSkill do
  @moduledoc false
  @behaviour BeamAgent.Tool

  alias BeamAgent.Session.Context

  @impl true
  def name, do: "read_skill"

  @impl true
  def description,
    do: "Activate one discovered project skill and return its complete SKILL.md instructions."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        name: %{type: "string", description: "Exact skill name from the available catalog"}
      },
      required: ["name"]
    }
  end

  @impl true
  def access, do: :read

  @impl true
  def execute(%{"name" => name}, context) when is_binary(name) and name != "" do
    with {:ok, skill} <- Context.read_skill(context.session_id, name) do
      {:ok,
       JSON.encode!(%{
         name: skill.name,
         description: skill.description,
         path: skill.path,
         sha256: skill.sha256,
         content: skill.content
       })}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_skill_name}
end
