defmodule BeamAgent.Providers.Demo do
  @moduledoc "A deterministic provider that demonstrates a real multi-step tool loop."
  @behaviour BeamAgent.LLMProvider

  @impl true
  def id, do: :demo

  @impl true
  def complete(messages, _tools, options) do
    if options[:parent_session_id] do
      prompt = messages |> Enum.reverse() |> Enum.find(&(&1.role == :user))

      {:ok,
       %{
         content: "I checked the delegated task: #{prompt.content}",
         tool_calls: []
       }}
    else
      complete_parent(messages)
    end
  end

  defp complete_parent(messages) do
    recent = messages |> Enum.reverse() |> Enum.take_while(&(&1.role != :user)) |> Enum.reverse()
    tool_results = Enum.filter(recent, &(&1.role == :tool))

    case tool_results do
      [] ->
        {:ok,
         %{
           content: nil,
           tool_calls: [call("add", %{"a" => 2, "b" => 3}, "call-add")]
         }}

      [%{name: "add", content: sum}] ->
        {:ok,
         %{
           content: nil,
           tool_calls: [
             call(
               "spawn_subagent",
               %{"prompt" => "Explain briefly why 2 + 3 equals #{sum}."},
               "call-subagent"
             )
           ]
         }}

      results ->
        add = Enum.find(results, &(&1.name == "add"))
        child = Enum.find(results, &(&1.name == "spawn_subagent"))

        {:ok,
         %{
           content:
             "The calculation returned #{add.content}. The subagent reported: #{child.content}",
           tool_calls: []
         }}
    end
  end

  defp call(name, arguments, id), do: %{id: id, name: name, arguments: arguments}
end
